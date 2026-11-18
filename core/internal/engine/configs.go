package engine

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/kyzaygy/paradise/core/internal/apperr"
	"github.com/kyzaygy/paradise/core/internal/logx"
	"github.com/kyzaygy/paradise/core/internal/model"
	"github.com/kyzaygy/paradise/core/internal/rules"
	"github.com/kyzaygy/paradise/core/internal/sub"
	"github.com/kyzaygy/paradise/core/internal/xcfg"
)

// Limits for remote rule sets.
const (
	maxRuleSets     = 40
	maxRuleSetBytes = 4 << 20
)

// PublicConfig is a routing config summary for the UI.
type PublicConfig struct {
	ID        string     `json:"id"`
	Name      string     `json:"name"`
	Host      string     `json:"host,omitempty"`
	Remote    bool       `json:"remote"`
	Builtin   bool       `json:"builtin"`
	Provided  bool       `json:"provided"` // delivered by a subscription
	Active    bool       `json:"active"`
	Rules     int        `json:"rules"`
	UpdatedAt *time.Time `json:"updatedAt,omitempty"`
	LastError string     `json:"lastError,omitempty"`
}

// ConfigReport is the result of checking a config.
type ConfigReport struct {
	Warnings    []rules.Warning `json:"warnings"`
	Ignored     []string        `json:"ignored"`
	Stats       rules.Stats     `json:"stats"`
	MissingGeo  []string        `json:"missingGeo"`
	MissingSets []string        `json:"missingSets"`
	GeoCodes    []string        `json:"geoCodes"`
	Sets        []string        `json:"sets"`
	DNSHijack   bool            `json:"dnsHijack"`
	Final       string          `json:"final"`
	Valid       bool            `json:"valid"`
	Error       string          `json:"error,omitempty"`
}

// ConfigDetail is a full config for the editor.
type ConfigDetail struct {
	Config PublicConfig `json:"config"`
	Text   string       `json:"text"`
	Report ConfigReport `json:"report"`
}

func ensureDefaultConfig(d *model.Document, now time.Time) bool {
	for _, c := range d.Configs {
		if c.Builtin {
			return false
		}
	}
	d.Configs = append([]model.RuleConfig{{ID: "default", Name: rules.DefaultName, Text: rules.DefaultText, Builtin: true, UpdatedAt: now.UTC()}}, d.Configs...)
	return true
}

func countRules(text string) int {
	n := 0
	section := ""
	for _, l := range strings.Split(text, "\n") {
		l = strings.TrimSpace(l)
		if strings.HasPrefix(l, "[") {
			section = strings.ToLower(l)
			continue
		}
		if section == "[rule]" && l != "" && !strings.HasPrefix(l, "#") && !strings.HasPrefix(l, ";") && !strings.HasPrefix(l, "//") {
			n++
		}
	}
	return n
}

func publicConfig(d *model.Document, c *model.RuleConfig) PublicConfig {
	pc := PublicConfig{ID: c.ID, Name: c.Name, Remote: c.URL != "", Builtin: c.Builtin, Provided: c.Source != "", LastError: c.LastError, Rules: countRules(c.Text)}
	if c.URL != "" {
		pc.Host = sub.HostOf(c.URL)
	}
	if a := d.ActiveConfig(); a != nil && a.ID == c.ID {
		pc.Active = true
	}
	if !c.UpdatedAt.IsZero() {
		t := c.UpdatedAt
		pc.UpdatedAt = &t
	}
	return pc
}

// looksLikeRuleConfig recognizes pasted Shadowrocket-style configs.
func looksLikeRuleConfig(t string) bool {
	low := strings.ToLower(t)
	return strings.Contains(low, "[rule]") || (strings.Contains(low, "[general]") && strings.Contains(low, "="))
}

// appLink extracts a subscription URL from an app deep link (happ://add/…, v2raytun://import/…).
func appLink(t string) string { return sub.EmbeddedURL(t) }

// ---- rule sets ----

func (e *Engine) setPath(url string) string {
	h := sha256.Sum256([]byte(url))
	return filepath.Join(e.dir, "rulesets", hex.EncodeToString(h[:])[:24]+".list")
}

func (e *Engine) ruleSet(url string) ([]string, bool) {
	b, err := os.ReadFile(e.setPath(url))
	if err != nil {
		return nil, false
	}
	return strings.Split(string(b), "\n"), true
}

// fetchSets downloads rule sets; existing files are replaced only on success.
func (e *Engine) fetchSets(urls []string, force bool) map[string]string {
	errs := map[string]string{}
	if len(urls) > maxRuleSets {
		urls = urls[:maxRuleSets]
	}
	_ = os.MkdirAll(filepath.Join(e.dir, "rulesets"), 0o700)
	var mu sync.Mutex
	var wg sync.WaitGroup
	slots := make(chan struct{}, 4)
	for _, u := range urls {
		if !force {
			if _, err := os.Stat(e.setPath(u)); err == nil {
				continue
			}
		}
		wg.Add(1)
		go func(u string) {
			defer wg.Done()
			slots <- struct{}{}
			defer func() { <-slots }()
			b, err := e.downloadText(u, maxRuleSetBytes)
			if err == nil {
				err = writeAtomic(e.setPath(u), b)
			}
			if err != nil {
				mu.Lock()
				errs[u] = apperr.From(err).Code
				mu.Unlock()
				logx.Warn("config", "rule set %s: %s", sub.HostOf(u), apperr.From(err).Code)
			}
		}(u)
	}
	wg.Wait()
	return errs
}

func writeAtomic(path string, b []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return apperr.New(apperr.Storage, "mkdir")
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return apperr.New(apperr.Storage, "write")
	}
	if err := os.Rename(tmp, path); err != nil {
		return apperr.New(apperr.Storage, "rename")
	}
	return nil
}

func (e *Engine) downloadText(raw string, limit int64) ([]byte, error) {
	u, err := sub.ValidateURL(raw)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, apperr.New(apperr.InvalidInput, "url")
	}
	req.Header.Set("User-Agent", e.userAgent())
	resp, err := e.bigClient.Do(req)
	if err != nil {
		return nil, apperr.New(apperr.Network, "")
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, apperr.New(apperr.HTTPStatus, itoa(resp.StatusCode))
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, limit+1))
	if err != nil {
		return nil, apperr.New(apperr.Network, "read")
	}
	if int64(len(b)) > limit {
		return nil, apperr.New(apperr.TooLarge, "")
	}
	return b, nil
}

func itoa(n int) string {
	b, _ := json.Marshal(n)
	return string(b)
}

// ---- compile and check ----

// compileLocked compiles text with the current geo database and cached rule sets.
// It reads files but takes no locks other than the geo cache, so callers may hold e.mu.
func (e *Engine) compile(text string) (*rules.Config, *rules.Compiled) {
	c := rules.Parse(text)
	geo := e.geoSource(c)
	return c, rules.Compile(c, rules.Options{Geo: geo, Sets: e.ruleSet})
}

func (e *Engine) report(text string, srv *model.Server, settings model.Settings) ConfigReport {
	c, comp := e.compile(text)
	r := ConfigReport{
		Warnings: comp.Warnings, Ignored: c.Ignored, Stats: comp.Stats, MissingGeo: comp.MissingGeo, MissingSets: comp.MissingSets,
		GeoCodes: comp.GeoCodes, Sets: comp.Sets, DNSHijack: comp.Hijack, Final: comp.Final, Valid: true,
	}
	if r.Warnings == nil {
		r.Warnings = []rules.Warning{}
	}
	if r.Ignored == nil {
		r.Ignored = []string{}
	}
	if e.validate != nil {
		probe := model.Server{Outbound: json.RawMessage(`{"protocol":"freedom","tag":"proxy"}`)}
		if srv != nil {
			probe = *srv
		}
		settings.Mode = "config"
		res, err := xcfg.Tunnel(probe, xcfg.Options{Settings: settings, Rules: comp})
		if err == nil {
			err = e.validate(res.JSON)
		}
		if err != nil {
			r.Valid = false
			r.Error = logx.Redact(firstLine(err.Error()))
		}
	}
	return r
}

// ---- methods ----

func (e *Engine) dispatchExtra(method string, args []byte) (any, bool, error) {
	switch method {
	case "configs":
		e.mu.Lock()
		defer e.mu.Unlock()
		return e.stateLocked().Configs, true, nil
	case "getConfig":
		var in struct{ ID string }
		if err := decode(args, &in); err != nil {
			return nil, true, err
		}
		out, err := e.getConfig(in.ID)
		return out, true, err
	case "checkConfig":
		var in struct{ Text string }
		if err := decode(args, &in); err != nil {
			return nil, true, err
		}
		if len(in.Text) > rules.MaxTextBytes {
			return nil, true, apperr.New(apperr.TooLarge, "")
		}
		e.mu.Lock()
		_, srv := e.doc.ResolveSelected()
		var cp *model.Server
		if srv != nil {
			c := *srv
			cp = &c
		}
		settings := e.doc.Settings
		e.mu.Unlock()
		return e.report(in.Text, cp, settings), true, nil
	case "saveConfig":
		var in struct{ ID, Name, Text string }
		if err := decode(args, &in); err != nil {
			return nil, true, err
		}
		out, err := e.saveConfig(in.ID, in.Name, in.Text, "")
		return out, true, err
	case "addConfigURL":
		var in struct{ URL, Name string }
		if err := decode(args, &in); err != nil {
			return nil, true, err
		}
		out, err := e.addConfigURL(in.URL, in.Name)
		return out, true, err
	case "updateConfig":
		var in struct{ ID string }
		if err := decode(args, &in); err != nil {
			return nil, true, err
		}
		out, err := e.updateConfig(in.ID)
		return out, true, err
	case "deleteConfig":
		var in struct{ ID string }
		if err := decode(args, &in); err != nil {
			return nil, true, err
		}
		out, err := e.mutate(func(d *model.Document) error {
			for i, c := range d.Configs {
				if c.ID == in.ID {
					if c.Builtin {
						return apperr.New(apperr.InvalidInput, "builtin")
					}
					d.Configs = append(d.Configs[:i], d.Configs[i+1:]...)
					if d.Settings.ActiveConfig == in.ID {
						d.Settings.ActiveConfig = ""
					}
					return nil
				}
			}
			return apperr.New(apperr.NotFound, "config")
		})
		return out, true, err
	case "resetConfig":
		var in struct{ ID string }
		if err := decode(args, &in); err != nil {
			return nil, true, err
		}
		out, err := e.mutate(func(d *model.Document) error {
			c := d.FindConfig(in.ID)
			if c == nil || !c.Builtin {
				return apperr.New(apperr.NotFound, "config")
			}
			c.Text, c.Name, c.UpdatedAt = rules.DefaultText, rules.DefaultName, e.now().UTC()
			return nil
		})
		return out, true, err
	case "activateConfig":
		var in struct{ ID string }
		if err := decode(args, &in); err != nil {
			return nil, true, err
		}
		out, err := e.mutate(func(d *model.Document) error {
			if d.FindConfig(in.ID) == nil {
				return apperr.New(apperr.NotFound, "config")
			}
			d.Settings.ActiveConfig = in.ID
			d.Settings.Mode = "config"
			return nil
		})
		return out, true, err
	case "importRouting":
		var in struct{ Link string }
		if err := decode(args, &in); err != nil {
			return nil, true, err
		}
		out, err := e.importRouting(in.Link, "")
		return out, true, err
	case "geoStatus":
		return e.geoStatus(), true, nil
	case "updateGeo":
		var in struct{ IPURL, SiteURL string }
		if err := decode(args, &in); err != nil {
			return nil, true, err
		}
		out, err := e.updateGeo(in.IPURL, in.SiteURL)
		return out, true, err
	case "deleteGeo":
		e.deleteGeo()
		return e.geoStatus(), true, nil
	case "exportServers":
		var in struct {
			Format         string
			SubscriptionID string
		}
		if err := decode(args, &in); err != nil {
			return nil, true, err
		}
		out, err := e.exportServers(in.Format, in.SubscriptionID)
		return out, true, err
	case "locateServers":
		out, err := e.locateServers()
		return out, true, err
	case "updateDueConfigs":
		return e.updateDueConfigs(), true, nil
	case "deleteAllServers":
		out, err := e.mutate(func(d *model.Document) error {
			d.Subscriptions = nil
			d.Selected, d.SelectedKey = "", ""
			d.Favorites = nil
			kept := d.Configs[:0]
			for _, c := range d.Configs {
				if c.Source == "" {
					kept = append(kept, c)
				}
			}
			d.Configs = kept
			return nil
		})
		return out, true, err
	}
	return nil, false, nil
}

func (e *Engine) getConfig(id string) (ConfigDetail, error) {
	e.mu.Lock()
	c := e.doc.FindConfig(id)
	if c == nil {
		e.mu.Unlock()
		return ConfigDetail{}, apperr.New(apperr.NotFound, "config")
	}
	pc := publicConfig(e.doc, c)
	text := c.Text
	_, srv := e.doc.ResolveSelected()
	var cp *model.Server
	if srv != nil {
		s := *srv
		cp = &s
	}
	settings := e.doc.Settings
	e.mu.Unlock()
	return ConfigDetail{Config: pc, Text: text, Report: e.report(text, cp, settings)}, nil
}

// SaveResult is returned when a config is created or changed.
type SaveResult struct {
	State  State        `json:"state"`
	ID     string       `json:"id"`
	Report ConfigReport `json:"report"`
}

func (e *Engine) saveConfig(id, name, text, url string) (SaveResult, error) {
	if len(text) > rules.MaxTextBytes {
		return SaveResult{}, apperr.New(apperr.TooLarge, "")
	}
	text = strings.ReplaceAll(text, "\r\n", "\n")
	name = clean(name, 80)
	e.mu.Lock()
	if id == "" {
		if name == "" {
			name = "Config"
		}
		id = newID()
		e.doc.Configs = append(e.doc.Configs, model.RuleConfig{ID: id, Name: name, Text: text, URL: url, UpdatedAt: e.now().UTC()})
	} else {
		c := e.doc.FindConfig(id)
		if c == nil {
			e.mu.Unlock()
			return SaveResult{}, apperr.New(apperr.NotFound, "config")
		}
		c.Text = text
		if name != "" {
			c.Name = name
		}
		c.UpdatedAt = e.now().UTC()
		c.LastError = ""
	}
	if err := e.store.Save(e.doc); err != nil {
		e.mu.Unlock()
		return SaveResult{}, err
	}
	e.mu.Unlock()
	c := rules.Parse(text)
	var sets []string
	for _, r := range c.Rules {
		if r.Kind == rules.KindSet {
			sets = append(sets, r.Value)
		}
	}
	if len(sets) > 0 {
		e.fetchSets(sets, false)
	}
	e.mu.Lock()
	_, srv := e.doc.ResolveSelected()
	var cp *model.Server
	if srv != nil {
		s := *srv
		cp = &s
	}
	settings := e.doc.Settings
	e.mu.Unlock()
	rep := e.report(text, cp, settings)
	e.mu.Lock()
	defer e.mu.Unlock()
	return SaveResult{State: e.stateLocked(), ID: id, Report: rep}, nil
}

func (e *Engine) addConfigURL(raw, name string) (SaveResult, error) {
	u, err := sub.ValidateURL(raw)
	if err != nil {
		return SaveResult{}, err
	}
	b, err := e.downloadText(u.String(), rules.MaxTextBytes)
	if err != nil {
		return SaveResult{}, err
	}
	text := strings.TrimPrefix(string(b), "\ufeff")
	if !looksLikeRuleConfig(text) {
		return SaveResult{}, apperr.New(apperr.UnsupportedFormat, "config")
	}
	if name == "" {
		name = configNameFromURL(u.Path)
	}
	return e.saveConfig("", name, text, u.String())
}

func configNameFromURL(path string) string {
	base := filepath.Base(path)
	base = strings.TrimSuffix(strings.TrimSuffix(base, ".conf"), ".txt")
	if base == "" || base == "." || base == "/" {
		return "Config"
	}
	return base
}

func (e *Engine) updateConfig(id string) (SaveResult, error) {
	e.mu.Lock()
	c := e.doc.FindConfig(id)
	if c == nil {
		e.mu.Unlock()
		return SaveResult{}, apperr.New(apperr.NotFound, "config")
	}
	url, text := c.URL, c.Text
	e.mu.Unlock()
	if url == "" {
		_, comp := e.compile(text)
		url = comp.UpdateURL
	}
	if url != "" {
		b, err := e.downloadText(url, rules.MaxTextBytes)
		if err == nil && !looksLikeRuleConfig(string(b)) {
			err = apperr.New(apperr.UnsupportedFormat, "config")
		}
		if err != nil {
			_, _ = e.mutate(func(d *model.Document) error {
				if c := d.FindConfig(id); c != nil {
					c.LastError = apperr.From(err).Code
				}
				return nil
			})
			return SaveResult{}, err
		}
		text = strings.TrimPrefix(string(b), "\ufeff")
	}
	parsed := rules.Parse(text)
	var sets []string
	for _, r := range parsed.Rules {
		if r.Kind == rules.KindSet {
			sets = append(sets, r.Value)
		}
	}
	e.fetchSets(sets, true)
	return e.saveConfig(id, "", text, "")
}

// RoutingResult reports an imported routing link.
type RoutingResult struct {
	State     State  `json:"state"`
	ID        string `json:"id,omitempty"`
	Name      string `json:"name,omitempty"`
	Activated bool   `json:"activated"`
	Off       bool   `json:"off"`
}

// importRouting adds a happ://routing/… profile as a config. source is a subscription id or "".
func (e *Engine) importRouting(link, source string) (RoutingResult, error) {
	r, err := rules.ParseRoutingLink(link)
	if err != nil {
		return RoutingResult{}, apperr.New(apperr.InvalidInput, err.Error())
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if r.Off {
		if a := e.doc.ActiveConfig(); a != nil && e.doc.Settings.Mode == "config" && (source == "" || a.Source == source) {
			e.doc.Settings.Mode = "all"
		}
		if err := e.store.Save(e.doc); err != nil {
			return RoutingResult{}, err
		}
		return RoutingResult{State: e.stateLocked(), Off: true}, nil
	}
	name := clean(r.Name, 80)
	var target *model.RuleConfig
	for i := range e.doc.Configs {
		c := &e.doc.Configs[i]
		if !c.Builtin && strings.EqualFold(c.Name, name) && (source == "" || c.Source == source || c.Source == "") {
			target = c
			break
		}
	}
	isNew := target == nil
	if isNew {
		e.doc.Configs = append(e.doc.Configs, model.RuleConfig{ID: newID(), Name: name})
		target = &e.doc.Configs[len(e.doc.Configs)-1]
	}
	target.Text, target.Source, target.UpdatedAt, target.LastError = r.Text, source, e.now().UTC(), ""
	activate := r.Activate && (source == "" || isNew)
	if source == "" && !r.Activate {
		activate = false
	}
	if activate {
		e.doc.Settings.ActiveConfig = target.ID
		e.doc.Settings.Mode = "config"
	}
	id := target.ID
	if err := e.store.Save(e.doc); err != nil {
		return RoutingResult{}, err
	}
	logx.Info("config", "routing profile imported (%d rules, activated %v)", countRules(r.Text), activate)
	return RoutingResult{State: e.stateLocked(), ID: id, Name: name, Activated: activate}, nil
}

// applyProvidedRouting stores routing links delivered with a subscription.
func (e *Engine) applyProvidedRouting(subID string, links []string) {
	for i, l := range links {
		if i >= 4 {
			break
		}
		if _, err := e.importRouting(l, subID); err != nil {
			logx.Warn("config", "provided routing skipped: %s", apperr.From(err).Detail)
		}
	}
}

// updateDueConfigs refreshes remote configs whose interval (update-url … interval=N, default 24 h) has passed.
func (e *Engine) updateDueConfigs() State {
	e.mu.Lock()
	now := e.now()
	var due []string
	for _, c := range e.doc.Configs {
		_, comp := e.compile(c.Text)
		if c.URL == "" && comp.UpdateURL == "" {
			continue
		}
		every := 24 * time.Hour
		if comp.UpdateMinutes > 0 {
			every = time.Duration(comp.UpdateMinutes) * time.Minute
		}
		if now.Sub(c.UpdatedAt) >= every {
			due = append(due, c.ID)
		}
	}
	e.mu.Unlock()
	for _, id := range due {
		if _, err := e.updateConfig(id); err != nil {
			logx.Warn("config", "update failed: %s", apperr.From(err).Code)
		}
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.stateLocked()
}
