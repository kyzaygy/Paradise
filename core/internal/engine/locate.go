package engine

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/kyzaygy/paradise/core/internal/logx"
	"github.com/kyzaygy/paradise/core/internal/model"
	"github.com/kyzaygy/paradise/core/internal/place"
)

// Server locations are looked up by IP only for servers whose name doesn't say the city.
// Results are cached in the document for 30 days.
const (
	locateTTL      = 30 * 24 * time.Hour
	locateMaxBatch = 40
)

// geoEndpoints answer {country, city} for an IP without an API key.
var geoEndpoints = []func(ip string) (string, func([]byte) (string, string)){
	func(ip string) (string, func([]byte) (string, string)) {
		return "https://ipinfo.io/" + ip + "/json", func(b []byte) (string, string) {
			var v struct{ Country, City string }
			_ = json.Unmarshal(b, &v)
			return v.Country, v.City
		}
	},
	func(ip string) (string, func([]byte) (string, string)) {
		return "https://ipwho.is/" + ip, func(b []byte) (string, string) {
			var v struct {
				Success     bool   `json:"success"`
				CountryCode string `json:"country_code"`
				City        string `json:"city"`
			}
			_ = json.Unmarshal(b, &v)
			if !v.Success {
				return "", ""
			}
			return v.CountryCode, v.City
		}
	},
}

func publicIP(ip net.IP) bool {
	return ip != nil && !ip.IsPrivate() && !ip.IsLoopback() && !ip.IsLinkLocalUnicast() && !ip.IsUnspecified() && !ip.IsMulticast()
}

func (e *Engine) lookupIP(ctx context.Context, ip string) (string, string) {
	for _, ep := range geoEndpoints {
		url, parse := ep(ip)
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		if err != nil {
			continue
		}
		req.Header.Set("Accept", "application/json")
		req.Header.Set("User-Agent", e.userAgent())
		resp, err := e.client.Do(req)
		if err != nil {
			continue
		}
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 16<<10))
		_ = resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			continue
		}
		cc, city := parse(b)
		cc = strings.ToUpper(strings.TrimSpace(cc))
		if len(cc) == 2 {
			return cc, clean(city, 60)
		}
	}
	return "", ""
}

// locateServers fills the location cache for servers without a city in their name.
func (e *Engine) locateServers() (any, error) {
	e.mu.Lock()
	if !e.doc.Settings.LocateServers {
		st := e.stateLocked()
		e.mu.Unlock()
		return st, nil
	}
	now := e.now()
	todo := map[string]bool{}
	for _, s := range e.doc.Subscriptions {
		for _, srv := range s.Servers {
			p := e.locate(srv)
			if p.Code != "" && p.City != "" {
				continue
			}
			if c, ok := e.doc.Places[srv.Address]; ok && now.Sub(c.At) < locateTTL {
				continue
			}
			if len(todo) < locateMaxBatch {
				todo[srv.Address] = true
			}
		}
	}
	e.mu.Unlock()
	if len(todo) == 0 {
		e.mu.Lock()
		defer e.mu.Unlock()
		return e.stateLocked(), nil
	}
	found := map[string]model.Located{}
	var mu sync.Mutex
	var wg sync.WaitGroup
	slots := make(chan struct{}, 4)
	for addr := range todo {
		wg.Add(1)
		go func(addr string) {
			defer wg.Done()
			slots <- struct{}{}
			defer func() { <-slots }()
			ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
			defer cancel()
			ip := net.ParseIP(addr)
			if ip == nil {
				ips, err := net.DefaultResolver.LookupIP(ctx, "ip", addr)
				if err != nil || len(ips) == 0 {
					return
				}
				ip = ips[0]
			}
			if !publicIP(ip) {
				mu.Lock()
				found[addr] = model.Located{At: now}
				mu.Unlock()
				return
			}
			cc, city := e.lookupIP(ctx, ip.String())
			if cc == "" {
				return
			}
			mu.Lock()
			found[addr] = model.Located{CC: cc, City: city, At: now}
			mu.Unlock()
		}(addr)
	}
	wg.Wait()
	logx.Info("place", "located %d of %d server addresses", len(found), len(todo))
	return e.mutate(func(d *model.Document) error {
		if d.Places == nil {
			d.Places = map[string]model.Located{}
		}
		for k, v := range found {
			d.Places[k] = v
		}
		return nil
	})
}

// placeOf merges the name-based guess with the IP lookup cache. Must be called with e.mu held.
func (e *Engine) placeOf(srv model.Server) place.Place {
	p := e.locate(srv)
	if c, ok := e.doc.Places[srv.Address]; ok && c.CC != "" {
		if p.Code == "" {
			p.Code = c.CC
		}
		if p.City == "" && p.Code == c.CC {
			p.City = c.City
		}
	}
	return p
}
