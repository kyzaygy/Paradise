package xcfg

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/kyzaygy/paradise/core/internal/model"
)

func TestTunnelSingleOutbound(t *testing.T) {
	srv := model.Server{Outbound: json.RawMessage(`{"protocol":"trojan","tag":"x","settings":{"servers":[{"address":"a.com","port":443,"password":"p"}]}}`)}
	res, err := Tunnel(srv, model.DefaultSettings())
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
	if outs[0].(map[string]any)["tag"] != "proxy" || len(outs) != 3 {
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
	res, err := Tunnel(model.Server{Profile: json.RawMessage(profile)}, s)
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
	res, err := Tunnel(model.Server{Profile: json.RawMessage(profile)}, model.DefaultSettings())
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
	b, err := Probe(model.Server{Outbound: json.RawMessage(`{"protocol":"vless","settings":{}}`)}, model.DefaultSettings())
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), `"inbounds":[]`) {
		t.Fatalf("%s", b)
	}
}
