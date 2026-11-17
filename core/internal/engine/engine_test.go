package engine

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

const (
	linkA = "vless://11111111-2222-3333-4444-555555555555@a.example.com:443?type=tcp&security=reality&pbk=K&sid=1&sni=www.example.com#A"
	linkB = "trojan://pw@b.example.com:443?type=ws&path=%2Fw#B"
)

type fakeProber struct{ calls int32 }

func (f *fakeProber) Probe(ctx context.Context, config []byte, url string) (int64, error) {
	atomic.AddInt32(&f.calls, 1)
	if !strings.Contains(string(config), `"inbounds":[]`) {
		return 0, context.DeadlineExceeded
	}
	return 42, nil
}

type env struct {
	t       *testing.T
	e       *Engine
	dir     string
	key     []byte
	server  *httptest.Server
	headers http.Header
	body    atomic.Value
}

func newEnv(t *testing.T) *env {
	t.Helper()
	v := &env{t: t, dir: t.TempDir(), key: make([]byte, 32)}
	_, _ = rand.Read(v.key)
	v.body.Store(linkA + "\n" + linkB)
	v.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		v.headers = r.Header.Clone()
		w.Header().Set("subscription-userinfo", "upload=1; download=2; total=100; expire=1893456000")
		w.Header().Set("profile-title", "Test VPN")
		_, _ = w.Write([]byte(v.body.Load().(string)))
	}))
	t.Cleanup(v.server.Close)
	v.open()
	return v
}

func (v *env) open() {
	e, err := New(v.dir, v.key, Device{Platform: "iOS", OSVersion: "18.1", Model: "iPhone15,2", Locale: "ru_RU", AppVersion: "0.1.0"}, &fakeProber{})
	if err != nil {
		v.t.Fatal(err)
	}
	v.e = e
}

type reply struct {
	OK    bool            `json:"ok"`
	Data  json.RawMessage `json:"data"`
	Error *struct {
		Code   string `json:"code"`
		Detail string `json:"detail"`
	} `json:"error"`
}

func (v *env) call(method string, args any) json.RawMessage {
	v.t.Helper()
	r := v.callRaw(method, args)
	if !r.OK {
		v.t.Fatalf("%s failed: %+v", method, r.Error)
	}
	return r.Data
}

func (v *env) callRaw(method string, args any) reply {
	v.t.Helper()
	b, _ := json.Marshal(args)
	var r reply
	if err := json.Unmarshal([]byte(v.e.Call(method, string(b))), &r); err != nil {
		v.t.Fatal(err)
	}
	return r
}

func (v *env) state() State {
	var s State
	_ = json.Unmarshal(v.call("state", map[string]any{}), &s)
	return s
}

func TestAddSubscriptionAndPersistence(t *testing.T) {
	v := newEnv(t)
	var res ImportResult
	_ = json.Unmarshal(v.call("addSubscription", map[string]any{"url": v.server.URL + "/sub/TOKEN"}), &res)
	if res.Added != 2 || len(res.State.Servers) != 2 {
		t.Fatalf("added %d", res.Added)
	}
	if v.headers.Get("x-hwid") == "" || !strings.HasPrefix(v.headers.Get("User-Agent"), "Paradise/0.1.0") || v.headers.Get("x-device-os") != "iOS" {
		t.Fatalf("headers %v", v.headers)
	}
	sub := res.State.Subscriptions[0]
	if sub.Meta == nil || sub.Meta.Title != "Test VPN" || sub.Meta.Total != 100 || !sub.Remote || sub.Host != "127.0.0.1" {
		t.Fatalf("subscription %+v", sub)
	}
	data := v.e.Call("state", "")
	if strings.Contains(data, "TOKEN") || strings.Contains(data, "11111111-2222") {
		t.Fatal("state leaks secrets")
	}
	if r := v.callRaw("addSubscription", map[string]any{"url": v.server.URL + "/sub/TOKEN"}); r.OK || r.Error.Code != "invalid_input" {
		t.Fatalf("duplicate must fail: %+v", r)
	}
	// reopen from disk
	v.open()
	if s := v.state(); len(s.Servers) != 2 || s.Selected == "" {
		t.Fatalf("reloaded state %+v", s)
	}
	// wrong key
	bad := make([]byte, 32)
	if _, err := New(v.dir, bad, Device{}, nil); err == nil {
		t.Fatal("wrong key must fail")
	}
}

func TestRefreshKeepsFavoritesAndSelection(t *testing.T) {
	v := newEnv(t)
	var res ImportResult
	_ = json.Unmarshal(v.call("addSubscription", map[string]any{"url": v.server.URL + "/s"}), &res)
	b := res.State.Servers[1]
	v.call("setFavorite", map[string]any{"key": b.Key, "favorite": true})
	v.call("select", map[string]any{"id": b.ID})
	v.body.Store(linkB + "\n" + linkA + "\nvless://broken")
	v.call("refresh", map[string]any{"id": res.SubscriptionID})
	s := v.state()
	if s.Selected != b.ID || !s.Servers[0].Favorite || s.Subscriptions[0].Warnings != 1 {
		t.Fatalf("after refresh %+v", s)
	}
	v.body.Store("<html>")
	r := v.callRaw("refreshAll", map[string]any{})
	var rr RefreshResult
	_ = json.Unmarshal(r.Data, &rr)
	if rr.Errors[res.SubscriptionID] != "html_response" || len(rr.State.Servers) != 2 || rr.State.Subscriptions[0].LastError != "html_response" {
		t.Fatalf("refreshAll %+v", rr)
	}
}

func TestImportTextAndTunnelConfig(t *testing.T) {
	v := newEnv(t)
	var res ImportResult
	_ = json.Unmarshal(v.call("importText", map[string]any{"text": linkA + "\n" + linkB}), &res)
	if res.Added != 2 || res.State.Subscriptions[0].Remote {
		t.Fatalf("%+v", res)
	}
	var tc TunnelConfig
	_ = json.Unmarshal(v.call("tunnelConfig", map[string]any{"id": res.State.Servers[1].ID}), &tc)
	if !strings.Contains(tc.Config, `"protocol":"tun"`) || tc.ServerName != "B" {
		t.Fatalf("tunnel %+v", tc)
	}
	var pr ProbeResult
	_ = json.Unmarshal(v.call("probe", map[string]any{"id": res.State.Servers[0].ID}), &pr)
	if pr.MS != 42 {
		t.Fatalf("probe %+v", pr)
	}
	if r := v.callRaw("importText", map[string]any{"text": "PD1.abc"}); r.OK {
		t.Fatal("transfer codes must not import as text")
	}
	if k := Classify("paradise://import#PD1.x"); k != "transfer" {
		t.Fatal(k)
	}
	if k := Classify(" https://a.b/c "); k != "url" {
		t.Fatal(k)
	}
}

func TestSettingsPatch(t *testing.T) {
	v := newEnv(t)
	var s State
	_ = json.Unmarshal(v.call("updateSettings", map[string]any{"killSwitch": true, "mode": "bogus"}), &s)
	if !s.Settings.KillSwitch || s.Settings.Mode != "all" || !s.Settings.AutoRefresh {
		t.Fatalf("%+v", s.Settings)
	}
}

func TestTransferBetweenDevices(t *testing.T) {
	src := newEnv(t)
	var res ImportResult
	_ = json.Unmarshal(src.call("addSubscription", map[string]any{"url": src.server.URL + "/s"}), &res)
	src.call("importText", map[string]any{"text": linkB})
	st := src.state()
	src.call("setFavorite", map[string]any{"key": st.Servers[0].Key, "favorite": true})
	src.call("updateSettings", map[string]any{"killSwitch": true})

	var ex ExportResult
	_ = json.Unmarshal(src.call("exportTransfer", map[string]any{"includeFavorites": true, "includeSettings": true, "password": "p@ss", "expiresInHours": 24}), &ex)
	if !ex.Encrypted || ex.ExpiresAt == 0 || !strings.HasPrefix(ex.Link, "paradise://import#PD1.") || ex.Counts.Subscriptions != 2 || ex.Counts.Servers != 1 {
		t.Fatalf("export %+v", ex)
	}

	dst := newEnv(t)
	var pv Preview
	_ = json.Unmarshal(dst.call("previewTransfer", map[string]any{"code": ex.Link}), &pv)
	if !pv.Locked || pv.Counts.Subscriptions != 0 {
		t.Fatalf("locked preview %+v", pv)
	}
	if r := dst.callRaw("previewTransfer", map[string]any{"code": ex.Code, "password": "nope"}); r.OK || r.Error.Code != "transfer_password_wrong" {
		t.Fatalf("%+v", r)
	}
	_ = json.Unmarshal(dst.call("previewTransfer", map[string]any{"code": ex.Code, "password": "p@ss"}), &pv)
	if pv.Locked || pv.Counts.Subscriptions != 2 || !pv.HasSettings || pv.HasIdentity || pv.Sources[0].Host != "127.0.0.1" {
		t.Fatalf("preview %+v", pv)
	}
	raw := dst.e.Call("previewTransfer", `{"code":"`+ex.Code+`","password":"p@ss"}`)
	if strings.Contains(raw, "/s\"") || strings.Contains(raw, "pw@") {
		t.Fatal("preview leaks secrets")
	}
	var ir ImportTransferResult
	_ = json.Unmarshal(dst.call("importTransfer", map[string]any{"code": ex.Code, "password": "p@ss", "applySettings": true}), &ir)
	if ir.Added != 2 || len(ir.PendingRefresh) != 1 || !ir.State.Settings.KillSwitch {
		t.Fatalf("import %+v", ir)
	}
	dst.call("refresh", map[string]any{"id": ir.PendingRefresh[0]})
	s := dst.state()
	fav := 0
	for _, srv := range s.Servers {
		if srv.Favorite {
			fav++
		}
	}
	if len(s.Servers) != 3 || fav != 1 || s.HWID == src.state().HWID {
		t.Fatalf("dst state %+v", s)
	}
	// second import merges as duplicates
	_ = json.Unmarshal(dst.call("importTransfer", map[string]any{"code": ex.Code, "password": "p@ss"}), &ir)
	if ir.Added != 0 || ir.Duplicates != 2 {
		t.Fatalf("merge %+v", ir)
	}
	// replace
	_ = json.Unmarshal(dst.call("importTransfer", map[string]any{"code": ex.Code, "password": "p@ss", "strategy": "replace"}), &ir)
	if ir.Added != 2 || len(ir.State.Subscriptions) != 2 {
		t.Fatalf("replace %+v", ir)
	}
}

func TestTransferIdentityAndSVOI(t *testing.T) {
	src := newEnv(t)
	src.call("importText", map[string]any{"text": linkA})
	var ex ExportResult
	_ = json.Unmarshal(src.call("exportTransfer", map[string]any{"includeIdentity": true}), &ex)
	dst := newEnv(t)
	dst.call("importTransfer", map[string]any{"code": ex.Code, "applyIdentity": true})
	if dst.state().HWID != src.state().HWID {
		t.Fatal("identity not applied")
	}
	_ = json.Unmarshal(src.call("exportTransfer", map[string]any{"format": "svoi1"}), &ex)
	if !strings.HasPrefix(ex.Code, "SVOI1.") || !ex.FitsQR {
		t.Fatalf("svoi %+v", ex)
	}
	third := newEnv(t)
	var ir ImportTransferResult
	_ = json.Unmarshal(third.call("importTransfer", map[string]any{"code": ex.Code}), &ir)
	if ir.Added != 1 || len(ir.State.Servers) != 1 || ir.State.Servers[0].Name != "A" {
		t.Fatalf("svoi import %+v", ir)
	}
}

func TestExpiredTransfer(t *testing.T) {
	src := newEnv(t)
	src.call("importText", map[string]any{"text": linkA})
	var ex ExportResult
	_ = json.Unmarshal(src.call("exportTransfer", map[string]any{"expiresInHours": 1}), &ex)
	dst := newEnv(t)
	dst.e.SetClock(func() time.Time { return time.Now().Add(2 * time.Hour) })
	if r := dst.callRaw("previewTransfer", map[string]any{"code": ex.Code}); r.OK || r.Error.Code != "transfer_expired" {
		t.Fatalf("%+v", r)
	}
}
