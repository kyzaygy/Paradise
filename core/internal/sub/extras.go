package sub

import (
	"encoding/base64"
	"errors"
	"net"
	"net/url"
	"strconv"
	"strings"

	"github.com/kyzaygy/paradise/core/internal/model"
)

// Keys that may follow the server name after "?" (Happ convention: "#Name?serverDescription=…").
var nameExtraKeys = []string{"serverDescription", "fragment", "noises", "resolve-address", "host"}

// applyNameExtras moves "?key=value" parameters out of the server name.
func applyNameExtras(srv *model.Server) {
	name, extra, ok := strings.Cut(srv.Name, "?")
	if !ok {
		return
	}
	q, err := url.ParseQuery(extra)
	if err != nil {
		return
	}
	known := false
	for _, k := range nameExtraKeys {
		if q.Has(k) {
			known = true
		}
	}
	if !known {
		return
	}
	srv.Name = strings.TrimSpace(name)
	if srv.Name == "" {
		srv.Name = net.JoinHostPort(srv.Address, strconv.Itoa(srv.Port))
	}
	if d := q.Get("serverDescription"); d != "" {
		if b, err := DecodeBase64(strings.ReplaceAll(d, " ", "+")); err == nil {
			srv.Desc = cleanText(string(b), 200)
		} else {
			srv.Desc = cleanText(d, 200)
		}
	}
	if f := ParseFragmentSpec(q.Get("fragment"), q["noises"]); f != nil && !udpBased(srv) {
		srv.Fragment = f
	}
}

func udpBased(srv *model.Server) bool {
	return srv.Protocol == "hysteria2" || srv.Protocol == "hysteria" || srv.Protocol == "wireguard"
}

// ParseFragmentSpec reads "length,interval,packets[,maxSplit]" and noises "type,packet,delay[,applyTo]".
func ParseFragmentSpec(spec string, noises []string) *model.Fragment {
	spec = strings.TrimSpace(spec)
	if spec == "" {
		return nil
	}
	parts := strings.Split(spec, ",")
	if len(parts) < 3 {
		return nil
	}
	for i := range parts {
		parts[i] = strings.TrimSpace(parts[i])
	}
	f := &model.Fragment{Length: parts[0], Interval: parts[1], Packets: strings.ToLower(parts[2])}
	if !model.ValidRange(f.Length) || !model.ValidRange(f.Interval) || (f.Packets != "tlshello" && !model.ValidRange(f.Packets)) {
		return nil
	}
	if len(parts) > 3 && model.ValidRange(parts[3]) {
		f.MaxSplit = parts[3]
	}
	for _, list := range noises {
		for _, item := range strings.Split(list, ";") {
			p := strings.Split(item, ",")
			if len(p) < 3 {
				continue
			}
			for i := range p {
				p[i] = strings.TrimSpace(p[i])
			}
			n := model.Noise{Type: strings.ToLower(p[0]), Packet: p[1], Delay: p[2]}
			if n.Type != "rand" && n.Type != "str" && n.Type != "base64" && n.Type != "hex" && n.Type != "array" {
				continue
			}
			if !model.ValidRange(n.Delay) || (n.Type == "rand" && !model.ValidRange(n.Packet)) {
				continue
			}
			if len(p) > 3 {
				switch strings.ToLower(p[3]) {
				case "ip", "ipv4", "ipv6":
					n.ApplyTo = strings.ToLower(p[3])
				}
			}
			if len(f.Noises) < 8 {
				f.Noises = append(f.Noises, n)
			}
		}
	}
	return f
}

func cleanText(s string, n int) string {
	s = strings.TrimSpace(strings.Map(func(r rune) rune {
		if r < 32 || r == 127 {
			return -1
		}
		return r
	}, s))
	if r := []rune(s); len(r) > n {
		return string(r[:n])
	}
	return s
}

// expandSocks rewrites Base64 forms of socks links:
// socks://<base64 user:pass>@host:port#Name and socks://<base64 of user:pass@host:port>#Name.
func expandSocks(raw string) string {
	i := strings.Index(raw, "://")
	scheme, rest := raw[:i], raw[i+3:]
	body, fragment, hasFragment := strings.Cut(rest, "#")
	suffix := ""
	if hasFragment {
		suffix = "#" + fragment
	}
	if at := strings.LastIndexByte(body, '@'); at >= 0 {
		user := body[:at]
		if !strings.Contains(user, ":") {
			if b, err := DecodeBase64(user); err == nil && strings.Contains(string(b), ":") && isPrintable(string(b)) {
				u, p, _ := strings.Cut(string(b), ":")
				return scheme + "://" + url.UserPassword(u, p).String() + body[at:] + suffix
			}
		}
		return raw
	}
	main, query, _ := strings.Cut(body, "?")
	if _, _, err := net.SplitHostPort(main); err == nil {
		return raw
	}
	b, err := DecodeBase64(main)
	if err != nil || !isPrintable(string(b)) {
		return raw
	}
	decoded := strings.TrimSpace(string(b))
	if at := strings.LastIndexByte(decoded, '@'); at >= 0 {
		u, p, _ := strings.Cut(decoded[:at], ":")
		decoded = url.UserPassword(u, p).String() + decoded[at:]
	}
	if query != "" {
		decoded += "?" + query
	}
	return scheme + "://" + decoded + suffix
}

func isPrintable(s string) bool {
	for _, r := range s {
		if r < 32 || r == 127 {
			return false
		}
	}
	return s != ""
}

// parseWireGuard reads wireguard://<private key>@host:port?publickey=…&address=…&mtu=…&reserved=…#Name.
func parseWireGuard(raw string) (model.Server, error) {
	u, err := url.Parse(raw)
	if err != nil || u.User == nil {
		return model.Server{}, errors.New("wireguard: invalid link")
	}
	port, err := strconv.Atoi(u.Port())
	if err != nil || port < 1 || port > 65535 || u.Hostname() == "" {
		return model.Server{}, errors.New("wireguard: invalid address or port")
	}
	q := u.Query()
	key := func(names ...string) string {
		for _, n := range names {
			if v := q.Get(n); v != "" {
				return strings.ReplaceAll(v, " ", "+")
			}
		}
		return ""
	}
	secret, _ := url.PathUnescape(u.User.Username())
	secret = strings.ReplaceAll(secret, " ", "+")
	if pw, ok := u.User.Password(); ok && secret == "" {
		secret = pw
	}
	secret, ok := wgKey(secret)
	if !ok {
		return model.Server{}, errors.New("wireguard: invalid private key")
	}
	public, ok := wgKey(key("publickey", "publicKey", "public_key", "peer"))
	if !ok {
		return model.Server{}, errors.New("wireguard: invalid public key")
	}
	peer := object{"publicKey": public, "endpoint": net.JoinHostPort(u.Hostname(), strconv.Itoa(port))}
	if raw := key("presharedkey", "preSharedKey", "psk"); raw != "" {
		psk, ok := wgKey(raw)
		if !ok {
			return model.Server{}, errors.New("wireguard: invalid pre-shared key")
		}
		peer["preSharedKey"] = psk
	}
	if ka, err := strconv.Atoi(q.Get("keepalive")); err == nil && ka > 0 && ka <= 600 {
		peer["keepAlive"] = ka
	}
	settings := object{"secretKey": secret, "peers": []any{peer}, "noKernelTun": true}
	var addresses []any
	for _, a := range strings.Split(defaultString(q.Get("address"), q.Get("ip")), ",") {
		a = strings.TrimSpace(a)
		if a == "" {
			continue
		}
		if !strings.Contains(a, "/") {
			if ip := net.ParseIP(a); ip != nil {
				if ip.To4() != nil {
					a += "/32"
				} else {
					a += "/128"
				}
			}
		}
		if _, _, err := net.ParseCIDR(a); err != nil {
			return model.Server{}, errors.New("wireguard: invalid address")
		}
		addresses = append(addresses, a)
	}
	if len(addresses) > 0 {
		settings["address"] = addresses
	}
	if mtu, err := strconv.Atoi(q.Get("mtu")); err == nil && mtu >= 576 && mtu <= 1500 {
		settings["mtu"] = mtu
	}
	if r := q.Get("reserved"); r != "" {
		var reserved []any
		for _, part := range strings.Split(r, ",") {
			n, err := strconv.Atoi(strings.TrimSpace(part))
			if err != nil || n < 0 || n > 255 {
				return model.Server{}, errors.New("wireguard: invalid reserved bytes")
			}
			reserved = append(reserved, n)
		}
		if len(reserved) != 3 {
			return model.Server{}, errors.New("wireguard: reserved needs 3 bytes")
		}
		settings["reserved"] = reserved
	}
	name, _ := url.PathUnescape(u.EscapedFragment())
	return ServerFromOutbound(name, object{"protocol": "wireguard", "settings": settings})
}

// wgKey validates a 32-byte key and returns it in standard Base64 (what Xray expects).
func wgKey(k string) (string, bool) {
	k = strings.TrimSpace(k)
	if k == "" {
		return "", false
	}
	for _, enc := range []*base64.Encoding{base64.StdEncoding, base64.RawStdEncoding, base64.URLEncoding, base64.RawURLEncoding} {
		if b, err := enc.DecodeString(k); err == nil && len(b) == 32 {
			return base64.StdEncoding.EncodeToString(b), true
		}
	}
	return "", false
}
