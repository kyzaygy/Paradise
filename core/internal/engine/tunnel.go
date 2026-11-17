package engine

import (
	"context"
	"time"

	"github.com/kyzaygy/paradise/core/internal/apperr"
	"github.com/kyzaygy/paradise/core/internal/xcfg"
)

// TunnelConfig is handed to the Network Extension.
type TunnelConfig struct {
	Config       string `json:"config"`
	ServerID     string `json:"serverId"`
	ServerName   string `json:"serverName"`
	Address      string `json:"address"`
	KillSwitch   bool   `json:"killSwitch"`
	DroppedRules int    `json:"droppedRules"`
}

func (e *Engine) tunnelConfig(id string) (any, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	_, srv := e.doc.FindServer(id)
	if srv == nil {
		if id == "" {
			_, srv = e.doc.ResolveSelected()
		}
		if srv == nil {
			return nil, apperr.New(apperr.NotFound, "server")
		}
	}
	res, err := xcfg.Tunnel(*srv, e.doc.Settings)
	if err != nil {
		return nil, err
	}
	e.doc.Selected, e.doc.SelectedKey = srv.ID, srv.Key
	_ = e.store.Save(e.doc)
	return TunnelConfig{Config: string(res.JSON), ServerID: srv.ID, ServerName: srv.Name, Address: srv.Address, KillSwitch: e.doc.Settings.KillSwitch, DroppedRules: res.DroppedRules}, nil
}

// ProbeResult is a latency measurement.
type ProbeResult struct {
	ID string `json:"id"`
	MS int64  `json:"ms"`
}

func (e *Engine) probe(id string) (any, error) {
	if e.prober == nil {
		return nil, apperr.New(apperr.ProbeFailed, "unavailable")
	}
	e.mu.Lock()
	_, srv := e.doc.FindServer(id)
	if srv == nil {
		e.mu.Unlock()
		return nil, apperr.New(apperr.NotFound, "server")
	}
	settings := e.doc.Settings
	cfg, err := xcfg.Probe(*srv, settings)
	e.mu.Unlock()
	if err != nil {
		return nil, err
	}
	e.probeMu.Lock()
	parent := e.probeCtx
	e.probeMu.Unlock()
	select {
	case e.probeSlots <- struct{}{}:
	case <-parent.Done():
		return nil, apperr.New(apperr.Cancelled, "")
	}
	defer func() { <-e.probeSlots }()
	ctx, cancel := context.WithTimeout(parent, 6*time.Second)
	defer cancel()
	ms, err := e.prober.Probe(ctx, cfg, settings.ProbeURL)
	if err != nil {
		if parent.Err() != nil {
			return nil, apperr.New(apperr.Cancelled, "")
		}
		if ae, ok := err.(*apperr.Error); ok {
			return nil, ae
		}
		return nil, apperr.New(apperr.ProbeFailed, "")
	}
	return ProbeResult{ID: id, MS: ms}, nil
}

// CancelProbes stops running and queued probes.
func (e *Engine) CancelProbes() {
	e.probeMu.Lock()
	defer e.probeMu.Unlock()
	e.probeCancel()
	e.probeCtx, e.probeCancel = context.WithCancel(context.Background())
}
