package engine

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"strconv"
	"strings"
	"time"

	"github.com/kyzaygy/paradise/core/internal/apperr"
	"github.com/kyzaygy/paradise/core/internal/model"
	"github.com/kyzaygy/paradise/core/internal/place"
	"github.com/kyzaygy/paradise/core/internal/sub"
)

// ExportServersResult is a text file with servers.
type ExportServersResult struct {
	Text     string `json:"text"`
	Format   string `json:"format"`
	Count    int    `json:"count"`
	Skipped  int    `json:"skipped"`
	FileName string `json:"fileName"`
}

func (e *Engine) exportServers(format, subscriptionID string) (ExportServersResult, error) {
	e.mu.Lock()
	var servers []model.Server
	for _, s := range e.doc.Subscriptions {
		if subscriptionID != "" && s.ID != subscriptionID {
			continue
		}
		servers = append(servers, s.Servers...)
	}
	e.mu.Unlock()
	if len(servers) == 0 {
		return ExportServersResult{}, apperr.New(apperr.NotFound, "servers")
	}
	stamp := e.now().Format("2006-01-02")
	if format == "json" {
		var configs []any
		for _, srv := range servers {
			if len(srv.Profile) > 0 {
				var p map[string]any
				if json.Unmarshal(srv.Profile, &p) == nil {
					configs = append(configs, p)
				}
				continue
			}
			var out map[string]any
			if json.Unmarshal(srv.Outbound, &out) != nil {
				continue
			}
			out["tag"] = "proxy"
			configs = append(configs, map[string]any{
				"remarks":   srv.Name,
				"outbounds": []any{out, map[string]any{"tag": "direct", "protocol": "freedom"}},
			})
		}
		b, _ := json.MarshalIndent(configs, "", "  ")
		return ExportServersResult{Text: string(b), Format: "json", Count: len(configs), Skipped: len(servers) - len(configs), FileName: "Paradise-servers-" + stamp + ".json"}, nil
	}
	var lines []string
	skipped := 0
	for _, srv := range servers {
		if l, ok := sub.ToURI(srv); ok {
			lines = append(lines, l)
		} else {
			skipped++
		}
	}
	if len(lines) == 0 {
		return ExportServersResult{}, apperr.New(apperr.UnsupportedFormat, "links")
	}
	return ExportServersResult{Text: strings.Join(lines, "\n") + "\n", Format: "links", Count: len(lines), Skipped: skipped, FileName: "Paradise-servers-" + stamp + ".txt"}, nil
}

// prepareImport applies the "overwrite existing" and "auto rename" options to new local servers.
// It returns the number of replaced servers. Must be called with e.mu held.
func (e *Engine) prepareImport(servers []model.Server) ([]model.Server, int) {
	s := e.doc.Settings
	existingKeys := map[string]bool{}
	names := map[string]bool{}
	for _, sub := range e.doc.Subscriptions {
		for _, srv := range sub.Servers {
			if sub.URL == "" {
				existingKeys[srv.Key] = true
			}
			names[srv.Name] = true
		}
	}
	replaced := 0
	if s.OverwriteExisting {
		endpoint := func(srv model.Server) string {
			return srv.Protocol + "|" + strings.ToLower(srv.Address) + "|" + strconv.Itoa(srv.Port)
		}
		incoming := map[string]bool{}
		for _, srv := range servers {
			incoming[endpoint(srv)] = true
		}
		kept := e.doc.Subscriptions[:0]
		for _, sub := range e.doc.Subscriptions {
			if sub.URL == "" {
				left := sub.Servers[:0]
				for _, srv := range sub.Servers {
					if incoming[endpoint(srv)] {
						replaced++
						delete(existingKeys, srv.Key)
						delete(names, srv.Name)
						continue
					}
					left = append(left, srv)
				}
				sub.Servers = left
				if len(sub.Servers) == 0 {
					continue
				}
			}
			kept = append(kept, sub)
		}
		e.doc.Subscriptions = kept
	}
	out := servers[:0]
	for _, srv := range servers {
		if existingKeys[srv.Key] {
			continue
		}
		if s.AutoRename && names[srv.Name] {
			base := srv.Name
			for i := 2; i < 1000; i++ {
				candidate := fmt.Sprintf("%s %d", base, i)
				if !names[candidate] {
					srv.Name = candidate
					break
				}
			}
		}
		names[srv.Name] = true
		existingKeys[srv.Key] = true
		out = append(out, srv)
	}
	return out, replaced
}

// locate returns the detected location of a server (cached by key). Must be called with e.mu held.
func (e *Engine) locate(srv model.Server) place.Place {
	if p, ok := e.places[srv.Key]; ok {
		return p
	}
	p := place.Detect(srv.Name, srv.Address)
	if len(e.places) > 10000 {
		e.places = map[string]place.Place{}
	}
	e.places[srv.Key] = p
	return p
}

func udpServer(srv model.Server) bool {
	return srv.Protocol == "hysteria2" || srv.Protocol == "hysteria" || srv.Protocol == "wireguard" || srv.Network == "hysteria" || srv.Network == "kcp"
}

// tcpPing measures the TCP handshake time to a server, optionally bound to a physical interface
// so it bypasses the VPN tunnel.
func tcpPing(ctx context.Context, host string, port int, iface string) (int64, error) {
	d := net.Dialer{Timeout: 4 * time.Second}
	if iface != "" {
		if ifi, err := net.InterfaceByName(iface); err == nil {
			d.Control = bindControl(ifi.Index)
		}
	}
	addr := net.JoinHostPort(host, strconv.Itoa(port))
	if net.ParseIP(host) == nil {
		rctx, cancel := context.WithTimeout(ctx, 4*time.Second)
		ips, err := net.DefaultResolver.LookupIPAddr(rctx, host)
		cancel()
		if err != nil || len(ips) == 0 {
			return 0, apperr.New(apperr.ProbeFailed, "dns")
		}
		addr = net.JoinHostPort(ips[0].IP.String(), strconv.Itoa(port))
	}
	start := time.Now()
	conn, err := d.DialContext(ctx, "tcp", addr)
	if err != nil {
		if ctx.Err() == context.Canceled {
			return 0, apperr.New(apperr.Cancelled, "")
		}
		return 0, apperr.New(apperr.ProbeFailed, "")
	}
	ms := time.Since(start).Milliseconds()
	_ = conn.Close()
	if ms < 1 {
		ms = 1
	}
	return ms, nil
}
