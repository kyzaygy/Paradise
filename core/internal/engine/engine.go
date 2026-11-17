// Package engine is the platform-independent application core.
// UIs talk to it through Call(method, jsonArgs) and get a JSON envelope back.
package engine

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/kyzaygy/paradise/core/internal/apperr"
	"github.com/kyzaygy/paradise/core/internal/logx"
	"github.com/kyzaygy/paradise/core/internal/model"
	"github.com/kyzaygy/paradise/core/internal/place"
	"github.com/kyzaygy/paradise/core/internal/rules"
	"github.com/kyzaygy/paradise/core/internal/store"
	"github.com/kyzaygy/paradise/core/internal/sub"
)

// Prober measures latency through a server using an Xray config.
type Prober interface {
	Probe(ctx context.Context, config []byte, url string) (int64, error)
}

// Device describes the host device.
type Device struct {
	Platform   string `json:"platform"`
	OSVersion  string `json:"osVersion"`
	Model      string `json:"model"`
	Locale     string `json:"locale"`
	AppVersion string `json:"appVersion"`
}

// Engine owns the document and all operations on it.
type Engine struct {
	mu     sync.Mutex
	doc    *model.Document
	store  *store.Store
	client *http.Client
	device Device
	prober Prober
	now    func() time.Time
	// validate checks an Xray config (core.LoadConfig); nil in unit tests.
	validate func([]byte) error

	probeMu     sync.Mutex
	probeCtx    context.Context
	probeCancel context.CancelFunc
	probeSlots  chan struct{}

	dir       string
	bigClient *http.Client
	places    map[string]place.Place // server key → detected location
	geoMu     sync.Mutex
	geoCache  map[string][]string // "ip:ru" / "site:google" → entries
	geoStamp  time.Time
}

// New opens the engine with an encrypted store in dir.
func New(dir string, key []byte, dev Device, prober Prober) (*Engine, error) {
	st, err := store.Open(dir, key)
	if err != nil {
		return nil, err
	}
	doc, err := st.Load()
	if err != nil {
		return nil, err
	}
	if dev.Platform == "" {
		dev.Platform = "iOS"
	}
	if dev.AppVersion == "" {
		dev.AppVersion = "0.1.0"
	}
	logx.Info("core", "opened: %d subscriptions, %d favorites", len(doc.Subscriptions), len(doc.Favorites))
	e := &Engine{doc: doc, store: st, client: sub.NewClient(), device: dev, prober: prober, now: time.Now, probeSlots: make(chan struct{}, 4),
		dir: dir, bigClient: &http.Client{Timeout: 3 * time.Minute}, places: map[string]place.Place{}, geoCache: map[string][]string{}}
	e.probeCtx, e.probeCancel = context.WithCancel(context.Background())
	changed := false
	if doc.HWID == "" {
		doc.HWID = randomHex(16)
		changed = true
	}
	if ensureDefaultConfig(doc, e.now()) {
		changed = true
	}
	if changed {
		_ = st.Save(doc)
	}
	return e, nil
}

// SetValidator installs the Xray config validator used by selfTest.
func (e *Engine) SetValidator(f func([]byte) error) { e.validate = f }

// SetHTTPClient replaces the subscription client (tests).
func (e *Engine) SetHTTPClient(c *http.Client) { e.client = c }

// SetClock replaces the clock (tests).
func (e *Engine) SetClock(f func() time.Time) { e.now = f }

func randomHex(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

func newID() string {
	b := make([]byte, 12)
	_, _ = rand.Read(b)
	return base64.RawURLEncoding.EncodeToString(b)
}

type envelope struct {
	OK    bool          `json:"ok"`
	Data  any           `json:"data,omitempty"`
	Error *apperr.Error `json:"error,omitempty"`
}

// Call dispatches a method with JSON arguments and returns a JSON envelope.
// Every call is timed and logged (method name only, never arguments).
func (e *Engine) Call(method, args string) (result string) {
	start := time.Now()
	if strings.TrimSpace(args) == "" {
		args = "{}"
	}
	var data any
	var err error
	func() {
		defer func() {
			if r := recover(); r != nil {
				logx.Error("core", "panic in %s: %v", method, r)
				err = apperr.New(apperr.Internal, "panic")
			}
		}()
		data, err = e.dispatch(method, []byte(args))
	}()
	ms := time.Since(start).Milliseconds()
	var out envelope
	if err != nil {
		ae := apperr.From(err)
		ae = &apperr.Error{Code: ae.Code, Detail: logx.Redact(ae.Detail)}
		out = envelope{OK: false, Error: ae}
		if ae.Code != apperr.Cancelled {
			logx.Warn("core", "%s failed in %dms: %s %s", method, ms, ae.Code, ae.Detail)
		}
	} else {
		out = envelope{OK: true, Data: data}
		if method != "logs" && method != "state" && method != "log" && method != "probe" && method != "configs" && method != "geoStatus" && method != "classify" {
			level := "info"
			if ms > 1500 {
				level = "warn"
			}
			logx.Add(level, "core", "%s ok in %dms", method, ms)
		}
	}
	b, mErr := json.Marshal(out)
	if mErr != nil {
		logx.Error("core", "%s: marshal failed", method)
		return `{"ok":false,"error":{"code":"internal","detail":"marshal"}}`
	}
	return string(b)
}

func decode(args []byte, v any) error {
	if err := json.Unmarshal(args, v); err != nil {
		return apperr.New(apperr.InvalidInput, "args")
	}
	return nil
}

func (e *Engine) dispatch(method string, args []byte) (any, error) {
	switch method {
	case "state":
		e.mu.Lock()
		defer e.mu.Unlock()
		return e.stateLocked(), nil
	case "classify":
		var in struct{ Text string }
		if err := decode(args, &in); err != nil {
			return nil, err
		}
		return map[string]string{"kind": Classify(in.Text)}, nil
	case "importText":
		var in struct{ Text string }
		if err := decode(args, &in); err != nil {
			return nil, err
		}
		return e.importText(in.Text)
	case "addSubscription":
		var in struct{ URL, Name string }
		if err := decode(args, &in); err != nil {
			return nil, err
		}
		return e.addSubscription(in.URL, in.Name)
	case "refresh":
		var in struct{ ID string }
		if err := decode(args, &in); err != nil {
			return nil, err
		}
		return e.refresh(in.ID)
	case "refreshAll":
		return e.refreshAll()
	case "deleteSubscription":
		var in struct{ ID string }
		if err := decode(args, &in); err != nil {
			return nil, err
		}
		return e.mutate(func(d *model.Document) error { return deleteSubscription(d, in.ID) })
	case "renameSubscription":
		var in struct{ ID, Name string }
		if err := decode(args, &in); err != nil {
			return nil, err
		}
		return e.mutate(func(d *model.Document) error {
			s := d.FindSubscription(in.ID)
			if s == nil {
				return apperr.New(apperr.NotFound, "subscription")
			}
			s.Name = clean(in.Name, 120)
			return nil
		})
	case "setFavorite":
		var in struct {
			Key      string
			Favorite bool
		}
		if err := decode(args, &in); err != nil {
			return nil, err
		}
		return e.mutate(func(d *model.Document) error { setFavorite(d, in.Key, in.Favorite); return nil })
	case "select":
		var in struct{ ID string }
		if err := decode(args, &in); err != nil {
			return nil, err
		}
		return e.mutate(func(d *model.Document) error {
			_, srv := d.FindServer(in.ID)
			if srv == nil {
				return apperr.New(apperr.NotFound, "server")
			}
			d.Selected, d.SelectedKey = srv.ID, srv.Key
			return nil
		})
	case "updateSettings":
		return e.mutate(func(d *model.Document) error { return applySettingsPatch(&d.Settings, args) })
	case "resetSettings":
		return e.mutate(func(d *model.Document) error {
			active := d.Settings.ActiveConfig
			d.Settings = model.DefaultSettings()
			d.Settings.ActiveConfig = active
			return nil
		})
	case "tunnelConfig":
		var in struct{ ID string }
		if err := decode(args, &in); err != nil {
			return nil, err
		}
		return e.tunnelConfig(in.ID)
	case "probe":
		var in struct{ ID, Iface string }
		if err := decode(args, &in); err != nil {
			return nil, err
		}
		return e.probe(in.ID, in.Iface)
	case "cancelProbes":
		e.CancelProbes()
		return map[string]bool{"cancelled": true}, nil
	case "exportTransfer":
		var in ExportOptions
		if err := decode(args, &in); err != nil {
			return nil, err
		}
		return e.exportTransfer(in)
	case "previewTransfer":
		var in struct{ Code, Password string }
		if err := decode(args, &in); err != nil {
			return nil, err
		}
		return e.previewTransfer(in.Code, in.Password)
	case "importTransfer":
		var in ImportOptions
		if err := decode(args, &in); err != nil {
			return nil, err
		}
		return e.importTransfer(in)
	case "logs":
		var in struct{ After int64 }
		if err := decode(args, &in); err != nil {
			return nil, err
		}
		return logx.Since(in.After), nil
	case "clearLogs":
		logx.Clear()
		return map[string]bool{"cleared": true}, nil
	case "log":
		var in struct{ Level, Source, Msg string }
		if err := decode(args, &in); err != nil {
			return nil, err
		}
		if in.Level != "warn" && in.Level != "error" {
			in.Level = "info"
		}
		if in.Source == "" {
			in.Source = "app"
		}
		logx.Add(in.Level, in.Source, "%s", in.Msg)
		return map[string]bool{"ok": true}, nil
	case "selfTest":
		return e.selfTest(), nil
	case "testFetch":
		var in struct{ ID, URL string }
		if err := decode(args, &in); err != nil {
			return nil, err
		}
		return e.testFetch(in.ID, in.URL)
	case "resetAll":
		return e.mutate(func(d *model.Document) error {
			*d = model.Document{Version: 1, HWID: randomHex(16), Settings: model.DefaultSettings()}
			ensureDefaultConfig(d, e.now())
			return nil
		})
	}
	if out, handled, err := e.dispatchExtra(method, args); handled {
		return out, err
	}
	return nil, apperr.New(apperr.InvalidInput, "method "+method)
}

// mutate applies f under the lock, saves, and returns the new state.
func (e *Engine) mutate(f func(d *model.Document) error) (any, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if err := f(e.doc); err != nil {
		return nil, err
	}
	if err := e.store.Save(e.doc); err != nil {
		return nil, err
	}
	return e.stateLocked(), nil
}

// applySettingsPatch overlays known JSON keys onto the settings and normalizes them.
func applySettingsPatch(s *model.Settings, args []byte) error {
	var patch map[string]json.RawMessage
	if err := json.Unmarshal(args, &patch); err != nil {
		return apperr.New(apperr.InvalidInput, "args")
	}
	current, _ := json.Marshal(s)
	var merged map[string]json.RawMessage
	_ = json.Unmarshal(current, &merged)
	for k, v := range patch {
		if _, known := merged[k]; known || k == "activeConfig" {
			merged[k] = v
		}
	}
	if raw, ok := patch["probeUrl"]; ok {
		var u string
		if json.Unmarshal(raw, &u) != nil {
			delete(merged, "probeUrl")
		} else if parsed, err := sub.ValidateURL(u); err == nil {
			b, _ := json.Marshal(parsed.String())
			merged["probeUrl"] = b
		} else {
			b, _ := json.Marshal(s.ProbeURL)
			merged["probeUrl"] = b
		}
	}
	b, _ := json.Marshal(merged)
	var next model.Settings
	if err := json.Unmarshal(b, &next); err != nil {
		return apperr.New(apperr.InvalidInput, "settings")
	}
	next.Normalize()
	*s = next
	return nil
}

func clean(s string, n int) string {
	s = strings.TrimSpace(strings.Map(func(r rune) rune {
		if r < 32 || r == 127 {
			return -1
		}
		return r
	}, s))
	if r := []rune(s); len(r) > n {
		return string(r[:n])
	}
	return s
}

func deleteSubscription(d *model.Document, id string) error {
	for i := range d.Subscriptions {
		if d.Subscriptions[i].ID == id {
			d.Subscriptions = append(d.Subscriptions[:i], d.Subscriptions[i+1:]...)
			if s, _ := d.FindServer(d.Selected); s == nil {
				d.Selected = ""
			}
			kept := d.Configs[:0]
			for _, c := range d.Configs {
				if c.Source == id {
					if d.Settings.ActiveConfig == c.ID {
						d.Settings.ActiveConfig = ""
					}
					continue
				}
				kept = append(kept, c)
			}
			d.Configs = kept
			return nil
		}
	}
	return apperr.New(apperr.NotFound, "subscription")
}

func setFavorite(d *model.Document, key string, on bool) {
	out := d.Favorites[:0]
	for _, k := range d.Favorites {
		if k != key {
			out = append(out, k)
		}
	}
	if on && key != "" {
		out = append(out, key)
	}
	d.Favorites = out
}

// Classify tells the UI how to treat pasted or scanned text.
func Classify(text string) string {
	t := strings.TrimSpace(text)
	switch {
	case t == "":
		return "empty"
	case isTransfer(t):
		return "transfer"
	case rules.IsRoutingLink(t) && !strings.ContainsAny(t, " \n\t"):
		return "routing"
	case strings.HasPrefix(strings.ToLower(t), "happ://crypt"):
		return "encrypted"
	case !strings.ContainsAny(t, " \n\t") && (strings.HasPrefix(strings.ToLower(t), "https://") || strings.HasPrefix(strings.ToLower(t), "http://")):
		return "url"
	case !strings.ContainsAny(t, " \n\t") && !strings.Contains(strings.ToLower(t), "://@") && appLink(t) != "":
		return "url"
	case looksLikeRuleConfig(t):
		return "ruleconfig"
	}
	return "config"
}

func (e *Engine) userAgent() string {
	return fmt.Sprintf("Paradise/%s (%s %s)", e.device.AppVersion, e.device.Platform, e.device.OSVersion)
}

func (e *Engine) deviceHeaders(sendHWID bool, hwid string) sub.Device {
	return sub.Device{HWID: hwid, OS: e.device.Platform, OSVersion: e.device.OSVersion, Model: e.device.Model, Locale: e.device.Locale, UserAgent: e.userAgent(), SendHWID: sendHWID}
}
