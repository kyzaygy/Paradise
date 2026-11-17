package sub

import (
	"context"
	"encoding/base64"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"github.com/kyzaygy/paradise/core/internal/apperr"
)

func dev() Device { return Device{UserAgent: "Paradise/0.1.0 (iOS 27.0)"} }

func TestResolveConnectPageWithAppButtons(t *testing.T) {
	list := base64.StdEncoding.EncodeToString([]byte(vlessReality + "\n" + trojanWS))
	var srv *httptest.Server
	srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/to/abc":
			sub := srv.URL + "/api/sub/TOKEN?x=1&y=2"
			w.Header().Set("Content-Type", "text/html")
			_, _ = w.Write([]byte(`<html><head><link href="/static/app.css" rel="stylesheet"></head><body>
<a href="happ://add/` + sub + `">Happ</a>
<a href="v2raytun://import/` + sub + `">v2RayTun</a>
<a href="sing-box://import-remote-profile?url=` + url.QueryEscape(sub) + `#x">sing-box</a></body></html>`))
		case "/api/sub/TOKEN":
			if r.URL.Query().Get("y") != "2" {
				http.Error(w, "bad query", 400)
				return
			}
			w.Header().Set("profile-title", "Provider")
			_, _ = w.Write([]byte(list))
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()
	res, err := Resolve(context.Background(), srv.Client(), srv.URL+"/to/abc", dev(), "s1")
	if err != nil {
		t.Fatalf("%v trace=%v", err, res.Trace)
	}
	if len(res.Parsed.Servers) != 2 || res.Header.Get("profile-title") != "Provider" {
		t.Fatalf("servers %d trace %v", len(res.Parsed.Servers), res.Trace)
	}
}

func TestResolveInlineLinksInHTML(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		page := `<!doctype html><div class="cfg"><code>` + strings.ReplaceAll(vlessReality, "&", "&amp;") + `</code>
<script>const cfg = "` + strings.ReplaceAll(trojanWS, "/", `\/`) + `";</script></div>`
		_, _ = w.Write([]byte(page))
	}))
	defer srv.Close()
	res, err := Resolve(context.Background(), srv.Client(), srv.URL+"/page", dev(), "s1")
	if err != nil || len(res.Parsed.Servers) != 2 || res.Parsed.Format != "extracted" {
		t.Fatalf("%v %+v", err, res)
	}
	if !strings.Contains(string(res.Parsed.Servers[0].Outbound), `"shortId":"ab12"`) {
		t.Fatalf("html entities not decoded: %s", res.Parsed.Servers[0].Outbound)
	}
}

func TestResolveUserAgentGating(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.UserAgent(), "v2rayNG") {
			_, _ = w.Write([]byte(base64.StdEncoding.EncodeToString([]byte(vlessReality))))
			return
		}
		_, _ = w.Write([]byte("<html><body>Open this link in a VPN app</body></html>"))
	}))
	defer srv.Close()
	res, err := Resolve(context.Background(), srv.Client(), srv.URL+"/sub", dev(), "s1")
	if err != nil || len(res.Parsed.Servers) != 1 || len(res.Trace) != 2 {
		t.Fatalf("%v trace %v", err, res.Trace)
	}
}

func TestResolveMetaRefreshAndFailure(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/go":
			_, _ = w.Write([]byte(`<html><head><meta http-equiv="refresh" content="0; url=/real/sub"></head></html>`))
		case "/real/sub":
			_, _ = w.Write([]byte(trojanWS))
		default:
			_, _ = w.Write([]byte(`<html>nothing here</html>`))
		}
	}))
	defer srv.Close()
	res, err := Resolve(context.Background(), srv.Client(), srv.URL+"/go", dev(), "s1")
	if err != nil || len(res.Parsed.Servers) != 1 {
		t.Fatalf("%v trace %v", err, res.Trace)
	}
	_, err = Resolve(context.Background(), srv.Client(), srv.URL+"/nothing", dev(), "s1")
	if apperr.From(err).Code != apperr.HTMLResponse {
		t.Fatalf("want html_response, got %v", err)
	}
}

func TestEmbeddedURL(t *testing.T) {
	for in, want := range map[string]string{
		"happ://add/https://s.example.com/sub/T":                              "https://s.example.com/sub/T",
		"streisand://import/https://s.example.com/x#name":                     "https://s.example.com/x#name",
		"clash://install-config?url=https%3A%2F%2Fs.example.com%2Fc":          "https://s.example.com/c",
		"sub://" + base64.StdEncoding.EncodeToString([]byte("https://a.b/s")): "https://a.b/s",
		"tg://resolve?domain=x":                                               "",
	} {
		if got := embeddedURL(in); got != want {
			t.Fatalf("%s: got %q want %q", in, got, want)
		}
	}
}

func TestHysteria2(t *testing.T) {
	srv, err := ParseURI("hysteria2://pass@h.example.com:443?sni=h.example.com&obfs=salamander&obfs-password=secret12#HY2")
	if err != nil || srv.Protocol != "hysteria2" || srv.Network != "hysteria" || srv.Name != "HY2" {
		t.Fatalf("%v %+v", err, srv)
	}
	srv, err = ParseURI("hy2://pass@h.example.com:20000-30000?sni=h.example.com#Hop")
	if err != nil || !strings.Contains(string(srv.Outbound), "udphop") {
		t.Fatalf("%v %s", err, srv.Outbound)
	}
	if _, err := ParseURI("hysteria2://pass@h.example.com:443?insecure=1"); err == nil {
		t.Fatal("insecure must be rejected")
	}
}
