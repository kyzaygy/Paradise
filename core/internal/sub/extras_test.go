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
