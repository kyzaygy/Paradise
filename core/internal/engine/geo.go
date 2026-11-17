package engine

import (
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
)

const maxGeoBytes = 80 << 20

func (e *Engine) geoPath(kind string) string {
	return filepath.Join(e.dir, "geo", kind+".dat")
}

// GeoFile describes one downloaded database file.
type GeoFile struct {
	Present   bool       `json:"present"`
	Bytes     int64      `json:"bytes"`
	Codes     int        `json:"codes"`
	UpdatedAt *time.Time `json:"updatedAt,omitempty"`
}

// GeoStatus describes the geo database.
type GeoStatus struct {
	IP      GeoFile `json:"ip"`
	Site    GeoFile `json:"site"`
	IPURL   string  `json:"ipUrl"`
	SiteURL string  `json:"siteUrl"`
}

func (e *Engine) geoStatus() GeoStatus {
	e.mu.Lock()
	st := GeoStatus{IPURL: e.doc.Settings.GeoIPURL, SiteURL: e.doc.Settings.GeoSiteURL}
	e.mu.Unlock()
	for _, f := range []struct {
		kind string
		out  *GeoFile
	}{{"geoip", &st.IP}, {"geosite", &st.Site}} {
		info, err := os.Stat(e.geoPath(f.kind))
		if err != nil {
			continue
		}
		t := info.ModTime().UTC()
		f.out.Present, f.out.Bytes, f.out.UpdatedAt = true, info.Size(), &t
		if b, err := os.ReadFile(e.geoPath(f.kind) + ".codes"); err == nil {
			f.out.Codes = len(strings.Fields(string(b)))
		}
	}
	return st
}

// updateGeo downloads geoip.dat and geosite.dat. Empty URLs mean "use settings".
func (e *Engine) updateGeo(ipURL, siteURL string) (GeoStatus, error) {
	e.mu.Lock()
	if ipURL == "" {
		ipURL = e.doc.Settings.GeoIPURL
	}
	if siteURL == "" {
		siteURL = e.doc.Settings.GeoSiteURL
	}
	e.mu.Unlock()
	type result struct {
		kind  string
		data  []byte
		codes []string
		err   error
	}
	var wg sync.WaitGroup
	results := make([]result, 2)
	for i, job := range []struct{ kind, url string }{{"geoip", ipURL}, {"geosite", siteURL}} {
		wg.Add(1)
		go func(i int, kind, url string) {
			defer wg.Done()
			r := result{kind: kind}
			if !strings.HasPrefix(strings.ToLower(url), "https://") {
				r.err = apperr.New(apperr.InvalidInput, "https")
				results[i] = r
				return
			}
			start := time.Now()
			r.data, r.err = e.downloadText(url, maxGeoBytes)
			if r.err == nil {
				r.codes, r.err = rules.GeoCodes(r.data)
				if r.err == nil && len(r.codes) == 0 {
					r.err = apperr.New(apperr.UnsupportedFormat, "geo")
				} else if r.err != nil {
					r.err = apperr.New(apperr.UnsupportedFormat, "geo")
				}
			}
			if r.err == nil {
				logx.Info("geo", "%s from %s: %d bytes, %d codes, %dms", kind, sub.HostOf(url), len(r.data), len(r.codes), time.Since(start).Milliseconds())
			} else {
				logx.Warn("geo", "%s from %s failed: %s", kind, sub.HostOf(url), apperr.From(r.err).Code)
			}
			results[i] = r
		}(i, job.kind, job.url)
	}
	wg.Wait()
	for _, r := range results {
		if r.err != nil {
			return e.geoStatus(), r.err
		}
	}
	// replace both files only after both downloads succeeded
	for _, r := range results {
		if err := writeAtomic(e.geoPath(r.kind), r.data); err != nil {
			return e.geoStatus(), err
		}
		_ = writeAtomic(e.geoPath(r.kind)+".codes", []byte(strings.Join(r.codes, "\n")))
	}
	e.geoMu.Lock()
	e.geoCache = map[string][]string{}
	e.geoStamp = time.Now()
	e.geoMu.Unlock()
	if ipURL != "" || siteURL != "" {
		_, _ = e.mutate(func(d *model.Document) error {
			if strings.HasPrefix(ipURL, "https://") {
				d.Settings.GeoIPURL = ipURL
			}
			if strings.HasPrefix(siteURL, "https://") {
				d.Settings.GeoSiteURL = siteURL
			}
			d.Settings.Normalize()
			return nil
		})
	}
	return e.geoStatus(), nil
}

func (e *Engine) deleteGeo() {
	for _, k := range []string{"geoip", "geosite"} {
		_ = os.Remove(e.geoPath(k))
		_ = os.Remove(e.geoPath(k) + ".codes")
	}
	e.geoMu.Lock()
	e.geoCache = map[string][]string{}
	e.geoMu.Unlock()
}

// geoProvider serves preloaded geo entries to the rules compiler.
type geoProvider struct {
	ip, site map[string][]string
}

func (g geoProvider) IP(code string) ([]string, bool) {
	v, ok := g.ip[strings.ToLower(code)]
	return v, ok
}

func (g geoProvider) Site(code string) ([]string, bool) {
	v, ok := g.site[strings.ToLower(code)]
	return v, ok
}

// geoSource loads the codes a config uses (one pass per file) and caches them.
func (e *Engine) geoSource(c *rules.Config) rules.GeoSource {
	wantIP, wantSite := map[string]bool{}, map[string]bool{}
	for _, r := range c.Rules {
		switch r.Kind {
		case rules.KindGeoIP:
			wantIP[strings.TrimPrefix(r.Value, "!")] = true
		case rules.KindGeoSite:
			wantSite[r.Value] = true
		}
	}
	g := geoProvider{ip: map[string][]string{}, site: map[string][]string{}}
	if len(wantIP) == 0 && len(wantSite) == 0 {
		return g
	}
	e.geoMu.Lock()
	defer e.geoMu.Unlock()
	load := func(kind, prefix string, want map[string]bool, out map[string][]string, read func([]byte, map[string]bool) (map[string][]string, error)) {
		missing := map[string]bool{}
		for code := range want {
			if v, ok := e.geoCache[prefix+code]; ok {
				out[code] = v
			} else {
				missing[code] = true
			}
		}
		if len(missing) == 0 {
			return
		}
		data, err := os.ReadFile(e.geoPath(kind))
		if err != nil {
			return
		}
		found, err := read(data, missing)
		if err != nil {
			logx.Warn("geo", "%s is damaged: %v", kind, err)
			return
		}
		for code, list := range found {
			e.geoCache[prefix+code] = list
			out[code] = list
		}
	}
	load("geoip", "ip:", wantIP, g.ip, rules.ReadGeoIP)
	load("geosite", "site:", wantSite, g.site, rules.ReadGeoSite)
	return g
}
