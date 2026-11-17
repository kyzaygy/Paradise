package engine

import (
	"encoding/json"
	"strings"
	"time"

	"github.com/kyzaygy/paradise/core/internal/apperr"
	"github.com/kyzaygy/paradise/core/internal/model"
	"github.com/kyzaygy/paradise/core/internal/sub"
	"github.com/kyzaygy/paradise/core/internal/transfer"
)

func isTransfer(text string) bool { return transfer.IsCode(text) }

// ExportOptions select what goes into a transfer code.
type ExportOptions struct {
	Format           string   `json:"format"` // "pd1" (default) | "svoi1"
	Name             string   `json:"name"`
	SubscriptionIDs  []string `json:"subscriptionIds"` // empty = all
	IncludeFavorites bool     `json:"includeFavorites"`
	IncludeSettings  bool     `json:"includeSettings"`
	IncludeIdentity  bool     `json:"includeIdentity"` // only for moving to your own device
	Password         string   `json:"password"`
	ExpiresInHours   int      `json:"expiresInHours"` // 0 = never
}

// ExportResult is a ready-to-share code.
type ExportResult struct {
	Code      string          `json:"code"`
	Link      string          `json:"link"`
	Format    string          `json:"format"`
	Chars     int             `json:"chars"`
	FitsQR    bool            `json:"fitsQr"`
	Encrypted bool            `json:"encrypted"`
	ExpiresAt int64           `json:"expiresAt,omitempty"`
	Counts    transfer.Counts `json:"counts"`
	Skipped   int             `json:"skipped"`
}

func (e *Engine) buildPayload(o ExportOptions) transfer.Payload {
	d := e.doc
	want := map[string]bool{}
	for _, id := range o.SubscriptionIDs {
		want[id] = true
	}
	p := transfer.Payload{V: transfer.PayloadVersion, App: "Paradise/" + e.device.AppVersion, Created: e.now().Unix(), Name: clean(o.Name, 120)}
	keys := map[string]bool{}
	for _, s := range d.Subscriptions {
		if len(want) > 0 && !want[s.ID] {
			continue
		}
		for _, srv := range s.Servers {
			keys[srv.Key] = true
		}
		if s.URL != "" {
			p.Subscriptions = append(p.Subscriptions, transfer.Source{Name: s.Name, URL: s.URL})
			continue
		}
		src := transfer.Source{Name: s.Name}
		for _, srv := range s.Servers {
			src.Servers = append(src.Servers, transfer.Config{Name: srv.Name, Outbound: srv.Outbound, Profile: srv.Profile})
		}
		if len(src.Servers) > 0 {
			p.Subscriptions = append(p.Subscriptions, src)
		}
	}
	if o.IncludeFavorites {
		for _, k := range d.Favorites {
			if keys[k] {
				p.Favorites = append(p.Favorites, k)
			}
		}
		if _, srv := d.ResolveSelected(); srv != nil && keys[srv.Key] {
			p.Selected = srv.Key
		}
	}
	if o.IncludeSettings {
		s := d.Settings
		p.Settings = &s
	}
	if o.IncludeIdentity && d.HWID != "" {
		p.Identity = &transfer.Identity{HWID: d.HWID}
	}
	return p
}

func (e *Engine) exportTransfer(o ExportOptions) (any, error) {
	e.mu.Lock()
	p := e.buildPayload(o)
	e.mu.Unlock()
	if len(p.Subscriptions) == 0 {
		return nil, apperr.New(apperr.TransferEmpty, "")
	}
	res := ExportResult{Counts: p.Count()}
	var err error
	switch o.Format {
	case "svoi1":
		res.Format = transfer.FormatSVOI1
		res.Code, res.Skipped, err = transfer.EncodeSVOI1(p, transfer.SVOIDevice{Model: e.device.Model, Locale: e.device.Locale, UserAgent: e.userAgent()})
	default:
		res.Format = transfer.FormatPD1
		opt := transfer.EncodeOptions{Password: o.Password}
		if o.ExpiresInHours > 0 {
			if o.ExpiresInHours > 24*365 {
				o.ExpiresInHours = 24 * 365
			}
			opt.ExpiresAt = e.now().Add(time.Duration(o.ExpiresInHours) * time.Hour).Unix()
		}
		res.Code, err = transfer.EncodePD1(p, opt)
		res.Encrypted = o.Password != ""
		res.ExpiresAt = opt.ExpiresAt
	}
	if err != nil {
		return nil, err
	}
	res.Chars = len(res.Code)
	res.FitsQR = len(transfer.LinkPrefix)+res.Chars <= transfer.QRMaxChars
	res.Link = transfer.LinkPrefix + res.Code
	return res, nil
}

// PreviewSource describes a source without secrets.
type PreviewSource struct {
	Name      string `json:"name"`
	Host      string `json:"host,omitempty"`
	Remote    bool   `json:"remote"`
	Servers   int    `json:"servers"`
	Duplicate bool   `json:"duplicate"`
}

// Preview is shown before import.
type Preview struct {
	Format      string          `json:"format"`
	Encrypted   bool            `json:"encrypted"`
	Locked      bool            `json:"locked"`
	ExpiresAt   int64           `json:"expiresAt,omitempty"`
	Name        string          `json:"name,omitempty"`
	App         string          `json:"app,omitempty"`
	Created     int64           `json:"created,omitempty"`
	Counts      transfer.Counts `json:"counts"`
	Sources     []PreviewSource `json:"sources"`
	HasSettings bool            `json:"hasSettings"`
	HasIdentity bool            `json:"hasIdentity"`
	Skipped     int             `json:"skipped"`
	Duplicates  int             `json:"duplicates"`
}

func (e *Engine) previewTransfer(code, password string) (any, error) {
	env, err := transfer.Inspect(code)
	if err != nil {
		return nil, err
	}
	if env.Encrypted && password == "" {
		if env.ExpiresAt > 0 && e.now().Unix() > env.ExpiresAt {
			return nil, apperr.New(apperr.TransferExpired, "")
		}
		return Preview{Format: env.Format, Encrypted: true, Locked: true, ExpiresAt: env.ExpiresAt, Sources: []PreviewSource{}}, nil
	}
	dec, err := transfer.Decode(code, password, e.now())
	if err != nil {
		return nil, err
	}
	p := dec.Payload
	pv := Preview{Format: dec.Envelope.Format, Encrypted: dec.Envelope.Encrypted, ExpiresAt: dec.Envelope.ExpiresAt, Name: p.Name, App: p.App, Created: p.Created, Counts: p.Count(), HasSettings: p.Settings != nil, HasIdentity: p.Identity != nil, Skipped: dec.Skipped, Sources: []PreviewSource{}}
	e.mu.Lock()
	defer e.mu.Unlock()
	for _, s := range p.Subscriptions {
		ps := PreviewSource{Name: s.Name, Remote: s.URL != "", Servers: len(s.Servers)}
		if s.URL != "" {
			ps.Host = sub.HostOf(s.URL)
		}
		ps.Duplicate = e.isDuplicate(s)
		if ps.Duplicate {
			pv.Duplicates++
		}
		pv.Sources = append(pv.Sources, ps)
	}
	return pv, nil
}

func normalizeURL(raw string) string {
	if u, err := sub.ValidateURL(raw); err == nil {
		return u.String()
	}
	return strings.TrimSpace(raw)
}

func (e *Engine) isDuplicate(s transfer.Source) bool {
	if s.URL != "" {
		link := normalizeURL(s.URL)
		for _, ex := range e.doc.Subscriptions {
			if ex.URL == link {
				return true
			}
		}
		return false
	}
	existing := map[string]bool{}
	for _, ex := range e.doc.Subscriptions {
		for _, srv := range ex.Servers {
			existing[srv.Key] = true
		}
	}
	for _, c := range s.Servers {
		srv, err := serverFromConfig(c, "probe")
		if err != nil || !existing[srv.Key] {
			return false
		}
	}
	return len(s.Servers) > 0
}

func serverFromConfig(c transfer.Config, subID string) (model.Server, error) {
	var m map[string]any
	var srv model.Server
	var err error
	if len(c.Profile) > 0 {
		if json.Unmarshal(c.Profile, &m) != nil || m == nil {
			return model.Server{}, apperr.New(apperr.TransferCorrupted, "profile")
		}
		outs, _ := m["outbounds"].([]any)
		srv, err = sub.ServerFromProfile(m, outs)
	} else {
		if json.Unmarshal(c.Outbound, &m) != nil || m == nil {
			return model.Server{}, apperr.New(apperr.TransferCorrupted, "outbound")
		}
		srv, err = sub.ServerFromOutbound(c.Name, m)
	}
	if err != nil {
		return model.Server{}, err
	}
	if c.Name != "" {
		srv.Name = c.Name
	}
	srv.ID = model.ServerID(subID, srv.Key)
	return srv, nil
}

// ImportOptions control how a transfer is applied.
type ImportOptions struct {
	Code          string `json:"code"`
	Password      string `json:"password"`
	Strategy      string `json:"strategy"` // "merge" (default) | "replace"
	ApplySettings bool   `json:"applySettings"`
	ApplyIdentity bool   `json:"applyIdentity"`
}

// ImportTransferResult tells the UI which subscriptions still need downloading.
type ImportTransferResult struct {
	State          State    `json:"state"`
	Added          int      `json:"added"`
	Duplicates     int      `json:"duplicates"`
	Invalid        int      `json:"invalid"`
	PendingRefresh []string `json:"pendingRefresh"`
}

func (e *Engine) importTransfer(o ImportOptions) (any, error) {
	dec, err := transfer.Decode(o.Code, o.Password, e.now())
	if err != nil {
		return nil, err
	}
	p := dec.Payload
	e.mu.Lock()
	defer e.mu.Unlock()
	res := ImportTransferResult{PendingRefresh: []string{}}
	doc := e.doc
	if o.Strategy == "replace" {
		doc.Subscriptions = nil
		doc.Favorites = nil
		doc.Selected, doc.SelectedKey = "", ""
	}
	for _, s := range p.Subscriptions {
		if o.Strategy != "replace" && e.isDuplicate(s) {
			res.Duplicates++
			continue
		}
		id := newID()
		ns := model.Subscription{ID: id, Name: s.Name, Servers: []model.Server{}}
		if s.URL != "" {
			u, err := sub.ValidateURL(s.URL)
			if err != nil {
				res.Invalid++
				continue
			}
			ns.URL = u.String()
			res.PendingRefresh = append(res.PendingRefresh, id)
		} else {
			seen := map[string]bool{}
			for _, c := range s.Servers {
				srv, err := serverFromConfig(c, id)
				if err != nil {
					res.Invalid++
					continue
				}
				if seen[srv.Key] {
					continue
				}
				seen[srv.Key] = true
				ns.Servers = append(ns.Servers, srv)
			}
			if len(ns.Servers) == 0 {
				continue
			}
			ns.UpdatedAt = e.now().UTC()
		}
		doc.Subscriptions = append(doc.Subscriptions, ns)
		res.Added++
	}
	for _, k := range p.Favorites {
		if !doc.IsFavorite(k) {
			doc.Favorites = append(doc.Favorites, k)
		}
	}
	if p.Selected != "" && (doc.Selected == "" || o.Strategy == "replace") {
		doc.Selected, doc.SelectedKey = "", p.Selected
	}
	if o.ApplySettings && p.Settings != nil {
		doc.Settings = *p.Settings
		doc.Settings.Normalize()
	}
	if o.ApplyIdentity && p.Identity != nil {
		doc.HWID = p.Identity.HWID
	}
	if err := e.store.Save(doc); err != nil {
		return nil, err
	}
	res.State = e.stateLocked()
	return res, nil
}
