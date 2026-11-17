package engine

import (
	"context"
	"encoding/json"
	"time"

	"github.com/kyzaygy/paradise/core/internal/apperr"
	"github.com/kyzaygy/paradise/core/internal/logx"
	"github.com/kyzaygy/paradise/core/internal/model"
	"github.com/kyzaygy/paradise/core/internal/xcfg"
)

// TunnelConfig is handed to the Network Extension.
type TunnelConfig struct {
	Config       string   `json:"config"`
	Net          string   `json:"net"` // JSON of xcfg.Net
	ServerID     string   `json:"serverId"`
	ServerName   string   `json:"serverName"`
	Address      string   `json:"address"`
	KillSwitch   bool     `json:"killSwitch"`
	ExcludeLocal bool     `json:"excludeLocal"`
	ExcludeAPNs  bool     `json:"excludeApns"`
	DroppedRules int      `json:"droppedRules"`
	Mode         string   `json:"mode"`
	ConfigName   string   `json:"configName,omitempty"`
	RuleWarnings int      `json:"ruleWarnings"`
	MissingGeo   []string `json:"missingGeo,omitempty"`
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
	s := e.doc.Settings
	opts := xcfg.Options{Settings: s}
	out := TunnelConfig{Mode: s.Mode}
	if s.Mode == "config" {
		if c := e.doc.ActiveConfig(); c != nil {
			_, comp := e.compile(c.Text)
			opts.Rules = comp
			out.ConfigName = c.Name
			out.RuleWarnings = len(comp.Warnings)
			out.MissingGeo = comp.MissingGeo
		} else {
			opts.Settings.Mode = "all"
			out.Mode = "all"
		}
	}
	if s.Mode == "profile" && len(srv.Profile) == 0 {
		opts.Settings.Mode = "all"
		out.Mode = "all"
	}
	res, err := xcfg.Tunnel(*srv, opts)
	if err != nil {
		return nil, err
	}
	if e.validate != nil {
		if err := e.validate(res.JSON); err != nil {
			return nil, apperr.New(apperr.Config, logx.Redact(firstLine(err.Error())))
		}
	}
	netJSON, _ := json.Marshal(res.Net)
	e.doc.Selected, e.doc.SelectedKey = srv.ID, srv.Key
	_ = e.store.Save(e.doc)
	out.Config, out.Net = string(res.JSON), string(netJSON)
	out.ServerID, out.ServerName, out.Address = srv.ID, srv.Name, srv.Address
	out.KillSwitch, out.ExcludeLocal, out.ExcludeAPNs = s.KillSwitch, s.ExcludeLocal, s.ExcludeAPNs
	out.DroppedRules = res.DroppedRules
	return out, nil
}

// ProbeResult is a latency measurement.
type ProbeResult struct {
	ID     string `json:"id"`
	MS     int64  `json:"ms"`
	Method string `json:"method"`
}

func (e *Engine) probe(id, iface string) (any, error) {
	e.mu.Lock()
	_, srv := e.doc.FindServer(id)
	if srv == nil {
		e.mu.Unlock()
		return nil, apperr.New(apperr.NotFound, "server")
	}
	settings := e.doc.Settings
	server := *srv
	e.mu.Unlock()
	if settings.TestMethod == "tcp" && !udpServer(server) {
		return e.probeTCP(id, server, iface)
	}
	if e.prober == nil {
		return nil, apperr.New(apperr.ProbeFailed, "unavailable")
	}
	cfg, err := xcfg.Probe(server, xcfg.Options{Settings: settings, Interface: iface})
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
	return ProbeResult{ID: id, MS: ms, Method: "proxy"}, nil
}

func (e *Engine) probeTCP(id string, srv model.Server, iface string) (any, error) {
	e.probeMu.Lock()
	parent := e.probeCtx
	e.probeMu.Unlock()
	select {
	case e.probeSlots <- struct{}{}:
	case <-parent.Done():
		return nil, apperr.New(apperr.Cancelled, "")
	}
	defer func() { <-e.probeSlots }()
	ctx, cancel := context.WithTimeout(parent, 5*time.Second)
	defer cancel()
	ms, err := tcpPing(ctx, srv.Address, srv.Port, iface)
	if err != nil {
		if parent.Err() != nil {
			return nil, apperr.New(apperr.Cancelled, "")
		}
		return nil, err
	}
	return ProbeResult{ID: id, MS: ms, Method: "tcp"}, nil
}

// CancelProbes stops running and queued probes.
func (e *Engine) CancelProbes() {
	e.probeMu.Lock()
	defer e.probeMu.Unlock()
	e.probeCancel()
	e.probeCtx, e.probeCancel = context.WithCancel(context.Background())
}
