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
	if out.DNSServers[1] != "https+local://1.1.1.1/dns-query" || len(out.DNSDirect) != 2 { // 8.8.8.8 and the [Host] server
		t.Errorf("dns mapping %v direct %v", out.DNSServers, out.DNSDirect)
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

// simple.conf from the user (zeklop/shadowrocket-configs), trimmed to what matters.
const simpleConf = `# Shadowrocket: 2026-11-18 00:46:41
[General]
bypass-system = true
skip-proxy = 127.0.0.1, 192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12, localhost, *.local, captive.apple.com
bypass-tun = 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.0.2.0/24, 192.88.99.0/24, 192.168.0.0/16, 198.18.0.0/15, 198.51.100.0/24, 203.0.113.0/24, 224.0.0.0/4, 255.255.255.255/32
dns-server = quic://dns11.quad9.net, tls://common.dot.dns.yandex.net
fallback-dns-server = https://dns.google/dns-query#proxy, https://cloudflare-dns.com/dns-query#proxy, system
update-url = https://raw.githubusercontent.com/zeklop/shadowrocket-configs/main/simple.conf interval=60 strict=true

[Rule]
RULE-SET,https://raw.githubusercontent.com/zeklop/shadowrocket-configs/main/REJECT.list,REJECT
RULE-SET,https://raw.githubusercontent.com/zeklop/shadowrocket-configs/main/RUSSIA.list,DIRECT
DOMAIN-SUFFIX,ru,DIRECT
#GEOIP,RU,DIRECT
FINAL,PROXY

[URL Rewrite]
'^https://(www.)?yandex.ru' 'https://ya.ru' 302
`

func TestSimpleConf(t *testing.T) {
	c := Parse(simpleConf)
	sets := func(u string) ([]string, bool) {
		if strings.HasSuffix(u, "REJECT.list") {
			return []string{"DOMAIN-SUFFIX,doubleclick.net", "DOMAIN-KEYWORD,adservice"}, true
		}
		return []string{"DOMAIN-SUFFIX,vk.com", "DOMAIN-SUFFIX,ozon.ru", "IP-CIDR,95.142.192.0/20,no-resolve"}, true
	}
	out := Compile(c, Options{Sets: sets})
	if len(out.Excluded) != 14 || out.Excluded[11] != "203.0.113.0/24" {
		t.Fatalf("bypass-tun: %v", out.Excluded)
	}
	want := []any{"quic+local://dns11.quad9.net", "https://dns.google/dns-query", "https://cloudflare-dns.com/dns-query", "localhost"}
	if len(out.DNSServers) != len(want) {
		t.Fatalf("dns %v", out.DNSServers)
	}
	for i := range want {
		if out.DNSServers[i] != want[i] {
			t.Fatalf("dns %v", out.DNSServers)
		}
	}
	if !out.Hijack || out.UpdateMinutes != 60 || !strings.HasSuffix(out.UpdateURL, "simple.conf") {
		t.Fatalf("hijack %v update %q %d", out.Hijack, out.UpdateURL, out.UpdateMinutes)
	}
	dotWarned := false
	for _, w := range out.Warnings {
		if w.Code == WarnUnsupportedDNS && strings.HasPrefix(w.Text, "tls://") {
			dotWarned = true
		} else {
			t.Errorf("unexpected warning %v", w)
		}
	}
	if !dotWarned {
		t.Error("DoT must be reported")
	}
	ign := strings.Join(c.Ignored, ",")
	if !strings.Contains(ign, "[URL Rewrite]") {
		t.Errorf("ignored %v", c.Ignored)
	}
	b, _ := json.Marshal(out.Rules)
	for _, s := range []string{`"domain:doubleclick.net","keyword:adservice"],"outboundTag":"block"`, `"domain:vk.com","domain:ozon.ru"],"outboundTag":"direct"`, `"95.142.192.0/20"`, `"domain:ru"`, `{"network":"tcp,udp","outboundTag":"proxy"}`} {
		if !strings.Contains(string(b), s) {
			t.Errorf("missing %s in %s", s, b)
		}
	}
}
