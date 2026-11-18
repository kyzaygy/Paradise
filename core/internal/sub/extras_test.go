package sub

import (
	"encoding/base64"
	"strings"
	"testing"
)

func TestSocksBase64Forms(t *testing.T) {
	partial := "socks://" + base64.StdEncoding.EncodeToString([]byte("user:pass")) + "@1.2.3.4:1080#Partial"
	full := "socks://" + base64.StdEncoding.EncodeToString([]byte("user:p@ss@5.6.7.8:1081")) + "#Full"
	plain := "socks://9.9.9.9:1082#Open"
	for _, c := range []struct{ link, addr, name, user string }{
		{partial, "1.2.3.4", "Partial", `"user":"user"`},
		{full, "5.6.7.8", "Full", `"pass":"p@ss"`},
		{plain, "9.9.9.9", "Open", ""},
	} {
		srv, err := ParseURI(c.link)
		if err != nil {
			t.Fatalf("%s: %v", c.name, err)
		}
		if srv.Address != c.addr || srv.Name != c.name || srv.Protocol != "socks" {
			t.Fatalf("%s: %+v", c.name, srv)
		}
		if c.user != "" && !strings.Contains(string(srv.Outbound), c.user) {
			t.Fatalf("%s: %s", c.name, srv.Outbound)
		}
	}
}

func TestNameExtras(t *testing.T) {
	desc := base64.StdEncoding.EncodeToString([]byte("Fast node"))
	link := vlessReality[:strings.Index(vlessReality, "#")] + "#NL%201?serverDescription=" + desc + "&fragment=1-10,5-20,tlshello&noises=rand,50-150,10-50,ip"
	srv, err := ParseURI(link)
	if err != nil {
		t.Fatal(err)
	}
	if srv.Name != "NL 1" || srv.Desc != "Fast node" {
		t.Fatalf("%+v", srv)
	}
	if srv.Fragment == nil || srv.Fragment.Packets != "tlshello" || srv.Fragment.Length != "1-10" || len(srv.Fragment.Noises) != 1 || srv.Fragment.Noises[0].ApplyTo != "ip" {
		t.Fatalf("fragment %+v", srv.Fragment)
	}
	q, err := ParseURI(vlessReality[:strings.Index(vlessReality, "#")] + "#What%3F")
	if err != nil || q.Name != "What?" {
		t.Fatalf("plain question mark: %+v %v", q, err)
	}
}

func TestWireGuard(t *testing.T) {
	key := base64.StdEncoding.EncodeToString(make([]byte, 32))
	pub := base64.URLEncoding.EncodeToString([]byte(strings.Repeat("\xfb", 32)))
	link := "wireguard://" + strings.ReplaceAll(key, "+", "%2B") + "@162.159.192.1:2408?publickey=" + pub + "&address=172.16.0.2/32,2606:4700::2&mtu=1280&reserved=1,2,3#WARP"
	srv, err := ParseURI(link)
	if err != nil {
		t.Fatal(err)
	}
	if srv.Protocol != "wireguard" || srv.Address != "162.159.192.1" || srv.Port != 2408 || srv.Network != "udp" || srv.Name != "WARP" {
		t.Fatalf("%+v", srv)
	}
	s := string(srv.Outbound)
	for _, want := range []string{`"noKernelTun":true`, `"reserved":[1,2,3]`, `"2606:4700::2/128"`, `"publicKey":"` + base64.StdEncoding.EncodeToString([]byte(strings.Repeat("\xfb", 32)))} {
		if !strings.Contains(s, want) {
			t.Fatalf("missing %s in %s", want, s)
		}
	}
	if _, err := ParseURI("wireguard://bad@1.2.3.4:51820?publickey=x"); err == nil {
		t.Fatal("bad key accepted")
	}
}

func TestRoutingLinesInBody(t *testing.T) {
	body := vlessReality + "\nhapp://routing/add/eyJOYW1lIjoiUlUifQ==\nhapp://crypt3/abc\n"
	p, err := Parse([]byte(body), "sub")
	if err != nil {
		t.Fatal(err)
	}
	if len(p.Servers) != 1 || len(p.Routing) != 1 || len(p.Warnings) != 1 {
		t.Fatalf("%+v", p)
	}
	only, err := Parse([]byte("happ://routing/onadd/eyJOYW1lIjoiUlUifQ=="), "sub")
	if err != nil || only.Format != "routing" || len(only.Routing) != 1 {
		t.Fatalf("routing only: %+v %v", only, err)
	}
}

func TestExportRoundTrip(t *testing.T) {
	key := base64.StdEncoding.EncodeToString(make([]byte, 32))
	links := []string{
		vlessReality, vlessXHTTP, trojanWS, vmessLink(),
		"ss://" + base64.RawURLEncoding.EncodeToString([]byte("aes-256-gcm:pa:ss")) + "@s.example.com:8388#SS%20one",
		"socks://user:pw@1.2.3.4:1080#S",
		"hysteria2://pass@h.example.com:443?sni=h.example.com&obfs=salamander&obfs-password=secretpw#HY",
		"wireguard://" + strings.ReplaceAll(key, "+", "%2B") + "@1.1.1.1:51820?publickey=" + key + "&address=10.0.0.2/32#WG",
	}
	for _, l := range links {
		a, err := ParseURI(l)
		if err != nil {
			t.Fatalf("%s: %v", l, err)
		}
		out, ok := ToURI(a)
		if !ok {
			t.Fatalf("no link for %s", a.Name)
		}
		b, err := ParseURI(out)
		if err != nil {
			t.Fatalf("re-parse %s: %v", out, err)
		}
		if a.Key != b.Key || a.Name != b.Name {
			t.Fatalf("round trip changed %s:\n%s\n%s\n%s", a.Name, out, a.Outbound, b.Outbound)
		}
	}
}

func TestVLESSValidation(t *testing.T) {
	base := "vless://11111111-2222-3333-4444-555555555555@example.com:443?type=tcp&security=reality&pbk=Z84J2IelR9ch3k8VtlVhhs5ycBUlXA7wHBWcBrjqnAw&sid=ab12&sni=www.microsoft.com&fp=chrome&flow=xtls-rprx-vision#R"
	if _, err := ParseURI(base); err != nil {
		t.Fatal(err)
	}
	bad := map[string]string{
		"pbk":  strings.Replace(base, "pbk=Z84J2IelR9ch3k8VtlVhhs5ycBUlXA7wHBWcBrjqnAw", "pbk=short", 1),
		"sid":  strings.Replace(base, "sid=ab12", "sid=xyz", 1),
		"odd":  strings.Replace(base, "sid=ab12", "sid=abc", 1),
		"flow": strings.Replace(base, "flow=xtls-rprx-vision", "flow=xtls-rprx-direct", 1),
		"fp":   strings.Replace(base, "fp=chrome", "fp=netscape", 1),
		"id":   strings.Replace(base, "11111111-2222-3333-4444-555555555555", "this-is-a-very-long-identifier-that-is-not-a-uuid", 1),
		"enc":  strings.Replace(base, "type=tcp", "type=tcp&encryption=aes-128-gcm", 1),
		"spx":  strings.Replace(base, "fp=chrome", "fp=chrome&spx=abc", 1),
	}
	for name, link := range bad {
		if _, err := ParseURI(link); err == nil {
			t.Errorf("%s accepted", name)
		}
	}
	short := strings.Replace(base, "11111111-2222-3333-4444-555555555555", "my-custom-id", 1)
	if _, err := ParseURI(short); err != nil {
		t.Errorf("short id rejected: %v", err)
	}
}

func TestWireGuardConf(t *testing.T) {
	key := base64.StdEncoding.EncodeToString(make([]byte, 32))
	conf := "# Name = Germany Frankfurt\n[Interface]\nPrivateKey = " + key + "\nAddress = 10.8.0.2/32, fd00::2/128\nDNS = 1.1.1.1\nMTU = 1280\n\n[Peer]\nPublicKey = " + key + "\nPresharedKey = " + key + "\nAllowedIPs = 0.0.0.0/0, ::/0\nEndpoint = de.example.com:51820\nPersistentKeepalive = 25\n"
	if !IsWireGuardConf(conf) {
		t.Fatal("not detected")
	}
	p, err := Parse([]byte(conf), "s")
	if err != nil || len(p.Servers) != 1 || p.Format != "wireguard" {
		t.Fatalf("%+v %v", p, err)
	}
	srv := p.Servers[0]
	if srv.Name != "Germany Frankfurt" || srv.Address != "de.example.com" || srv.Port != 51820 || srv.Protocol != "wireguard" {
		t.Fatalf("%+v", srv)
	}
	out := string(srv.Outbound)
	for _, want := range []string{`"keepAlive":25`, `"mtu":1280`, `"allowedIPs":["0.0.0.0/0","::/0"]`, `"preSharedKey"`, `"10.8.0.2/32"`} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %s in %s", want, out)
		}
	}
	if _, err := Parse([]byte(strings.Replace(conf, "Endpoint = de.example.com:51820", "Endpoint = nope", 1)), "s"); err == nil {
		t.Error("bad endpoint accepted")
	}
	if l, ok := ToURI(srv); !ok || !strings.HasPrefix(l, "wireguard://") {
		t.Errorf("export %v", l)
	}
}

func TestCertPinning(t *testing.T) {
	pin := strings.Repeat("ab", 32)
	srv, err := ParseURI("trojan://pw@t.example.com:443?security=tls&sni=t.example.com&allowInsecure=1&pcs=" + pin + "&vcn=t.example.com#T")
	if err != nil {
		t.Fatal(err)
	}
	out := string(srv.Outbound)
	if strings.Contains(out, "allowInsecure") || !strings.Contains(out, `"pinnedPeerCertSha256":"`+pin+`"`) || !strings.Contains(out, `"verifyPeerCertByName":"t.example.com"`) {
		t.Fatalf("%s", out)
	}
	hy, err := ParseURI("hysteria2://pass@h.example.com:443?sni=h.example.com&pinSHA256=" + pin + "#H")
	if err != nil || !strings.Contains(string(hy.Outbound), "pinnedPeerCertSha256") {
		t.Fatalf("%v %s", err, hy.Outbound)
	}
	if _, err := ParseURI("trojan://pw@t.example.com:443?security=tls&pcs=nothex#T"); err == nil {
		t.Fatal("bad pin accepted")
	}
	if l, ok := ToURI(srv); !ok || !strings.Contains(l, "pcs="+pin) {
		t.Fatalf("export %s", l)
	}
}
