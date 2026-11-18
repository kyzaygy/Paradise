package engine

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/kyzaygy/paradise/core/internal/rules"
)

func TestDefaultConfigAndModes(t *testing.T) {
	v := newEnv(t)
	s := v.state()
	if len(s.Configs) != 1 || !s.Configs[0].Builtin || !s.Configs[0].Active {
		t.Fatalf("configs %+v", s.Configs)
	}
	v.call("importText", map[string]any{"text": linkA})
	var sr SaveResult
	text := "[Rule]\nDOMAIN-SUFFIX,example.org,DIRECT\nGEOIP,RU,DIRECT\nFINAL,PROXY\n"
	_ = json.Unmarshal(v.call("saveConfig", map[string]any{"name": "Mine", "text": text}), &sr)
	if sr.ID == "" || len(sr.Report.MissingGeo) != 1 || len(sr.State.Configs) != 2 {
		t.Fatalf("save %+v", sr)
	}
	v.call("activateConfig", map[string]any{"id": sr.ID})
	var tc TunnelConfig
	_ = json.Unmarshal(v.call("tunnelConfig", map[string]any{}), &tc)
	if tc.Mode != "config" || tc.ConfigName != "Mine" || !strings.Contains(tc.Config, "domain:example.org") || len(tc.MissingGeo) != 1 {
		t.Fatalf("tunnel %+v", tc)
	}
	var n map[string]any
	if json.Unmarshal([]byte(tc.Net), &n) != nil || n["mtu"].(float64) != 1500 {
		t.Fatalf("net %s", tc.Net)
	}
	// geo database: install a tiny file and recompile
	dat := rules.EncodeGeoIPForTest(map[string][]string{"ru": {"5.8.0.0/16"}})
	_ = os.MkdirAll(v.dir+"/geo", 0o700)
	_ = os.WriteFile(v.e.geoPath("geoip"), dat, 0o600)
	tc = TunnelConfig{}
	_ = json.Unmarshal(v.call("tunnelConfig", map[string]any{}), &tc)
	if !strings.Contains(tc.Config, "5.8.0.0/16") || len(tc.MissingGeo) != 0 {
		t.Fatalf("geo not applied %+v", tc.MissingGeo)
	}
	if r := v.callRaw("deleteConfig", map[string]any{"id": "default"}); r.OK {
		t.Fatal("builtin deleted")
	}
	v.call("deleteConfig", map[string]any{"id": sr.ID})
	s = v.state()
	if len(s.Configs) != 1 || !s.Configs[0].Active {
		t.Fatalf("after delete %+v", s.Configs)
	}
}

func TestRoutingImportAndProvidedRouting(t *testing.T) {
	v := newEnv(t)
	profile, _ := json.Marshal(map[string]any{"Name": "Provider", "GlobalProxy": "true", "DirectSites": []any{"domain:ya.ru"}})
	link := "happ://routing/onadd/" + base64.StdEncoding.EncodeToString(profile)
	if Classify(link) != "routing" {
		t.Fatal("classify")
	}
	var res ImportResult
	_ = json.Unmarshal(v.call("importText", map[string]any{"text": link}), &res)
	if res.Kind != "routing" || res.State.Settings.Mode != "config" {
		t.Fatalf("%+v", res)
	}
	// subscription delivering routing in the body
	v.body.Store(linkA + "\n" + strings.Replace(link, "onadd", "add", 1))
	var sub ImportResult
	_ = json.Unmarshal(v.call("addSubscription", map[string]any{"url": v.server.URL + "/r"}), &sub)
	s := v.state()
	provided := 0
	for _, c := range s.Configs {
		if c.Provided {
			provided++
		}
	}
	if provided != 1 {
		t.Fatalf("configs %+v", s.Configs)
	}
	v.call("deleteSubscription", map[string]any{"id": sub.SubscriptionID})
	for _, c := range v.state().Configs {
		if c.Provided {
			t.Fatal("provided config survived subscription deletion")
		}
	}
	if Classify("happ://crypt3/abc") != "encrypted" {
		t.Fatal("crypt")
	}
	if Classify("happ://add/https://example.com/sub") != "url" {
		t.Fatal("deep link")
	}
}

func TestConfigURLAndRuleSets(t *testing.T) {
	v := newEnv(t)
	var srv *httptest.Server
	srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/a.conf":
			_, _ = w.Write([]byte("[General]\nipv6 = false\n[Rule]\nDOMAIN-SET," + srv.URL + "/d.txt,REJECT\nFINAL,DIRECT\n"))
		case "/d.txt":
			_, _ = w.Write([]byte(".ads.example\ntracker.example\n"))
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()
	var sr SaveResult
	_ = json.Unmarshal(v.call("addConfigURL", map[string]any{"url": srv.URL + "/a.conf"}), &sr)
	if sr.Report.Stats.Domains != 2 || len(sr.Report.MissingSets) != 0 {
		t.Fatalf("report %+v", sr.Report)
	}
	var detail ConfigDetail
	_ = json.Unmarshal(v.call("getConfig", map[string]any{"id": sr.ID}), &detail)
	if detail.Config.Name != "a" || !detail.Config.Remote || detail.Report.Final != "direct" {
		t.Fatalf("detail %+v", detail.Config)
	}
	_ = json.Unmarshal(v.call("updateConfig", map[string]any{"id": sr.ID}), &sr)
	if sr.Report.Stats.Domains != 2 {
		t.Fatalf("update %+v", sr.Report)
	}
}

func TestImportOptionsAndExport(t *testing.T) {
	v := newEnv(t)
	v.call("importText", map[string]any{"text": linkA + "\n" + linkB})
	var res ImportResult
	_ = json.Unmarshal(v.call("importText", map[string]any{"text": linkA}), &res)
	if res.Added != 0 || res.Duplicates != 1 {
		t.Fatalf("duplicate %+v", res)
	}
	renamed := strings.Replace(linkB, "path=%2Fw", "path=%2Fother", 1)
	_ = json.Unmarshal(v.call("importText", map[string]any{"text": renamed}), &res)
	if res.Added != 1 || res.State.Servers[len(res.State.Servers)-1].Name != "B 2" {
		t.Fatalf("auto rename %+v", res.State.Servers)
	}
	v.call("updateSettings", map[string]any{"overwriteExisting": true})
	_ = json.Unmarshal(v.call("importText", map[string]any{"text": strings.Replace(linkB, "path=%2Fw", "path=%2Fnew", 1)}), &res)
	if res.Replaced != 2 || len(res.State.Servers) != 2 {
		t.Fatalf("overwrite %+v", res)
	}
	var ex ExportServersResult
	_ = json.Unmarshal(v.call("exportServers", map[string]any{"format": "links"}), &ex)
	if ex.Count != 2 || !strings.Contains(ex.Text, "vless://") {
		t.Fatalf("export %+v", ex)
	}
	_ = json.Unmarshal(v.call("exportServers", map[string]any{"format": "json"}), &ex)
	if ex.Count != 2 || !strings.HasPrefix(strings.TrimSpace(ex.Text), "[") {
		t.Fatalf("export json %+v", ex)
	}
	v.call("deleteAllServers", map[string]any{})
	if s := v.state(); len(s.Servers) != 0 {
		t.Fatal("not deleted")
	}
}

func TestSettingsPatchNewFields(t *testing.T) {
	v := newEnv(t)
	var s State
	_ = json.Unmarshal(v.call("updateSettings", map[string]any{"mtu": 1400, "dns": []string{"9.9.9.9", "bad"}, "fragmentLength": "x", "loopbackRoute": true, "unknown": 1}), &s)
	if s.Settings.MTU != 1400 || len(s.Settings.DNS) != 1 || s.Settings.FragmentLength != "100-200" || !s.Settings.LoopbackRoute {
		t.Fatalf("%+v", s.Settings)
	}
	_ = json.Unmarshal(v.call("resetSettings", map[string]any{}), &s)
	if s.Settings.MTU != 1500 || s.Settings.LoopbackRoute {
		t.Fatalf("reset %+v", s.Settings)
	}
}

func TestCountriesInState(t *testing.T) {
	v := newEnv(t)
	v.call("importText", map[string]any{"text": "vless://11111111-2222-3333-4444-555555555555@nl1.example.com:443?security=tls#%F0%9F%87%B3%F0%9F%87%B1%20Amsterdam\n" + linkB})
	s := v.state()
	if len(s.Countries) != 2 || s.Servers[0].Country != "NL" || s.Servers[0].City != "Amsterdam" || s.Servers[0].Region != "europe" {
		t.Fatalf("%+v %+v", s.Countries, s.Servers)
	}
}

func TestLocateServers(t *testing.T) {
	v := newEnv(t)
	geo := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"country":"NL","city":"Amsterdam"}`))
	}))
	defer geo.Close()
	saved := geoEndpoints
	geoEndpoints = geoEndpoints[:1]
	geoEndpoints[0] = func(ip string) (string, func([]byte) (string, string)) {
		return geo.URL + "/" + ip, func(b []byte) (string, string) {
			var x struct{ Country, City string }
			_ = json.Unmarshal(b, &x)
			return x.Country, x.City
		}
	}
	defer func() { geoEndpoints = saved }()
	v.call("importText", map[string]any{"text": "trojan://pw@203.0.113.10:443?security=tls#%D0%9D%D0%B8%D0%B4%D0%B5%D1%80%D0%BB%D0%B0%D0%BD%D0%B4%D1%8B%2010G"})
	var s State
	_ = json.Unmarshal(v.call("locateServers", map[string]any{}), &s)
	srv := s.Servers[0]
	if srv.Country != "NL" || srv.City != "Amsterdam" || srv.Bandwidth != "10 Gbps" || srv.Label != "" {
		t.Fatalf("%+v", srv)
	}
}
