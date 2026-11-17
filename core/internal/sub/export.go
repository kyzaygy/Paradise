package sub

import (
	"encoding/base64"
	"encoding/json"
	"net"
	"net/url"
	"strconv"
	"strings"

	"github.com/kyzaygy/paradise/core/internal/model"
)

// ToURI converts a server back into a share link. Full Xray profiles have no link form.
func ToURI(srv model.Server) (string, bool) {
	if len(srv.Outbound) == 0 {
		return "", false
	}
	var out object
	if json.Unmarshal(srv.Outbound, &out) != nil {
		return "", false
	}
	settings := obj(out["settings"])
	stream := obj(out["streamSettings"])
	name := url.PathEscape(srv.Name)
	hostPort := net.JoinHostPort(srv.Address, strconv.Itoa(srv.Port))
	switch str(out["protocol"]) {
	case "vless":
		user := firstObject(firstObject(settings["vnext"])["users"])
		id := str(user["id"])
		if id == "" {
			return "", false
		}
		q := streamQuery(stream)
		q.Set("encryption", defaultString(str(user["encryption"]), "none"))
		if flow := str(user["flow"]); flow != "" {
			q.Set("flow", flow)
		}
		return "vless://" + url.PathEscape(id) + "@" + hostPort + "?" + q.Encode() + "#" + name, true
	case "trojan":
		pw := str(firstObject(settings["servers"])["password"])
		if pw == "" {
			return "", false
		}
		q := streamQuery(stream)
		return "trojan://" + url.PathEscape(pw) + "@" + hostPort + "?" + q.Encode() + "#" + name, true
	case "vmess":
		user := firstObject(firstObject(settings["vnext"])["users"])
		q := streamQuery(stream)
		v := map[string]any{
			"v": "2", "ps": srv.Name, "add": srv.Address, "port": strconv.Itoa(srv.Port), "id": str(user["id"]),
			"aid": strconv.Itoa(number(user["alterId"])), "scy": defaultString(str(user["security"]), "auto"),
			"net": q.Get("type"), "type": defaultString(q.Get("headerType"), "none"), "host": q.Get("host"),
			"path": defaultString(q.Get("path"), q.Get("serviceName")), "tls": "", "sni": q.Get("sni"),
			"alpn": q.Get("alpn"), "fp": q.Get("fp"),
		}
		if q.Get("security") == "tls" {
			v["tls"] = "tls"
		}
		b, _ := json.Marshal(v)
		return "vmess://" + base64.StdEncoding.EncodeToString(b), true
	case "shadowsocks":
		s := firstObject(settings["servers"])
		method, pw := str(s["method"]), str(s["password"])
		if method == "" || pw == "" {
			return "", false
		}
		user := base64.RawURLEncoding.EncodeToString([]byte(method + ":" + pw))
		return "ss://" + user + "@" + hostPort + "#" + name, true
	case "socks":
		s := firstObject(settings["servers"])
		auth := ""
		if u := firstObject(s["users"]); str(u["user"]) != "" {
			auth = url.UserPassword(str(u["user"]), str(u["pass"])).String() + "@"
		}
		return "socks://" + auth + hostPort + "#" + name, true
	case "hysteria":
		h := obj(stream["hysteriaSettings"])
		tls := obj(stream["tlsSettings"])
		q := url.Values{}
		if sni := str(tls["serverName"]); sni != "" {
			q.Set("sni", sni)
		}
		if alpn, ok := tls["alpn"].([]any); ok && len(alpn) > 0 {
			q.Set("alpn", joinAny(alpn))
		}
		for _, m := range asList(obj(stream["finalmask"])["udp"]) {
			mo := obj(m)
			ms := obj(mo["settings"])
			switch str(mo["type"]) {
			case "salamander":
				q.Set("obfs", "salamander")
				q.Set("obfs-password", str(ms["password"]))
			case "udphop":
				q.Set("mport", str(ms["remotePorts"]))
				if iv := number(ms["interval"]); iv > 0 {
					q.Set("hop-interval", strconv.Itoa(iv))
				}
			}
		}
		auth := url.PathEscape(str(h["auth"]))
		link := "hysteria2://" + auth + "@" + hostPort + "/"
		if len(q) > 0 {
			link += "?" + q.Encode()
		}
		return link + "#" + name, true
	case "wireguard":
		peer := firstObject(settings["peers"])
		q := url.Values{}
		q.Set("publickey", str(peer["publicKey"]))
		if psk := str(peer["preSharedKey"]); psk != "" {
			q.Set("presharedkey", psk)
		}
		if addrs := asList(settings["address"]); len(addrs) > 0 {
			q.Set("address", joinAny(addrs))
		}
		if mtu := number(settings["mtu"]); mtu > 0 {
			q.Set("mtu", strconv.Itoa(mtu))
		}
		if r := asList(settings["reserved"]); len(r) == 3 {
			q.Set("reserved", joinAny(r))
		}
		return "wireguard://" + url.QueryEscape(str(settings["secretKey"])) + "@" + hostPort + "?" + q.Encode() + "#" + name, true
	}
	return "", false
}

func asList(v any) []any {
	l, _ := v.([]any)
	return l
}

func joinAny(v []any) string {
	parts := make([]string, 0, len(v))
	for _, x := range v {
		parts = append(parts, str(x))
	}
	return strings.Join(parts, ",")
}

func streamQuery(stream object) url.Values {
	q := url.Values{}
	network := defaultString(str(stream["network"]), "tcp")
	if network == "raw" {
		network = "tcp"
	}
	q.Set("type", network)
	security := defaultString(str(stream["security"]), "none")
	q.Set("security", security)
	switch security {
	case "tls":
		t := obj(stream["tlsSettings"])
		setIf(q, "sni", str(t["serverName"]))
		setIf(q, "fp", str(t["fingerprint"]))
		if alpn, ok := t["alpn"].([]any); ok && len(alpn) > 0 {
			q.Set("alpn", joinAny(alpn))
		}
		if b, _ := t["allowInsecure"].(bool); b {
			q.Set("allowInsecure", "1")
		}
	case "reality":
		r := obj(stream["realitySettings"])
		setIf(q, "sni", str(r["serverName"]))
		setIf(q, "fp", str(r["fingerprint"]))
		setIf(q, "pbk", str(r["publicKey"]))
		setIf(q, "sid", str(r["shortId"]))
		setIf(q, "spx", str(r["spiderX"]))
		setIf(q, "pqv", str(r["mldsa65Verify"]))
	}
	switch network {
	case "tcp":
		h := obj(obj(stream["tcpSettings"])["header"])
		if str(h["type"]) == "http" {
			q.Set("headerType", "http")
			req := obj(h["request"])
			if p := asList(req["path"]); len(p) > 0 {
				q.Set("path", str(p[0]))
			}
			if hosts := asList(obj(req["headers"])["Host"]); len(hosts) > 0 {
				q.Set("host", joinAny(hosts))
			}
		}
	case "ws":
		w := obj(stream["wsSettings"])
		setIf(q, "path", str(w["path"]))
		setIf(q, "host", defaultString(str(w["host"]), str(obj(w["headers"])["Host"])))
	case "grpc":
		g := obj(stream["grpcSettings"])
		setIf(q, "serviceName", str(g["serviceName"]))
		if b, _ := g["multiMode"].(bool); b {
			q.Set("mode", "multi")
		}
	case "httpupgrade":
		h := obj(stream["httpupgradeSettings"])
		setIf(q, "path", str(h["path"]))
		setIf(q, "host", str(h["host"]))
	case "xhttp", "splithttp":
		x := obj(stream["xhttpSettings"])
		setIf(q, "path", str(x["path"]))
		setIf(q, "host", str(x["host"]))
		setIf(q, "mode", str(x["mode"]))
		if extra, ok := x["extra"].(map[string]any); ok && len(extra) > 0 {
			b, _ := json.Marshal(extra)
			q.Set("extra", string(b))
		}
	}
	return q
}

func setIf(q url.Values, k, v string) {
	if v != "" {
		q.Set(k, v)
	}
}
