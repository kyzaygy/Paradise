package engine

import (
	"context"
	"sync"
	"time"

	"github.com/kyzaygy/paradise/core/internal/apperr"
	"github.com/kyzaygy/paradise/core/internal/logx"
	"github.com/kyzaygy/paradise/core/internal/model"
	"github.com/kyzaygy/paradise/core/internal/sub"
)

// ImportResult is returned by importText and addSubscription.
type ImportResult struct {
	State          State  `json:"state"`
	SubscriptionID string `json:"subscriptionId"`
	Added          int    `json:"added"`
	Warnings       int    `json:"warnings"`
}

func (e *Engine) importText(text string) (any, error) {
	switch Classify(text) {
	case "empty":
		return nil, apperr.New(apperr.InvalidInput, "empty")
	case "transfer":
		return nil, apperr.New(apperr.InvalidInput, "transfer")
	case "url":
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
	e.mu.Lock()
	defer e.mu.Unlock()
	s := model.Subscription{ID: id, Servers: parsed.Servers, UpdatedAt: e.now().UTC(), Warnings: len(parsed.Warnings)}
	e.doc.Subscriptions = append(e.doc.Subscriptions, s)
	if err := e.store.Save(e.doc); err != nil {
		return nil, err
	}
	return ImportResult{State: e.stateLocked(), SubscriptionID: id, Added: len(parsed.Servers), Warnings: len(parsed.Warnings)}, nil
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
	parsed, meta, err := e.download(link, id, hwid, send)
	if err != nil {
		return nil, err
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	s := model.Subscription{ID: id, Name: clean(name, 120), URL: link, Servers: parsed.Servers, Meta: meta, UpdatedAt: e.now().UTC(), Warnings: len(parsed.Warnings)}
	e.doc.Subscriptions = append(e.doc.Subscriptions, s)
	if err := e.store.Save(e.doc); err != nil {
		return nil, err
	}
	return ImportResult{State: e.stateLocked(), SubscriptionID: id, Added: len(parsed.Servers), Warnings: len(parsed.Warnings)}, nil
}

func (e *Engine) download(link, id, hwid string, send bool) (sub.Parsed, *model.Meta, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	host := sub.HostOf(link)
	body, header, rep, err := sub.FetchDetailed(ctx, e.client, link, e.deviceHeaders(send, hwid))
	if err != nil {
		ae := apperr.From(err)
		logx.Warn("sub", "fetch %s: %s %s (status %d, %d bytes, %s, %dms)", host, ae.Code, ae.Detail, rep.Status, rep.Bytes, rep.BodyKind, rep.MS)
		return sub.Parsed{}, nil, err
	}
	parsed, err := sub.Parse(body, id)
	if err != nil {
		ae := apperr.From(err)
		logx.Warn("sub", "parse %s: %s %s (body %s, %d bytes, content-type %q)", host, ae.Code, ae.Detail, rep.BodyKind, rep.Bytes, rep.ContentType)
		for i, w := range parsed.Warnings {
			if i >= 5 {
				break
			}
			logx.Warn("sub", "  %s", w)
		}
		return parsed, nil, err
	}
	logx.Info("sub", "fetch %s: %d servers, format %s, %d bytes, %d warnings, %dms", host, len(parsed.Servers), parsed.Format, rep.Bytes, len(parsed.Warnings), rep.MS)
	for i, w := range parsed.Warnings {
		if i >= 5 {
			break
		}
		logx.Warn("sub", "  skipped %s", w)
	}
	return parsed, sub.ParseMeta(sub.MergeHeaders(parsed.Headers, header)), nil
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

	parsed, meta, err := e.download(link, id, hwid, send)

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
