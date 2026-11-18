// Package sub parses subscriptions: URI lists, Base64 lists and Xray JSON.
//
// Link parsing is adapted from SVOI (https://github.com/1atex/svoi),
// Copyright (c) 2026 SVOI contributors, MIT License. See third_party/SVOI-LICENSE.
package sub

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"

	"github.com/kyzaygy/paradise/core/internal/apperr"
	"github.com/kyzaygy/paradise/core/internal/model"
)

// MaxServers is the maximum number of servers accepted from one source.
const MaxServers = 2000

type object = map[string]any

// Parsed is the result of parsing a subscription body.
type Parsed struct {
	Format   string
	Servers  []model.Server
	Warnings []string
	Headers  http.Header // metadata found inside the body (#profile-title: ...)
	Routing  []string    // happ://routing/… links found in the body
}

// DecodeBase64 accepts standard and URL-safe alphabets, with or without padding.
func DecodeBase64(s string) ([]byte, error) {
	s = strings.Join(strings.Fields(s), "")
	for _, enc := range []*base64.Encoding{base64.StdEncoding, base64.RawStdEncoding, base64.URLEncoding, base64.RawURLEncoding} {
		if b, err := enc.DecodeString(s); err == nil {
			return b, nil
		}
	}
	return nil, errors.New("invalid base64")
}

// Parse parses a subscription body. Servers get ids derived from subscriptionID.
func Parse(data []byte, subscriptionID string) (Parsed, error) {
	p := Parsed{Format: "uri", Headers: http.Header{}}
	s := strings.TrimSpace(strings.TrimPrefix(string(data), "\ufeff"))
	if looksLikeHTML(s) {
		return p, apperr.New(apperr.HTMLResponse, "")
	}
	if IsWireGuardConf(s) {
		p.Format = "wireguard"
		servers, warnings, err := ParseWireGuardConf(s)
		p.Warnings = warnings
		if err != nil {
			return p, apperr.New(apperr.EmptySubscription, err.Error())
		}
		for _, srv := range servers {
			srv.ID = model.ServerID(subscriptionID, srv.Key)
			p.Servers = append(p.Servers, srv)
		}
		return p, nil
	}
	s = stripBodyMetadata(s, p.Headers)
	if !strings.HasPrefix(s, "{") && !strings.HasPrefix(s, "[") && !strings.Contains(s, "://") {
		b, err := DecodeBase64(s)
		if err != nil {
			return p, apperr.New(apperr.UnsupportedFormat, "")
		}
		s = strings.TrimSpace(string(b))
		s = stripBodyMetadata(s, p.Headers)
		p.Format = "base64"
	}
	seen := map[string]bool{}
	add := func(srv model.Server) {
		if seen[srv.Key] {
			return
		}
		seen[srv.Key] = true
		srv.ID = model.ServerID(subscriptionID, srv.Key)
		p.Servers = append(p.Servers, srv)
	}
	if strings.HasPrefix(s, "{") || strings.HasPrefix(s, "[") {
		p.Format = "xray-json"
		var raw any
		if json.Unmarshal([]byte(s), &raw) != nil {
			return p, apperr.New(apperr.UnsupportedFormat, "json")
		}
		configs, ok := raw.([]any)
		if !ok {
			configs = []any{raw}
		}
		for ci, c := range configs {
			m, ok := c.(map[string]any)
			if !ok {
				p.Warnings = append(p.Warnings, fmt.Sprintf("config %d: not an object", ci+1))
				continue
			}
			if outs, ok := m["outbounds"].([]any); ok {
				srv, err := ServerFromProfile(m, outs)
				if err != nil {
					p.Warnings = append(p.Warnings, fmt.Sprintf("config %d: %v", ci+1, err))
					continue
				}
				add(srv)
				continue
			}
			if _, ok := m["protocol"]; ok {
				srv, err := ServerFromOutbound(str(m["tag"]), m)
				if err != nil {
					p.Warnings = append(p.Warnings, fmt.Sprintf("config %d: %v", ci+1, err))
					continue
				}
				add(srv)
			}
		}
	} else {
		for i, line := range strings.Split(s, "\n") {
			line = strings.TrimSpace(line)
			if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, "//") {
				continue
			}
			low := strings.ToLower(line)
			if strings.HasPrefix(low, "happ://routing/") {
				p.Routing = append(p.Routing, line)
				continue
			}
			if strings.HasPrefix(low, "happ://crypt") {
				p.Warnings = append(p.Warnings, fmt.Sprintf("line %d: encrypted Happ link", i+1))
				continue
			}
			srv, err := ParseURI(line)
			if err != nil {
				p.Warnings = append(p.Warnings, fmt.Sprintf("line %d: %v", i+1, err))
				continue
			}
			add(srv)
		}
	}
	if len(p.Servers) == 0 {
		if len(p.Routing) > 0 {
			p.Format = "routing"
			return p, nil
		}
		return p, apperr.New(apperr.EmptySubscription, firstWarning(p.Warnings))
	}
	if len(p.Servers) > MaxServers {
		return p, apperr.New(apperr.TooLarge, strconv.Itoa(len(p.Servers)))
	}
	return p, nil
}

func looksLikeHTML(s string) bool {
	head := strings.ToLower(s)
	if len(head) > 4096 {
		head = head[:4096]
	}
	if strings.HasPrefix(head, "<") {
		return true
	}
	for _, tag := range []string{"<!doctype html", "<html", "<head", "<body", "<script", "<meta ", "<div"} {
		if strings.Contains(head, tag) {
			return true
		}
	}
	return false
}

func firstWarning(w []string) string {
	if len(w) == 0 {
		return ""
	}
	return w[0]
}

var bodyMetaKeys = []string{"profile-title", "profile-update-interval", "subscription-userinfo", "support-url", "profile-web-page-url", "announce"}

func stripBodyMetadata(s string, h http.Header) string {
	lines := strings.Split(s, "\n")
	kept := lines[:0]
	for _, line := range lines {
		t := strings.TrimSpace(line)
		if strings.HasPrefix(t, "#") {
			body := strings.TrimSpace(strings.TrimPrefix(t, "#"))
			if k, v, ok := strings.Cut(body, ":"); ok {
				key := strings.ToLower(strings.TrimSpace(k))
				for _, known := range bodyMetaKeys {
					if key == known {
						h.Set(key, strings.TrimSpace(v))
					}
				}
			}
			continue
		}
		kept = append(kept, line)
	}
	return strings.Join(kept, "\n")
}

func str(v any) string {
	switch x := v.(type) {
	case string:
		return x
	case float64:
		return strconv.FormatFloat(x, 'f', -1, 64)
	case json.Number:
		return x.String()
	case nil:
		return ""
	default:
		return fmt.Sprint(x)
	}
}

func number(v any) int { i, _ := strconv.Atoi(str(v)); return i }

func obj(v any) object {
	m, _ := v.(map[string]any)
	if m == nil {
		return object{}
	}
	return m
}

func firstObject(v any) object {
	a, _ := v.([]any)
	if len(a) == 0 {
		return object{}
	}
	return obj(a[0])
}

var supported = map[string]bool{"vless": true, "vmess": true, "trojan": true, "shadowsocks": true, "socks": true, "http": true, "hysteria": true, "wireguard": true}

// IsService reports outbounds that are not proxies.
func IsService(protocol string) bool {
	switch protocol {
	case "freedom", "blackhole", "dns", "loopback":
		return true
	}
	return false
}

// ServerFromOutbound validates a single Xray outbound and wraps it as a server.
func ServerFromOutbound(name string, out object) (model.Server, error) {
	protocol := str(out["protocol"])
	if !supported[protocol] {
		return model.Server{}, fmt.Errorf("unsupported protocol %q", protocol)
	}
	if out["proxySettings"] != nil {
		return model.Server{}, errors.New("proxySettings chains need a full profile")
	}
	settings := obj(out["settings"])
	endpoint := settings
	if settings["vnext"] != nil {
		endpoint = firstObject(settings["vnext"])
	} else if settings["servers"] != nil {
		endpoint = firstObject(settings["servers"])
	}
	address := str(endpoint["address"])
	port := number(endpoint["port"])
	if protocol == "wireguard" {
		peer := firstObject(settings["peers"])
		host, p, err := net.SplitHostPort(str(peer["endpoint"]))
		if err != nil {
			return model.Server{}, errors.New("wireguard: invalid endpoint")
		}
		address, port = host, number(p)
	}
	if address == "" || port < 1 || port > 65535 {
		return model.Server{}, errors.New("missing address or port")
	}
	stream := obj(out["streamSettings"])
	network := str(stream["network"])
	if network == "" {
		network = "tcp"
	}
	if protocol == "wireguard" {
		network = "udp"
	}
	security := str(stream["security"])
	if security == "" {
		security = "none"
	}
	if name == "" || name == "proxy" {
		name = net.JoinHostPort(address, strconv.Itoa(port))
	}
	out["tag"] = "proxy"
	b, err := json.Marshal(out)
	if err != nil {
		return model.Server{}, err
	}
	return model.Server{Key: model.ContentKey(out), Name: name, Protocol: protocol, Address: address, Port: port, Network: network, Security: security, Outbound: b}, nil
}

// ServerFromProfile wraps a full Xray config. The first proxy outbound is used for display.
func ServerFromProfile(m object, outs []any) (model.Server, error) {
	var first object
	for _, o := range outs {
		ob := obj(o)
		if !IsService(str(ob["protocol"])) {
			first = ob
			break
		}
	}
	if first == nil {
		return model.Server{}, errors.New("profile has no proxy outbound")
	}
	info, err := ServerFromOutbound("", cloneObject(first))
	if err != nil {
		return model.Server{}, err
	}
	name := str(m["remarks"])
	if name == "" {
		name = info.Name
	}
	b, err := json.Marshal(m)
	if err != nil {
		return model.Server{}, err
	}
	info.Name = name
	info.Key = model.ContentKey(m)
	info.Outbound = nil
	info.Profile = b
	return info, nil
}

func cloneObject(m object) object {
	b, _ := json.Marshal(m)
	var c object
	_ = json.Unmarshal(b, &c)
	return c
}

// ParseURI parses vless://, vmess://, trojan://, ss://, socks://, hysteria2:// and wireguard:// links.
// Happ-style extras in the name ("#Name?serverDescription=…&fragment=…") are applied too.
func ParseURI(raw string) (model.Server, error) {
	srv, err := parseURI(raw)
	if err != nil {
		return srv, err
	}
	applyNameExtras(&srv)
	return srv, nil
}

func parseURI(raw string) (model.Server, error) {
	scheme, _, ok := strings.Cut(raw, "://")
	if !ok {
		return model.Server{}, errors.New("not a link")
	}
	switch strings.ToLower(scheme) {
	case "hysteria2", "hy2":
		return parseHysteria2(raw)
	case "vmess":
		return parseVMess(raw)
	case "ss":
		return parseShadowsocks(raw)
	case "wireguard", "wg":
		return parseWireGuard(raw)
	case "socks", "socks5":
		raw = expandSocks(raw)
	}
	u, err := url.Parse(raw)
	if err != nil {
		return model.Server{}, errors.New("invalid link")
	}
	port, err := strconv.Atoi(u.Port())
	if err != nil || port < 1 || port > 65535 || u.Hostname() == "" {
		return model.Server{}, errors.New("invalid address or port")
	}
	protocol := strings.ToLower(u.Scheme)
	if u.User == nil && protocol != "socks" && protocol != "socks5" {
		return model.Server{}, errors.New("missing credentials")
	}
	credential := ""
	if u.User != nil {
		credential = u.User.Username()
	}
	q := u.Query()
	settings := object{}
	switch protocol {
	case "vless":
		if err := validVLESSID(credential); err != nil {
			return model.Server{}, err
		}
		enc := defaultString(q.Get("encryption"), "none")
		if enc != "none" && !strings.HasPrefix(enc, "mlkem768x25519plus.") {
			return model.Server{}, fmt.Errorf("vless: unsupported encryption %q", enc)
		}
		user := object{"id": credential, "encryption": enc}
		if flow := q.Get("flow"); flow != "" {
			if flow != "xtls-rprx-vision" && flow != "xtls-rprx-vision-udp443" {
				return model.Server{}, fmt.Errorf("vless: unsupported flow %q", flow)
			}
			user["flow"] = flow
		}
		settings["vnext"] = []any{object{"address": u.Hostname(), "port": port, "users": []any{user}}}
	case "trojan":
		if credential == "" {
			return model.Server{}, errors.New("empty Trojan password")
		}
		settings["servers"] = []any{object{"address": u.Hostname(), "port": port, "password": credential}}
		if q.Get("security") == "" {
			q.Set("security", "tls")
		}
	case "socks", "socks5":
		protocol = "socks"
		endpoint := object{"address": u.Hostname(), "port": port}
		if credential != "" {
			password, _ := u.User.Password()
			endpoint["users"] = []any{object{"user": credential, "pass": password}}
		}
		settings["servers"] = []any{endpoint}
	default:
		return model.Server{}, fmt.Errorf("unsupported scheme %q", u.Scheme)
	}
	stream, err := streamFromQuery(q)
	if err != nil {
		return model.Server{}, err
	}
	name, _ := url.PathUnescape(u.EscapedFragment())
	return ServerFromOutbound(name, object{"protocol": protocol, "settings": settings, "streamSettings": stream})
}

func defaultString(s, d string) string {
	if s == "" {
		return d
	}
	return s
}

func streamFromQuery(q url.Values) (object, error) {
	network := strings.ToLower(defaultString(q.Get("type"), "tcp"))
	stream := object{"network": network}
	security := strings.ToLower(defaultString(q.Get("security"), "none"))
	stream["security"] = security
	sni := defaultString(q.Get("sni"), q.Get("serverName"))
	fp := strings.ToLower(defaultString(q.Get("fp"), "chrome"))
	if !validFingerprint(fp) {
		return nil, fmt.Errorf("unknown TLS fingerprint %q", fp)
	}
	if sni != "" && !validHostName(sni) {
		return nil, fmt.Errorf("invalid sni %q", sni)
	}
	switch security {
	case "none":
	case "tls":
		tls := object{"fingerprint": fp}
		if sni != "" {
			tls["serverName"] = sni
		}
		if alpn := q.Get("alpn"); alpn != "" {
			tls["alpn"] = strings.Split(alpn, ",")
		}
		// Xray 26 removed allowInsecure; certificate pinning (pcs) and name checks (vcn) replace it.
		if pcs := q.Get("pcs"); pcs != "" {
			if !validCertPins(pcs) {
				return nil, errors.New("tls: pcs must be SHA-256 hashes (64 hex characters)")
			}
			tls["pinnedPeerCertSha256"] = pcs
		}
		if vcn := q.Get("vcn"); vcn != "" {
			tls["verifyPeerCertByName"] = vcn
		}
		stream["tlsSettings"] = tls
	case "reality":
		key := q.Get("pbk")
		if key == "" {
			return nil, errors.New("reality: missing pbk")
		}
		if !validRealityKey(key) {
			return nil, errors.New("reality: pbk must be a 32-byte base64url key")
		}
		if sni == "" {
			return nil, errors.New("reality: missing sni")
		}
		sid := q.Get("sid")
		if !validShortID(sid) {
			return nil, errors.New("reality: sid must be up to 16 hex characters, even length")
		}
		spx := q.Get("spx")
		if spx != "" && !strings.HasPrefix(spx, "/") {
			return nil, errors.New("reality: spx must start with /")
		}
		r := object{"fingerprint": fp, "serverName": sni, "publicKey": key, "shortId": sid, "spiderX": spx}
		if pqv := q.Get("pqv"); pqv != "" {
			r["mldsa65Verify"] = pqv
		}
		stream["realitySettings"] = r
	default:
		return nil, fmt.Errorf("unsupported security %q", security)
	}
	switch network {
	case "tcp", "raw":
		stream["network"] = "tcp"
		switch q.Get("headerType") {
		case "", "none":
		case "http":
			stream["tcpSettings"] = object{"header": object{"type": "http", "request": object{"path": []string{defaultString(q.Get("path"), "/")}, "headers": object{"Host": strings.Split(q.Get("host"), ",")}}}}
		default:
			return nil, errors.New("unsupported tcp headerType")
		}
	case "ws", "websocket":
		stream["network"] = "ws"
		ws := object{"path": defaultString(q.Get("path"), "/")}
		if h := q.Get("host"); h != "" {
			ws["headers"] = object{"Host": h}
		}
		stream["wsSettings"] = ws
	case "grpc":
		stream["grpcSettings"] = object{"serviceName": q.Get("serviceName"), "multiMode": q.Get("mode") == "multi"}
	case "httpupgrade":
		stream["httpupgradeSettings"] = object{"host": q.Get("host"), "path": defaultString(q.Get("path"), "/")}
	case "xhttp", "splithttp":
		stream["network"] = "xhttp"
		x := object{"host": q.Get("host"), "path": defaultString(q.Get("path"), "/"), "mode": defaultString(q.Get("mode"), "auto")}
		if extra := q.Get("extra"); extra != "" {
			var v object
			if json.Unmarshal([]byte(extra), &v) != nil {
				return nil, errors.New("invalid xhttp extra")
			}
			x["extra"] = v
		}
		stream["xhttpSettings"] = x
	default:
		return nil, fmt.Errorf("unsupported transport %q", network)
	}
	return stream, nil
}

func parseVMess(raw string) (model.Server, error) {
	b, err := DecodeBase64(raw[strings.Index(raw, "://")+3:])
	if err != nil {
		return model.Server{}, errors.New("vmess: invalid base64")
	}
	var v object
	dec := json.NewDecoder(strings.NewReader(string(b)))
	dec.UseNumber()
	if dec.Decode(&v) != nil {
		return model.Server{}, errors.New("vmess: invalid json")
	}
	if str(v["id"]) == "" {
		return model.Server{}, errors.New("vmess: empty id")
	}
	q := url.Values{}
	q.Set("type", defaultString(str(v["net"]), "tcp"))
	for _, key := range []string{"host", "path", "sni", "alpn", "fp"} {
		q.Set(key, str(v[key]))
	}
	q.Set("headerType", str(v["type"]))
	q.Set("serviceName", str(v["path"]))
	security := strings.ToLower(str(v["tls"]))
	if security == "" || security == "0" || security == "false" {
		security = "none"
	}
	q.Set("security", security)
	stream, err := streamFromQuery(q)
	if err != nil {
		return model.Server{}, err
	}
	port := number(v["port"])
	out := object{"protocol": "vmess", "settings": object{"vnext": []any{object{"address": str(v["add"]), "port": port, "users": []any{object{"id": str(v["id"]), "alterId": number(v["aid"]), "security": defaultString(str(v["scy"]), "auto")}}}}}, "streamSettings": stream}
	return ServerFromOutbound(str(v["ps"]), out)
}

func parseShadowsocks(raw string) (model.Server, error) {
	payload := raw[strings.Index(raw, "://")+3:]
	body, fragment, _ := strings.Cut(payload, "#")
	if !strings.Contains(body, "@") {
		main, query, _ := strings.Cut(body, "?")
		decoded, err := DecodeBase64(main)
		if err != nil {
			return model.Server{}, errors.New("ss: invalid base64")
		}
		body = string(decoded)
		if query != "" {
			body += "?" + query
		}
	}
	u, err := url.Parse("ss://" + body)
	if err != nil || u.User == nil {
		return model.Server{}, errors.New("ss: invalid link")
	}
	if u.Query().Get("plugin") != "" {
		return model.Server{}, errors.New("ss: plugins are not supported")
	}
	method := u.User.Username()
	password, hasPassword := u.User.Password()
	if !hasPassword {
		decoded, err := DecodeBase64(method)
		if err != nil {
			return model.Server{}, errors.New("ss: invalid userinfo")
		}
		m, p, ok := strings.Cut(string(decoded), ":")
		if !ok {
			return model.Server{}, errors.New("ss: missing password")
		}
		method, password = m, p
	}
	port, _ := strconv.Atoi(u.Port())
	name, _ := url.PathUnescape(fragment)
	return ServerFromOutbound(name, object{"protocol": "shadowsocks", "settings": object{"servers": []any{object{"address": u.Hostname(), "port": port, "method": method, "password": password}}}})
}

var uuidRe = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

// validVLESSID accepts a UUID or (as Xray does) any other string of 1–30 bytes mapped to a UUID.
func validVLESSID(id string) error {
	switch {
	case id == "":
		return errors.New("vless: empty id")
	case uuidRe.MatchString(id):
		return nil
	case len(id) <= 30 && !strings.ContainsAny(id, " \t"):
		return nil
	}
	return errors.New("vless: id is not a UUID")
}

var presetFingerprints = map[string]bool{"chrome": true, "firefox": true, "safari": true, "ios": true, "android": true, "edge": true,
	"360": true, "qq": true, "random": true, "randomized": true, "randomizednoalpn": true, "unsafe": true}

func validFingerprint(fp string) bool {
	return presetFingerprints[fp] || (strings.HasPrefix(fp, "hello") && len(fp) < 40)
}

func validRealityKey(k string) bool {
	for _, enc := range []*base64.Encoding{base64.RawURLEncoding, base64.URLEncoding, base64.RawStdEncoding, base64.StdEncoding} {
		if b, err := enc.DecodeString(k); err == nil && len(b) == 32 {
			return true
		}
	}
	return false
}

func validShortID(sid string) bool {
	if len(sid) > 16 || len(sid)%2 != 0 {
		return false
	}
	for _, r := range sid {
		if !(r >= '0' && r <= '9' || r >= 'a' && r <= 'f' || r >= 'A' && r <= 'F') {
			return false
		}
	}
	return true
}

func validHostName(h string) bool {
	if len(h) > 253 || strings.ContainsAny(h, " /\\@:?#") {
		return net.ParseIP(strings.Trim(h, "[]")) != nil
	}
	return h != ""
}

// validCertPins checks a comma-separated list of SHA-256 hashes (hex, colons allowed).
func validCertPins(v string) bool {
	for _, part := range strings.Split(v, ",") {
		h := strings.ReplaceAll(strings.TrimSpace(part), ":", "")
		if len(h) != 64 {
			return false
		}
		for _, r := range h {
			if !(r >= '0' && r <= '9' || r >= 'a' && r <= 'f' || r >= 'A' && r <= 'F') {
				return false
			}
		}
	}
	return true
}
