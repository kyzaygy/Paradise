package rules

import (
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
)

type fakeGeo struct{ ip, site map[string][]string }

func (f fakeGeo) IP(c string) ([]string, bool)   { v, ok := f.ip[c]; return v, ok }
func (f fakeGeo) Site(c string) ([]string, bool) { v, ok := f.site[c]; return v, ok }

const sample = `# test
[General]
bypass-system = true
skip-proxy = 192.168.0.0/16, *.local, localhost
tun-excluded-routes = 10.0.0.0/8, bad
dns-server = https://1.1.1.1/dns-query, 8.8.8.8, tls://x
ipv6 = false
always-real-ip = *.apple.com

[Proxy]
a = ss, 1.2.3.4

[Rule]
DOMAIN-SUFFIX,google.com,PROXY
DOMAIN-SUFFIX,youtube.com,PROXY
DOMAIN,ads.example.com,REJECT
DOMAIN-KEYWORD,tracker,REJECT-TINYGIF
IP-CIDR,1.1.1.0/24,DIRECT,no-resolve
IP-CIDR6,2001:db8::/32,DIRECT
GEOIP,RU,DIRECT
GEOSITE,category-ads,REJECT
DST-PORT,123,DIRECT
USER-AGENT,Instagram*,DIRECT
RULE-SET,https://example.com/set.list,MyGroup
DOMAIN-SET,https://example.com/domains.txt,DIRECT
RULE-SET,https://example.com/missing.list,PROXY
FINAL,PROXY

[Host]
router.local = 192.168.1.1
*.corp = server:10.0.0.53
`

func TestParseAndCompile(t *testing.T) {
	c := Parse(sample)
	if c.Final != Proxy {
		t.Fatalf("final %q", c.Final)
	}
	codes := map[string]bool{}
	for _, w := range c.Warnings {
		codes[w.Code] = true
	}
	if !codes[WarnUnsupportedRule] || !codes[WarnUnsupportedPolicy] {
		t.Fatalf("warnings: %v", c.Warnings)
	}
	if len(c.Ignored) != 2 { // always-real-ip, [Proxy]
		t.Fatalf("ignored: %v", c.Ignored)
	}
	geo := fakeGeo{ip: map[string][]string{"ru": {"5.0.0.0/8", "31.0.0.0/8"}}, site: map[string][]string{}}
	sets := func(u string) ([]string, bool) {
		switch u {
		case "https://example.com/set.list":
			return []string{"# c", "DOMAIN-SUFFIX,a.com", "IP-CIDR,9.9.9.0/24,no-resolve", "URL-REGEX,^x"}, true
		case "https://example.com/domains.txt":
			return []string{".b.com", "c.com", ""}, true
		}
		return nil, false
	}
	out := Compile(c, Options{Geo: geo, Sets: sets})
	b, _ := json.Marshal(out.Rules)
	s := string(b)
	for _, want := range []string{
		`{"ip":["192.168.0.0/16"],"outboundTag":"direct"}`,
		`"domain:local","full:localhost"`,
		`{"domain":["domain:google.com","domain:youtube.com"],"outboundTag":"proxy"}`,
		`{"domain":["full:ads.example.com","keyword:tracker"],"outboundTag":"block"}`,
		`"5.0.0.0/8","31.0.0.0/8"`,
		`{"outboundTag":"direct","port":"123"}`,
		`{"domain":["domain:a.com"],"outboundTag":"proxy"}`,
		`{"ip":["9.9.9.0/24"],"outboundTag":"proxy"}`,
		`{"domain":["domain:b.com","full:c.com"],"outboundTag":"direct"}`,
		`{"network":"tcp,udp","outboundTag":"proxy"}`,
	} {
		if !strings.Contains(s, want) {
			t.Errorf("missing %s in %s", want, s)
		}
	}
	if out.DomainStrategy != "IPIfNonMatch" {
		t.Errorf("strategy %s", out.DomainStrategy)
	}
	if len(out.MissingGeo) != 1 || out.MissingGeo[0] != "geosite:category-ads" {
		t.Errorf("missing geo %v", out.MissingGeo)
	}
	if len(out.MissingSets) != 1 {
		t.Errorf("missing sets %v", out.MissingSets)
	}
	if !out.Hijack || len(out.DNSServers) != 3 || out.Hosts["router.local"] != "192.168.1.1" {
		t.Errorf("dns %v %v %v", out.Hijack, out.DNSServers, out.Hosts)
	}
	if out.IPv6 == nil || *out.IPv6 {
		t.Errorf("ipv6")
	}
	if len(out.Excluded) != 1 || out.Excluded[0] != "10.0.0.0/8" {
		t.Errorf("excluded %v", out.Excluded)
	}
}

func TestDefaultCompiles(t *testing.T) {
	c := Parse(DefaultText)
	if len(c.Warnings) != 0 {
		t.Fatalf("warnings %v", c.Warnings)
	}
	out := Compile(c, Options{})
	if out.Hijack {
		t.Fatalf("default config must keep system DNS, got hijack with %v", out.Hosts)
	}
}

func TestGeoDat(t *testing.T) {
	ip := EncodeGeoIPForTest(map[string][]string{"ru": {"5.0.0.0/8", "2a00::/16"}, "cn": {"1.0.1.0/24"}})
	got, err := ReadGeoIP(ip, map[string]bool{"ru": true})
	if err != nil || len(got["ru"]) != 2 || got["ru"][0] != "5.0.0.0/8" || got["ru"][1] != "2a00::/16" || got["cn"] != nil {
		t.Fatalf("geoip %v %v", got, err)
	}
	site := EncodeGeoSiteForTest(map[string][]string{"google": {"domain:google.com", "full:www.google.cn@cn", "keyword:gstatic"}})
	gs, err := ReadGeoSite(site, map[string]bool{"google": true, "google@cn": true, "absent": true})
	if err != nil || len(gs["google"]) != 3 || len(gs["google@cn"]) != 1 || gs["google@cn"][0] != "full:www.google.cn" {
		t.Fatalf("geosite %v %v", gs, err)
	}
	if _, ok := gs["absent"]; ok {
		t.Fatalf("absent code returned")
	}
	codes, _ := GeoCodes(site)
	if len(codes) != 1 || codes[0] != "google" {
		t.Fatalf("codes %v", codes)
	}
	if _, err := ReadGeoIP([]byte{0x0a, 0xff}, map[string]bool{"x": true}); err == nil {
		t.Fatalf("corrupt data accepted")
	}
}

func TestRoutingLink(t *testing.T) {
	profile := map[string]any{
		"Name": "RU", "GlobalProxy": "true", "RemoteDNSType": "DoH", "RemoteDNSDomain": "https://cloudflare-dns.com/dns-query",
		"Geoipurl": "https://example.com/geoip.dat", "DirectSites": []any{"geosite:category-ru", "domain:yandex.ru"},
		"DirectIp": []any{"geoip:ru", "10.0.0.0/8"}, "BlockSites": []any{"geosite:category-ads-all"},
		"DnsHosts": map[string]any{"cloudflare-dns.com": "1.1.1.1"},
	}
	b, _ := json.Marshal(profile)
	link := "happ://routing/onadd/" + base64.StdEncoding.EncodeToString(b)
	if !IsRoutingLink(link) {
		t.Fatal("not detected")
	}
	r, err := ParseRoutingLink(link)
	if err != nil || !r.Activate || r.Name != "RU" {
		t.Fatalf("%+v %v", r, err)
	}
	c := Parse(r.Text)
	if len(c.Warnings) != 0 {
		t.Fatalf("warnings %v\n%s", c.Warnings, r.Text)
	}
	if c.General["geoip-url"] != "https://example.com/geoip.dat" || c.Final != Proxy || len(c.Hosts) != 1 {
		t.Fatalf("parsed %+v", c)
	}
	if !strings.Contains(r.Text, "GEOSITE,category-ads-all,REJECT") || !strings.Contains(r.Text, "GEOIP,ru,DIRECT,no-resolve") {
		t.Fatalf("text:\n%s", r.Text)
	}
	off, err := ParseRoutingLink("happ://routing/off")
	if err != nil || !off.Off {
		t.Fatal("off")
	}
}
