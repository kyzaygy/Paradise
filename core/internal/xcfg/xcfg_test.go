package xcfg

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/kyzaygy/paradise/core/internal/model"
	"github.com/kyzaygy/paradise/core/internal/rules"
)

func TestTunnelSingleOutbound(t *testing.T) {
	srv := model.Server{Outbound: json.RawMessage(`{"protocol":"trojan","tag":"x","settings":{"servers":[{"address":"a.com","port":443,"password":"p"}]}}`)}
	res, err := Tunnel(srv, Options{Settings: model.DefaultSettings()})
	if err != nil {
		t.Fatal(err)
	}
	var cfg map[string]any
	if err := json.Unmarshal(res.JSON, &cfg); err != nil {
		t.Fatal(err)
	}
	in := cfg["inbounds"].([]any)[0].(map[string]any)
	if in["protocol"] != "tun" {
		t.Fatalf("inbound %v", in)
	}
	outs := cfg["outbounds"].([]any)
	if outs[0].(map[string]any)["tag"] != "proxy" || len(outs) != 3 || res.Net.MTU != 1500 || len(res.Net.Excluded) == 0 {
		t.Fatalf("outbounds %v", outs)
	}
	if cfg["log"].(map[string]any)["access"] != "none" {
		t.Fatal("access log must be off")
	}
}

const profile = `{"remarks":"P","log":{"access":"/tmp/a.log"},"api":{"tag":"api"},"inbounds":[{"protocol":"socks","port":1080}],
"outbounds":[{"tag":"main","protocol":"vless","settings":{}},{"tag":"block","protocol":"blackhole"}],
"routing":{"rules":[
 {"type":"field","domain":["geosite:category-ru"],"outboundTag":"direct"},
 {"type":"field","domain":["geosite:ads","example.org"],"outboundTag":"block"},
 {"type":"field","ip":["geoip:private"],"outboundTag":"direct"},
 {"type":"field","ip":["geoip:ru"],"outboundTag":"direct"},
 {"type":"field","network":"tcp,udp","outboundTag":"main"}]},
"dns":{"hosts":{"geosite:x":"1.1.1.1","a.com":"2.2.2.2"},"servers":[{"address":"1.1.1.1","domains":["geosite:ru"]},"8.8.8.8"]}}`

func TestProfileKeepRoutingSanitizes(t *testing.T) {
	s := model.DefaultSettings()
	s.Mode = "profile"
	res, err := Tunnel(model.Server{Profile: json.RawMessage(profile)}, Options{Settings: s})
	if err != nil {
		t.Fatal(err)
	}
	if res.DroppedRules != 2 {
		t.Fatalf("dropped %d", res.DroppedRules)
	}
	out := string(res.JSON)
	for _, bad := range []string{"geosite:", "geoip:", `"api"`, "/tmp/a.log", `"socks"`} {
		if strings.Contains(out, bad) {
			t.Fatalf("config still contains %s: %s", bad, out)
		}
	}
	for _, want := range []string{"example.org", "10.0.0.0/8", `"tag":"direct"`, `"a.com":"2.2.2.2"`, "8.8.8.8"} {
		if !strings.Contains(out, want) {
			t.Fatalf("config misses %s: %s", want, out)
		}
	}
}

func TestProfileAllModeRoutesToFirstProxy(t *testing.T) {
	res, err := Tunnel(model.Server{Profile: json.RawMessage(profile)}, Options{Settings: model.DefaultSettings()})
	if err != nil {
		t.Fatal(err)
	}
	var cfg map[string]any
	_ = json.Unmarshal(res.JSON, &cfg)
	rules := cfg["routing"].(map[string]any)["rules"].([]any)
	last := rules[len(rules)-1].(map[string]any)
	if last["outboundTag"] != "main" || cfg["dns"] != nil {
		t.Fatalf("routing %v dns %v", rules, cfg["dns"])
	}
}

func TestProbeHasNoInbounds(t *testing.T) {
	b, err := Probe(model.Server{Outbound: json.RawMessage(`{"protocol":"vless","settings":{}}`)}, Options{Settings: model.DefaultSettings()})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), `"inbounds":[]`) {
		t.Fatalf("%s", b)
	}
}

func TestTunnelOptions(t *testing.T) {
	s := model.DefaultSettings()
	s.Fragment = true
	s.Mux = true
	s.TCPFastOpen = true
	s.BlockQUIC = true
	s.UDPRelay = false
	s.ProxyShare = true
	s.ProxyLAN = true
	s.HideVPNIcon = true
	s.LoopbackRoute = true
	s.ConnectionLog = true
	srv := model.Server{Outbound: json.RawMessage(`{"protocol":"vmess","settings":{"vnext":[{"address":"a.com","port":443,"users":[{"id":"x"}]}]},"streamSettings":{"network":"ws"}}`)}
	res, err := Tunnel(srv, Options{Settings: s})
	if err != nil {
		t.Fatal(err)
	}
	out := string(res.JSON)
	for _, want := range []string{`"dialerProxy":"fragment"`, `"tag":"fragment"`, `"packets":"tlshello"`, `"mux":{`, `"tcpFastOpen":true`,
		`"port":"443"`, `"port":"1-52,54-65535"`, `"protocol":"mixed"`, `"listen":"0.0.0.0"`, `"access":"file"`} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %s in %s", want, out)
		}
	}
	if res.Net.Reflect[0] != "10.7.0.1" || res.Net.Included[0] != "10.7.0.1/32" || res.Net.Excluded[len(res.Net.Excluded)-1] != "0.0.0.0/31" {
		t.Errorf("net %+v", res.Net)
	}
	// vision flow disables mux; hysteria never gets fragmentation
	vision := model.Server{Outbound: json.RawMessage(`{"protocol":"vless","settings":{"vnext":[{"address":"a.com","port":443,"users":[{"id":"x","flow":"xtls-rprx-vision"}]}]}}`)}
	res, _ = Tunnel(vision, Options{Settings: s})
	if strings.Contains(string(res.JSON), `"mux"`) {
		t.Error("mux with vision")
	}
	hy := model.Server{Outbound: json.RawMessage(`{"protocol":"hysteria","settings":{"address":"a.com","port":443},"streamSettings":{"network":"hysteria"}}`)}
	res, _ = Tunnel(hy, Options{Settings: s})
	if strings.Contains(string(res.JSON), `"dialerProxy"`) {
		t.Error("fragment on hysteria")
	}
}

func TestConfigMode(t *testing.T) {
	c := rules.Parse("[General]\ndns-server = https://1.1.1.1/dns-query\ntun-excluded-routes = 192.168.0.0/16\n[Rule]\nDOMAIN-SUFFIX,ru,DIRECT\nIP-CIDR,1.0.0.0/8,REJECT\nFINAL,PROXY\n[Host]\na.lan = 192.168.1.2\n")
	comp := rules.Compile(c, rules.Options{})
	s := model.DefaultSettings()
	s.Mode = "config"
	res, err := Tunnel(model.Server{Profile: json.RawMessage(profile)}, Options{Settings: s, Rules: comp})
	if err != nil {
		t.Fatal(err)
	}
	var cfg map[string]any
	_ = json.Unmarshal(res.JSON, &cfg)
	rs := cfg["routing"].(map[string]any)["rules"].([]any)
	first := rs[0].(map[string]any)
	last := rs[len(rs)-1].(map[string]any)
	if first["outboundTag"] != "dns-out" || last["outboundTag"] != "main" {
		t.Fatalf("rules %v", rs)
	}
	if cfg["routing"].(map[string]any)["domainStrategy"] != "IPIfNonMatch" {
		t.Fatal("strategy")
	}
	dns := cfg["dns"].(map[string]any)
	if dns["hosts"].(map[string]any)["a.lan"] != "192.168.1.2" || len(dns["servers"].([]any)) != 1 {
		t.Fatalf("dns %v", dns)
	}
	if res.Net.DNS[0] != DNSAddress || res.Net.Excluded[1] != "192.168.0.0/16" {
		t.Fatalf("net %+v", res.Net)
	}
	s.Mode = "direct"
	res, _ = Tunnel(model.Server{Profile: json.RawMessage(profile)}, Options{Settings: s})
	if !strings.Contains(string(res.JSON), `{"network":"tcp,udp","outboundTag":"direct","type":"field"}`) {
		t.Fatalf("direct: %s", res.JSON)
	}
}

func TestProbeInterface(t *testing.T) {
	b, err := Probe(model.Server{Outbound: json.RawMessage(`{"protocol":"trojan","settings":{"servers":[{"address":"a.com","port":443,"password":"p"}]}}`)}, Options{Settings: model.DefaultSettings(), Interface: "en0"})
	if err != nil || !strings.Contains(string(b), `"interface":"en0"`) {
		t.Fatalf("%s %v", b, err)
	}
}
