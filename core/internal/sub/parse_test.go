package sub

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	"github.com/kyzaygy/paradise/core/internal/apperr"
)

const (
	vlessReality = "vless://11111111-2222-3333-4444-555555555555@example.com:443?type=tcp&security=reality&pbk=PUBKEY&sid=ab12&sni=www.microsoft.com&fp=chrome&flow=xtls-rprx-vision#%F0%9F%87%A9%F0%9F%87%AA%20Germany"
	vlessXHTTP   = "vless://11111111-2222-3333-4444-555555555555@x.example.com:443?type=xhttp&security=tls&sni=x.example.com&path=%2Fapi&mode=packet-up&alpn=h2,http/1.1#XHTTP"
	trojanWS     = "trojan://secret@t.example.com:8443?type=ws&path=%2Fws&host=cdn.example.com#Trojan"
)

func vmessLink() string {
	j := `{"v":"2","ps":"VMess node","add":"v.example.com","port":"443","id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","aid":"0","net":"ws","type":"none","host":"v.example.com","path":"/vm","tls":"tls","sni":"v.example.com"}`
	return "vmess://" + base64.StdEncoding.EncodeToString([]byte(j))
}

func TestParseURIProtocols(t *testing.T) {
	cases := []struct {
		link, protocol, network, security, name string
	}{
		{vlessReality, "vless", "tcp", "reality", "🇩🇪 Germany"},
		{vlessXHTTP, "vless", "xhttp", "tls", "XHTTP"},
		{trojanWS, "trojan", "ws", "tls", "Trojan"},
		{vmessLink(), "vmess", "ws", "tls", "VMess node"},
		{"ss://" + base64.RawURLEncoding.EncodeToString([]byte("aes-256-gcm:pa:ss")) + "@s.example.com:8388#SS%20one", "shadowsocks", "tcp", "none", "SS one"},
		{"ss://" + base64.StdEncoding.EncodeToString([]byte("chacha20-ietf-poly1305:pw@legacy.example.com:8389")) + "#Legacy", "shadowsocks", "tcp", "none", "Legacy"},
		{"ss://2022-blake3-aes-128-gcm:a2V5@s2.example.com:443#SS2022", "shadowsocks", "tcp", "none", "SS2022"},
	}
	for _, c := range cases {
		srv, err := ParseURI(c.link)
		if err != nil {
			t.Fatalf("%s: %v", c.name, err)
		}
		if srv.Protocol != c.protocol || srv.Network != c.network || srv.Security != c.security || srv.Name != c.name {
			t.Fatalf("%s: got %+v", c.name, srv)
		}
		if srv.Key == "" || len(srv.Outbound) == 0 {
			t.Fatalf("%s: missing key or outbound", c.name)
		}
		var out map[string]any
		if err := json.Unmarshal(srv.Outbound, &out); err != nil || out["tag"] != "proxy" {
			t.Fatalf("%s: bad outbound %s", c.name, srv.Outbound)
		}
	}
}

func TestRealityFields(t *testing.T) {
	srv, err := ParseURI(vlessReality)
	if err != nil {
		t.Fatal(err)
	}
	s := string(srv.Outbound)
	for _, want := range []string{`"publicKey":"PUBKEY"`, `"shortId":"ab12"`, `"flow":"xtls-rprx-vision"`, `"serverName":"www.microsoft.com"`} {
		if !strings.Contains(s, want) {
			t.Fatalf("missing %s in %s", want, s)
		}
	}
}

func TestParseURIErrors(t *testing.T) {
	for _, bad := range []string{
		"vless://@example.com:443",
		"vless://id@example.com:0",
		"vless://id@example.com:443?security=reality&sni=a",
		"hysteria2://pw@h.example.com:443",
		"ss://YWVzLTI1Ni1nY206cGFzcw@s.example.com:8388?plugin=obfs-local",
		"vless://id@example.com:443?type=quic",
	} {
		if _, err := ParseURI(bad); err == nil {
			t.Fatalf("expected error for %s", bad)
		}
	}
}

func TestParseBase64ListWithWarnings(t *testing.T) {
	body := strings.Join([]string{vlessReality, "garbage line", trojanWS, vlessReality}, "\n")
	enc := base64.StdEncoding.EncodeToString([]byte(body))
	p, err := Parse([]byte(enc), "sub123456")
	if err != nil {
		t.Fatal(err)
	}
	if p.Format != "base64" || len(p.Servers) != 2 || len(p.Warnings) != 1 {
		t.Fatalf("got format=%s servers=%d warnings=%v", p.Format, len(p.Servers), p.Warnings)
	}
	if !strings.HasPrefix(p.Servers[0].ID, "sub12345-") {
		t.Fatalf("bad id %s", p.Servers[0].ID)
	}
}

func TestParseBodyMetadata(t *testing.T) {
	body := "#profile-title: base64:" + base64.StdEncoding.EncodeToString([]byte("Мой VPN")) + "\n#profile-update-interval: 12\n" + vlessReality
	p, err := Parse([]byte(body), "s")
	if err != nil {
		t.Fatal(err)
	}
	m := ParseMeta(p.Headers)
	if m == nil || m.Title != "Мой VPN" || m.UpdateHours != 12 {
		t.Fatalf("meta %+v", m)
	}
}

func TestParseMetaHeaders(t *testing.T) {
	h := http.Header{}
	h.Set("subscription-userinfo", "upload=10; download=20; total=1000; expire=1893456000")
	h.Set("support-url", "https://t.me/support")
	h.Set("profile-web-page-url", "javascript:alert(1)")
	m := ParseMeta(h)
	if m.Upload != 10 || m.Download != 20 || m.Total != 1000 || m.Expire != 1893456000 || m.SupportURL == "" || m.WebURL != "" {
		t.Fatalf("meta %+v", m)
	}
	if ParseMeta(http.Header{}) != nil {
		t.Fatal("empty meta must be nil")
	}
}

func TestParseXrayJSON(t *testing.T) {
	profile := `[{"remarks":"Full NL","outbounds":[{"tag":"proxy","protocol":"vless","settings":{"vnext":[{"address":"nl.example.com","port":443,"users":[{"id":"u","encryption":"none"}]}]},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"serverName":"a.com","publicKey":"k"}}},{"tag":"direct","protocol":"freedom"}],"routing":{"rules":[{"type":"field","domain":["geosite:category-ru"],"outboundTag":"direct"}]}},
	{"protocol":"trojan","tag":"single","settings":{"servers":[{"address":"t.example.com","port":443,"password":"p"}]}}]`
	p, err := Parse([]byte(profile), "s")
	if err != nil {
		t.Fatal(err)
	}
	if len(p.Servers) != 2 || p.Format != "xray-json" {
		t.Fatalf("servers %d format %s", len(p.Servers), p.Format)
	}
	full := p.Servers[0]
	if full.Name != "Full NL" || len(full.Profile) == 0 || len(full.Outbound) != 0 || full.Address != "nl.example.com" {
		t.Fatalf("full profile %+v", full)
	}
	if p.Servers[1].Name != "single" || p.Servers[1].Protocol != "trojan" {
		t.Fatalf("single %+v", p.Servers[1])
	}
}

func TestParseHTMLAndEmpty(t *testing.T) {
	_, err := Parse([]byte("<!DOCTYPE html><html></html>"), "s")
	if apperr.From(err).Code != apperr.HTMLResponse {
		t.Fatalf("got %v", err)
	}
	_, err = Parse([]byte("vless://broken"), "s")
	if apperr.From(err).Code != apperr.EmptySubscription {
		t.Fatalf("got %v", err)
	}
	_, err = Parse([]byte("%%%not base64%%%"), "s")
	if apperr.From(err).Code != apperr.UnsupportedFormat {
		t.Fatalf("got %v", err)
	}
}

func TestStableKeys(t *testing.T) {
	a, _ := ParseURI(vlessReality)
	b, _ := ParseURI(vlessReality)
	if a.Key != b.Key {
		t.Fatal("keys differ")
	}
	var m map[string]any
	_ = json.Unmarshal(a.Outbound, &m)
	c, err := ServerFromOutbound(a.Name, m)
	if err != nil || c.Key != a.Key {
		t.Fatalf("roundtrip key differs: %v", err)
	}
}
