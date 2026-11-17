package pdcore

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"

	"github.com/xtls/xray-core/core"

	"github.com/kyzaygy/paradise/core/internal/model"
	"github.com/kyzaygy/paradise/core/internal/sub"
	"github.com/kyzaygy/paradise/core/internal/xcfg"
)

var links = []string{
	"vless://11111111-2222-3333-4444-555555555555@example.com:443?type=tcp&security=reality&pbk=Z84J2IelR9ch3k8VtlVhhs5ycBUlXA7wHBWcBrjqnAw&sid=ab12&sni=www.microsoft.com&fp=chrome&flow=xtls-rprx-vision#R",
	"vless://11111111-2222-3333-4444-555555555555@x.example.com:443?type=xhttp&security=tls&sni=x.example.com&path=%2Fapi&mode=packet-up#X",
	"vless://11111111-2222-3333-4444-555555555555@g.example.com:443?type=grpc&security=tls&serviceName=svc#G",
	"vless://11111111-2222-3333-4444-555555555555@h.example.com:443?type=httpupgrade&security=tls&sni=h.example.com&path=%2Fup#H",
	"trojan://secret@t.example.com:8443?type=ws&path=%2Fws&host=cdn.example.com#T",
	"vmess://" + base64.StdEncoding.EncodeToString([]byte(`{"v":"2","ps":"V","add":"v.example.com","port":"443","id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","aid":"0","net":"ws","path":"/vm","tls":"tls"}`)),
	"ss://" + base64.RawURLEncoding.EncodeToString([]byte("aes-256-gcm:password")) + "@s.example.com:8388#S",
	"ss://2022-blake3-aes-128-gcm:" + "YWFhYWFhYWFhYWFhYWFhYQ==" + "@s2.example.com:443#S2",
}

func TestConfigsAreAcceptedByXray(t *testing.T) {
	for _, link := range links {
		srv, err := sub.ParseURI(link)
		if err != nil {
			t.Fatalf("%s: %v", link, err)
		}
		tun, err := xcfg.Tunnel(srv, model.DefaultSettings())
		if err != nil {
			t.Fatal(err)
		}
		if _, err := core.LoadConfig("json", bytes.NewReader(tun.JSON)); err != nil {
			t.Fatalf("%s: tunnel config rejected: %v\n%s", srv.Name, err, tun.JSON)
		}
		probe, err := xcfg.Probe(srv, model.DefaultSettings())
		if err != nil {
			t.Fatal(err)
		}
		inst, err := core.StartInstance("json", probe)
		if err != nil {
			t.Fatalf("%s: probe instance failed: %v\n%s", srv.Name, err, probe)
		}
		_ = inst.Close()
	}
}

func TestFullProfileIsAcceptedByXray(t *testing.T) {
	profile := `{"remarks":"P","outbounds":[{"tag":"main","protocol":"vless","settings":{"vnext":[{"address":"a.example.com","port":443,"users":[{"id":"11111111-2222-3333-4444-555555555555","encryption":"none"}]}]},"streamSettings":{"network":"tcp","security":"tls","tlsSettings":{"serverName":"a.example.com"}}},{"tag":"block","protocol":"blackhole"}],
	"routing":{"rules":[{"type":"field","domain":["geosite:category-ads-all","example.org"],"outboundTag":"block"},{"type":"field","ip":["geoip:private"],"outboundTag":"direct"}]}}`
	var m map[string]any
	_ = json.Unmarshal([]byte(profile), &m)
	srv, err := sub.ServerFromProfile(m, m["outbounds"].([]any))
	if err != nil {
		t.Fatal(err)
	}
	for _, mode := range []string{"all", "profile"} {
		s := model.DefaultSettings()
		s.Mode = mode
		tun, err := xcfg.Tunnel(srv, s)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := core.LoadConfig("json", bytes.NewReader(tun.JSON)); err != nil {
			t.Fatalf("%s: %v\n%s", mode, err, tun.JSON)
		}
	}
}

func TestOpenAndCall(t *testing.T) {
	key := base64.StdEncoding.EncodeToString(make([]byte, 32))
	if r := Open(t.TempDir(), key, `{"platform":"iOS","appVersion":"0.1.0"}`); !strings.Contains(r, `"ok":true`) {
		t.Fatal(r)
	}
	if r := Call("state", "{}"); !strings.Contains(r, `"ok":true`) {
		t.Fatal(r)
	}
	if r := Call("nope", "{}"); !strings.Contains(r, `"invalid_input"`) {
		t.Fatal(r)
	}
	if Version() == "" {
		t.Fatal("no version")
	}
}

func TestTunnelLogsAndValidator(t *testing.T) {
	if err := validateConfig([]byte(`{"outbounds":[{"protocol":"freedom"}]}`)); err != nil {
		t.Fatal(err)
	}
	if err := validateConfig([]byte(`{"outbounds":[{"protocol":"nope"}]}`)); err == nil {
		t.Fatal("invalid config accepted")
	}
	Log("info", "test", "hello https://secret.example.com/path/TOKEN")
	out := TunnelLogs("")
	if !strings.Contains(out, "hello") || strings.Contains(out, "TOKEN") {
		t.Fatal(out)
	}
	_ = Open(t.TempDir(), base64.StdEncoding.EncodeToString(make([]byte, 32)), `{}`)
	var env struct {
		OK   bool `json:"ok"`
		Data []struct {
			Name   string `json:"name"`
			OK     bool   `json:"ok"`
			Detail string `json:"detail"`
		} `json:"data"`
	}
	r := Call("selfTest", "{}")
	if err := json.Unmarshal([]byte(r), &env); err != nil || !env.OK || len(env.Data) < 8 {
		t.Fatal(r)
	}
	for _, c := range env.Data {
		if !c.OK {
			t.Fatalf("self-test %s failed: %s", c.Name, c.Detail)
		}
	}
}
