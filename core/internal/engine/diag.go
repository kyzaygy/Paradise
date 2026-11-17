package engine

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"os"
	"runtime"
	"strings"
	"time"

	"github.com/kyzaygy/paradise/core/internal/apperr"
	"github.com/kyzaygy/paradise/core/internal/logx"
	"github.com/kyzaygy/paradise/core/internal/model"
	"github.com/kyzaygy/paradise/core/internal/store"
	"github.com/kyzaygy/paradise/core/internal/sub"
	"github.com/kyzaygy/paradise/core/internal/transfer"
	"github.com/kyzaygy/paradise/core/internal/xcfg"
)

// Check is one self-test result.
type Check struct {
	Name   string `json:"name"`
	OK     bool   `json:"ok"`
	Warn   bool   `json:"warn,omitempty"`
	MS     int64  `json:"ms"`
	Detail string `json:"detail,omitempty"`
}

// Built-in fixtures: fake servers, never contacted.
var fixtures = []string{
	"vless://11111111-2222-3333-4444-555555555555@example.com:443?type=tcp&security=reality&pbk=Z84J2IelR9ch3k8VtlVhhs5ycBUlXA7wHBWcBrjqnAw&sid=ab12&sni=www.example.com&fp=chrome&flow=xtls-rprx-vision#Reality",
	"vless://11111111-2222-3333-4444-555555555555@x.example.com:443?type=xhttp&security=tls&sni=x.example.com&path=%2Fx&mode=auto#XHTTP",
	"vless://11111111-2222-3333-4444-555555555555@g.example.com:443?type=grpc&security=tls&serviceName=s#gRPC",
	"trojan://pw@t.example.com:443?type=ws&path=%2Fws#Trojan",
	"vmess://eyJ2IjoiMiIsInBzIjoiVk1lc3MiLCJhZGQiOiJ2LmV4YW1wbGUuY29tIiwicG9ydCI6IjQ0MyIsImlkIjoiYWFhYWFhYWEtYmJiYi1jY2NjLWRkZGQtZWVlZWVlZWVlZWVlIiwiYWlkIjoiMCIsIm5ldCI6IndzIiwicGF0aCI6Ii92bSIsInRscyI6InRscyJ9",
	"ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ@s.example.com:8388#SS",
}

func timed(name string, f func() (string, error)) Check {
	start := time.Now()
	detail, err := f()
	c := Check{Name: name, OK: err == nil, MS: time.Since(start).Milliseconds(), Detail: detail}
	if err != nil {
		ae := apperr.From(err)
		c.Detail = strings.TrimSpace(ae.Code + " " + ae.Detail + " " + detail)
	}
	c.Detail = logx.Redact(c.Detail)
	level := "info"
	if !c.OK {
		level = "error"
	}
	logx.Add(level, "selftest", "%s: ok=%v %dms %s", name, c.OK, c.MS, c.Detail)
	return c
}

func (e *Engine) selfTest() []Check {
	logx.Info("selftest", "started")
	checks := []Check{}

	checks = append(checks, timed("storage", func() (string, error) {
		dir, err := os.MkdirTemp("", "pd-selftest")
		if err != nil {
			return "", apperr.New(apperr.Storage, "tempdir")
		}
		defer os.RemoveAll(dir)
		key := make([]byte, 32)
		_, _ = rand.Read(key)
		st, err := store.Open(dir, key)
		if err != nil {
			return "", err
		}
		doc := &model.Document{Version: 1, HWID: "x", Settings: model.DefaultSettings()}
		if err := st.Save(doc); err != nil {
			return "", err
		}
		back, err := st.Load()
		if err != nil || back.HWID != "x" {
			return "", apperr.New(apperr.Storage, "roundtrip")
		}
		return "encrypted write/read ok", nil
	}))

	var parsed []model.Server
	checks = append(checks, timed("parser", func() (string, error) {
		for _, link := range fixtures {
			srv, err := sub.ParseURI(link)
			if err != nil {
				return "", fmt.Errorf("%s: %v", strings.SplitN(link, "://", 2)[0], err)
			}
			parsed = append(parsed, srv)
		}
		return fmt.Sprintf("%d links: vless reality/xhttp/grpc, trojan, vmess, ss", len(parsed)), nil
	}))

	checks = append(checks, timed("xray_config", func() (string, error) {
		if e.validate == nil {
			return "validator unavailable", nil
		}
		for _, srv := range parsed {
			res, err := xcfg.Tunnel(srv, model.DefaultSettings())
			if err != nil {
				return srv.Name, err
			}
			if err := e.validate(res.JSON); err != nil {
				return srv.Name, apperr.New(apperr.Config, firstLine(err.Error()))
			}
		}
		return fmt.Sprintf("%d configs accepted by Xray", len(parsed)), nil
	}))

	payload := transfer.Payload{Name: "selftest", Subscriptions: []transfer.Source{{Name: "s", URL: "https://example.com/sub"}}}
	checks = append(checks, timed("transfer_pd1", func() (string, error) {
		c, err := transfer.EncodePD1(payload, transfer.EncodeOptions{})
		if err != nil {
			return "", err
		}
		if _, err := transfer.Decode(c, "", time.Now()); err != nil {
			return "", err
		}
		return fmt.Sprintf("%d chars", len(c)), nil
	}))
	checks = append(checks, timed("transfer_password", func() (string, error) {
		c, err := transfer.EncodePD1(payload, transfer.EncodeOptions{Password: "selftest", ExpiresAt: time.Now().Add(time.Hour).Unix()})
		if err != nil {
			return "", err
		}
		if _, err := transfer.Decode(c, "selftest", time.Now()); err != nil {
			return "", err
		}
		if _, err := transfer.Decode(c, "wrong", time.Now()); apperr.From(err).Code != apperr.TransferWrongPass {
			return "", apperr.New(apperr.Internal, "wrong password accepted")
		}
		return "argon2id + aes-gcm encode/decode", nil
	}))
	checks = append(checks, timed("transfer_svoi1", func() (string, error) {
		c, _, err := transfer.EncodeSVOI1(payload, transfer.SVOIDevice{Model: e.device.Model, Locale: e.device.Locale, UserAgent: e.userAgent()})
		if err != nil {
			return "", err
		}
		if _, _, err := transfer.DecodeSVOI1(c); err != nil {
			return "", err
		}
		return "encode/decode", nil
	}))

	e.mu.Lock()
	servers := []model.Server{}
	subs := []model.Subscription{}
	for _, s := range e.doc.Subscriptions {
		subs = append(subs, model.Subscription{Name: s.Name, URL: s.URL, LastError: s.LastError, Servers: nil, UpdatedAt: s.UpdatedAt})
		servers = append(servers, s.Servers...)
	}
	settings := e.doc.Settings
	e.mu.Unlock()

	checks = append(checks, timed("profile_subscriptions", func() (string, error) {
		failed := []string{}
		for _, s := range subs {
			if s.LastError != "" {
				failed = append(failed, fmt.Sprintf("%s: %s", nameOr(s.Name, sub.HostOf(s.URL)), s.LastError))
			}
		}
		detail := fmt.Sprintf("%d subscriptions, %d servers", len(subs), len(servers))
		if len(failed) > 0 {
			return detail + "; failing: " + strings.Join(failed, "; "), apperr.New(apperr.Network, "last refresh failed")
		}
		return detail, nil
	}))

	checks = append(checks, timed("profile_servers", func() (string, error) {
		if len(servers) == 0 {
			return "no servers", nil
		}
		if e.validate == nil {
			return "validator unavailable", nil
		}
		bad := []string{}
		for _, srv := range servers {
			res, err := xcfg.Tunnel(srv, settings)
			if err == nil {
				err = e.validate(res.JSON)
			}
			if err != nil {
				bad = append(bad, fmt.Sprintf("%s (%s): %s", srv.Name, srv.Protocol, firstLine(err.Error())))
			}
		}
		if len(bad) > 0 {
			show := bad
			if len(show) > 5 {
				show = show[:5]
			}
			return fmt.Sprintf("%d/%d rejected: %s", len(bad), len(servers), strings.Join(show, "; ")), apperr.New(apperr.Config, "")
		}
		return fmt.Sprintf("all %d servers produce valid configs", len(servers)), nil
	}))

	var m runtime.MemStats
	runtime.ReadMemStats(&m)
	mem := Check{Name: "memory", OK: true, Detail: fmt.Sprintf("heap %d MB, sys %d MB, goroutines %d", m.HeapAlloc>>20, m.Sys>>20, runtime.NumGoroutine())}
	logx.Info("selftest", "memory: %s", mem.Detail)
	checks = append(checks, mem)
	logx.Info("selftest", "finished")
	return checks
}

func nameOr(a, b string) string {
	if a != "" {
		return a
	}
	return b
}

func firstLine(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = s[:i]
	}
	// Xray errors are long chains "a > b > c"; the tail is the useful part.
	if parts := strings.Split(s, " > "); len(parts) > 2 {
		s = strings.Join(parts[len(parts)-2:], " > ")
	}
	if len(s) > 220 {
		s = s[:220] + "…"
	}
	return s
}

// FetchTest reports how a subscription download behaves, without returning its content.
type FetchTest struct {
	Host     string          `json:"host"`
	Report   sub.FetchReport `json:"report"`
	OK       bool            `json:"ok"`
	Error    *apperr.Error   `json:"error,omitempty"`
	Format   string          `json:"format,omitempty"`
	Servers  int             `json:"servers"`
	Warnings []string        `json:"warnings,omitempty"`
	Meta     []string        `json:"meta,omitempty"`
	UA       string          `json:"userAgent"`
}

func (e *Engine) testFetch(id, raw string) (any, error) {
	e.mu.Lock()
	if id != "" {
		s := e.doc.FindSubscription(id)
		if s == nil {
			e.mu.Unlock()
			return nil, apperr.New(apperr.NotFound, "subscription")
		}
		raw = s.URL
	}
	hwid, send := e.doc.HWID, e.doc.Settings.SendHWID
	e.mu.Unlock()
	if raw == "" {
		return nil, apperr.New(apperr.InvalidInput, "local subscription")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	dev := e.deviceHeaders(send, hwid)
	out := FetchTest{Host: sub.HostOf(raw), UA: dev.UserAgent}
	body, header, rep, err := sub.FetchDetailed(ctx, e.client, raw, dev)
	out.Report = rep
	if err != nil {
		ae := apperr.From(err)
		out.Error = ae
		logx.Warn("diag", "testFetch %s: %s %s status=%d kind=%s", out.Host, ae.Code, ae.Detail, rep.Status, rep.BodyKind)
		return out, nil
	}
	parsed, err := sub.Parse(body, "diag")
	out.Format = parsed.Format
	out.Servers = len(parsed.Servers)
	for i, w := range parsed.Warnings {
		if i >= 8 {
			break
		}
		out.Warnings = append(out.Warnings, logx.Redact(w))
	}
	for k := range sub.MergeHeaders(parsed.Headers, header) {
		lk := strings.ToLower(k)
		for _, known := range []string{"subscription-userinfo", "profile-title", "profile-update-interval", "support-url", "announce", "profile-web-page-url", "routing"} {
			if lk == known {
				out.Meta = append(out.Meta, lk)
			}
		}
	}
	if err != nil {
		ae := apperr.From(err)
		out.Error = &apperr.Error{Code: ae.Code, Detail: logx.Redact(ae.Detail)}
	} else {
		out.OK = true
	}
	b, _ := json.Marshal(out.Report)
	logx.Info("diag", "testFetch %s: ok=%v servers=%d format=%s report=%s", out.Host, out.OK, out.Servers, out.Format, b)
	return out, nil
}
