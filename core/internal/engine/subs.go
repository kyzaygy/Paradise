package engine

import (
	"context"
	"strings"
	"sync"
	"time"

	"github.com/kyzaygy/paradise/core/internal/apperr"
	"github.com/kyzaygy/paradise/core/internal/logx"
	"github.com/kyzaygy/paradise/core/internal/model"
	"github.com/kyzaygy/paradise/core/internal/rules"
	"github.com/kyzaygy/paradise/core/internal/sub"
)

// ImportResult is returned by importText and addSubscription.
type ImportResult struct {
	State          State  `json:"state"`
	Kind           string `json:"kind"` // servers | routing | ruleconfig
	SubscriptionID string `json:"subscriptionId,omitempty"`
	ConfigID       string `json:"configId,omitempty"`
	Added          int    `json:"added"`
	Replaced       int    `json:"replaced"`
	Duplicates     int    `json:"duplicates"`
	Warnings       int    `json:"warnings"`
}

func (e *Engine) importText(text string) (any, error) {
	text = strings.TrimSpace(text)
	switch Classify(text) {
	case "empty":
		return nil, apperr.New(apperr.InvalidInput, "empty")
	case "transfer":
		return nil, apperr.New(apperr.InvalidInput, "transfer")
	case "encrypted":
		return nil, apperr.New(apperr.UnsupportedFormat, "happ-crypt")
	case "routing":
		r, err := e.importRouting(text, "")
		if err != nil {
			return nil, err
		}
		return ImportResult{State: r.State, Kind: "routing", ConfigID: r.ID}, nil
	case "ruleconfig":
		r, err := e.saveConfig("", "", text, "")
		if err != nil {
			return nil, err
		}
		return ImportResult{State: r.State, Kind: "ruleconfig", ConfigID: r.ID}, nil
	case "url":
		if !strings.HasPrefix(strings.ToLower(text), "http") {
			text = appLink(text)
		}
		return e.addSubscription(text, "")
	}
	if len(text) > sub.MaxBody {
		return nil, apperr.New(apperr.TooLarge, "text")
	}
	id := newID()
	parsed, err := sub.Parse([]byte(text), id)
	if err != nil {
		return nil, err
	}
	for _, l := range parsed.Routing {
		_, _ = e.importRouting(l, "")
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	total := len(parsed.Servers)
	servers, replaced := e.prepareImport(parsed.Servers)
	res := ImportResult{Kind: "servers", Added: len(servers), Replaced: replaced, Duplicates: total - len(servers), Warnings: len(parsed.Warnings)}
	if len(servers) > 0 {
		s := model.Subscription{ID: id, Servers: servers, UpdatedAt: e.now().UTC(), Warnings: len(parsed.Warnings)}
		e.doc.Subscriptions = append(e.doc.Subscriptions, s)
		res.SubscriptionID = id
	}
	if err := e.store.Save(e.doc); err != nil {
		return nil, err
	}
	if len(parsed.Servers) == 0 && len(parsed.Routing) > 0 {
		res.Kind = "routing"
	}
	res.State = e.stateLocked()
	return res, nil
}

func (e *Engine) addSubscription(raw, name string) (any, error) {
	u, err := sub.ValidateURL(raw)
	if err != nil {
		return nil, err
	}
	link := u.String()
	e.mu.Lock()
	for _, s := range e.doc.Subscriptions {
		if s.URL == link {
			e.mu.Unlock()
			return nil, apperr.New(apperr.InvalidInput, "duplicate")
		}
	}
	hwid, send := e.doc.HWID, e.doc.Settings.SendHWID
	e.mu.Unlock()

	id := newID()
	parsed, meta, routing, err := e.download(link, id, hwid, send)
	if err != nil {
		return nil, err
	}
	e.mu.Lock()
	s := model.Subscription{ID: id, Name: clean(name, 120), URL: link, Servers: parsed.Servers, Meta: meta, UpdatedAt: e.now().UTC(), Warnings: len(parsed.Warnings)}
	e.doc.Subscriptions = append(e.doc.Subscriptions, s)
	if err := e.store.Save(e.doc); err != nil {
		e.mu.Unlock()
		return nil, err
	}
	e.mu.Unlock()
	e.applyProvidedRouting(id, routing)
	e.mu.Lock()
	defer e.mu.Unlock()
	return ImportResult{State: e.stateLocked(), Kind: "servers", SubscriptionID: id, Added: len(parsed.Servers), Warnings: len(parsed.Warnings)}, nil
}

func (e *Engine) download(link, id, hwid string, send bool) (sub.Parsed, *model.Meta, []string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	host := sub.HostOf(link)
	res, err := sub.Resolve(ctx, e.client, link, e.deviceHeaders(send, hwid), id)
	for _, step := range res.Trace {
		logx.Info("sub", "  %s", step)
	}
	if err != nil {
		ae := apperr.From(err)
		logx.Warn("sub", "fetch %s failed: %s %s", host, ae.Code, ae.Detail)
		return sub.Parsed{}, nil, nil, err
	}
	parsed, header, rep := res.Parsed, res.Header, res.Report
	logx.Info("sub", "fetch %s: %d servers, format %s, %d bytes, %d warnings, %dms", host, len(parsed.Servers), parsed.Format, rep.Bytes, len(parsed.Warnings), rep.MS)
	for i, w := range parsed.Warnings {
		if i >= 5 {
			break
		}
		logx.Warn("sub", "  skipped %s", w)
	}
	routing := append([]string{}, parsed.Routing...)
	for _, v := range header.Values("routing") {
		for _, l := range strings.Split(v, "\n") {
			if l = strings.TrimSpace(l); rules.IsRoutingLink(l) {
				routing = append(routing, l)
			}
		}
	}
	if len(routing) > 0 {
		logx.Info("sub", "  provider routing: %d profile(s)", len(routing))
	}
	return parsed, sub.ParseMeta(sub.MergeHeaders(parsed.Headers, header)), routing, nil
}

// RefreshResult reports per-subscription errors.
type RefreshResult struct {
	State  State             `json:"state"`
	Errors map[string]string `json:"errors"`
}

func (e *Engine) refresh(id string) (any, error) {
	if err := e.refreshOne(id); err != nil {
		return nil, err
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.stateLocked(), nil
}

func (e *Engine) refreshOne(id string) error {
	e.mu.Lock()
	s := e.doc.FindSubscription(id)
	if s == nil {
		e.mu.Unlock()
		return apperr.New(apperr.NotFound, "subscription")
	}
	if s.URL == "" {
		e.mu.Unlock()
		return nil
	}
	link, hwid, send := s.URL, e.doc.HWID, e.doc.Settings.SendHWID
	e.mu.Unlock()

	parsed, meta, routing, err := e.download(link, id, hwid, send)
	if err == nil && len(routing) > 0 {
		e.applyProvidedRouting(id, routing)
	}

	e.mu.Lock()
	defer e.mu.Unlock()
	s = e.doc.FindSubscription(id)
	if s == nil {
		return apperr.New(apperr.NotFound, "subscription")
	}
	if err != nil {
		s.LastError = apperr.From(err).Code
		_ = e.store.Save(e.doc)
		return err
	}
	s.Servers = parsed.Servers
	s.Meta = meta
	s.UpdatedAt = e.now().UTC()
	s.LastError = ""
	s.Warnings = len(parsed.Warnings)
	if _, srv := e.doc.FindServer(e.doc.Selected); srv == nil {
		e.doc.Selected = ""
	}
	return e.store.Save(e.doc)
}

func (e *Engine) refreshAll() (any, error) {
	e.mu.Lock()
	ids := []string{}
	for _, s := range e.doc.Subscriptions {
		if s.URL != "" {
			ids = append(ids, s.ID)
		}
	}
	e.mu.Unlock()
	errs := map[string]string{}
	var mu sync.Mutex
	var wg sync.WaitGroup
	slots := make(chan struct{}, 3)
	for _, id := range ids {
		wg.Add(1)
		go func(id string) {
			defer wg.Done()
			slots <- struct{}{}
			defer func() { <-slots }()
			if err := e.refreshOne(id); err != nil {
				mu.Lock()
				errs[id] = apperr.From(err).Code
				mu.Unlock()
			}
		}(id)
	}
	wg.Wait()
	e.mu.Lock()
	defer e.mu.Unlock()
	return RefreshResult{State: e.stateLocked(), Errors: errs}, nil
}
