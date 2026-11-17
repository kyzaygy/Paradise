package sub

import (
	"context"
	"fmt"
	"html"
	"net/http"
	"net/url"
	"regexp"
	"strings"

	"github.com/kyzaygy/paradise/core/internal/apperr"
	"github.com/kyzaygy/paradise/core/internal/model"
)

// Many providers hand out a "connect" page instead of a raw subscription: an HTML
// page with app buttons (happ://add/<url>, v2raytun://import/<url>, …), a redirect,
// or links shown only to known client User-Agents. Resolve digs through that.

// compatUserAgents are tried when a provider doesn't serve our own User-Agent.
// They are generic client identifiers used by panels to choose a plain link list.
var compatUserAgents = []string{"v2rayNG/1.10.5", "Streisand/1.6.40"}

const (
	maxFetches = 8
	maxDepth   = 2
)

var (
	reProxyURI = regexp.MustCompile(`(?i)\b(?:vless|vmess|trojan|ss|socks5?|hysteria2|hy2)://[^\s"'<>\\` + "`" + `]+`)
	reAnyURI   = regexp.MustCompile(`(?i)\b[a-z][a-z0-9+.-]{1,30}://[^\s"'<>\\` + "`" + `]+`)
	reRelHref  = regexp.MustCompile(`(?i)(?:href|src|action|content)\s*=\s*["']([^"'#]+)["']`)
	reAssets   = regexp.MustCompile(`(?i)\.(?:css|js|mjs|png|jpe?g|gif|svg|ico|webp|woff2?|ttf|map)(?:\?|$)`)
)

// Resolved is a successful resolution.
type Resolved struct {
	Parsed Parsed
	Header http.Header
	Report FetchReport
	Trace  []string
}

type candidate struct {
	url   string
	depth int
}

func unescapeBody(b []byte) string {
	s := string(b)
	s = strings.NewReplacer(`\/`, `/`, `&`, `&`, `=`, `=`, `:`, `:`, `/`, `/`).Replace(s)
	return html.UnescapeString(s)
}

// ExtractProxyURIs returns proxy links found anywhere in a text (HTML, JSON, anything).
func ExtractProxyURIs(body []byte) []string {
	seen := map[string]bool{}
	out := []string{}
	for _, m := range reProxyURI.FindAllString(unescapeBody(body), -1) {
		m = strings.TrimRight(m, ".,;)]}")
		if !seen[m] {
			seen[m] = true
			out = append(out, m)
		}
	}
	return out
}

// embeddedURL pulls a subscription URL out of an app deep link
// (happ://add/<url>, v2raytun://import/<url>, sing-box://import-remote-profile?url=…, sub://<base64>, …).
func embeddedURL(link string) string {
	low := strings.ToLower(link)
	if i := strings.Index(low, "https://"); i > 0 {
		return strings.TrimRight(link[i:], ".,;)]}")
	}
	if i := strings.Index(low, "http://"); i > 0 {
		return strings.TrimRight(link[i:], ".,;)]}")
	}
	if u, err := url.Parse(link); err == nil {
		for _, key := range []string{"url", "sub", "config", "link", "subscription"} {
			if v := u.Query().Get(key); strings.HasPrefix(strings.ToLower(v), "http") {
				return v
			}
		}
		if strings.HasPrefix(low, "sub://") {
			payload := strings.SplitN(link[6:], "#", 2)[0]
			if b, err := DecodeBase64(payload); err == nil && strings.HasPrefix(strings.ToLower(string(b)), "http") {
				return strings.TrimSpace(string(b))
			}
		}
	}
	for _, sep := range []string{"%3a%2f%2f", "%3A%2F%2F"} {
		if i := strings.Index(link, sep); i > 4 {
			start := strings.LastIndex(strings.ToLower(link[:i]), "http")
			if start >= 0 {
				if v, err := url.QueryUnescape(link[start:]); err == nil {
					return v
				}
			}
		}
	}
	return ""
}

func sameSite(a, b string) bool {
	tail := func(h string) string {
		parts := strings.Split(strings.ToLower(h), ".")
		if len(parts) <= 2 {
			return strings.Join(parts, ".")
		}
		return strings.Join(parts[len(parts)-2:], ".")
	}
	return tail(a) == tail(b)
}

// ExtractLinks finds likely subscription URLs inside a page.
// App deep links come first, then same-site links that look like subscriptions.
func ExtractLinks(body []byte, base *url.URL) []string {
	text := unescapeBody(body)
	seen := map[string]bool{base.String(): true}
	var deep, site []string
	add := func(list *[]string, raw string) {
		u, err := url.Parse(strings.TrimSpace(raw))
		if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Hostname() == "" || reAssets.MatchString(u.Path) {
			return
		}
		u.Fragment = ""
		s := u.String()
		if !seen[s] {
			seen[s] = true
			*list = append(*list, s)
		}
	}
	for _, m := range reAnyURI.FindAllString(text, -1) {
		m = strings.TrimRight(m, ".,;)]}")
		scheme := strings.ToLower(m[:strings.Index(m, "://")])
		switch scheme {
		case "vless", "vmess", "trojan", "ss", "socks", "socks5", "hysteria2", "hy2":
			continue
		case "http", "https":
			u, err := url.Parse(m)
			if err != nil || !sameSite(u.Hostname(), base.Hostname()) {
				continue
			}
			add(&site, m)
		default:
			if e := embeddedURL(m); e != "" {
				add(&deep, e)
			}
		}
	}
	for _, m := range reRelHref.FindAllStringSubmatch(text, -1) {
		ref := strings.TrimSpace(m[1])
		if ref == "" || strings.Contains(ref, "://") || strings.HasPrefix(ref, "javascript:") || strings.HasPrefix(ref, "mailto:") {
			continue
		}
		if strings.HasPrefix(strings.ToLower(ref), "0;") || strings.HasPrefix(strings.ToLower(ref), "0; url=") {
			ref = strings.TrimSpace(ref[strings.Index(ref, "=")+1:])
		}
		if r, err := base.Parse(ref); err == nil && sameSite(r.Hostname(), base.Hostname()) {
			add(&site, r.String())
		}
	}
	return append(deep, site...)
}

// Resolve downloads a subscription, digging through connect pages, redirects and
// User-Agent gating until it finds servers.
func Resolve(ctx context.Context, client *http.Client, raw string, d Device, subscriptionID string) (Resolved, error) {
	root, err := ValidateURL(raw)
	if err != nil {
		return Resolved{}, err
	}
	var trace []string
	queue := []candidate{{url: root.String(), depth: 0}}
	visited := map[string]bool{}
	fetches := 0
	var lastRep FetchReport
	var firstErr, lastErr error
	for len(queue) > 0 && fetches < maxFetches {
		c := queue[0]
		queue = queue[1:]
		if visited[c.url] {
			continue
		}
		visited[c.url] = true
		agents := []string{d.UserAgent}
		if c.depth == 0 {
			agents = append(agents, compatUserAgents...)
		}
		for _, ua := range agents {
			if fetches >= maxFetches || ctx.Err() != nil {
				break
			}
			fetches++
			dev := d
			dev.UserAgent = ua
			body, header, rep, err := FetchDetailed(ctx, client, c.url, dev)
			lastRep = rep
			step := fmt.Sprintf("%s [%s] → HTTP %d %s %dB", HostOf(c.url), shortUA(ua), rep.Status, rep.BodyKind, rep.Bytes)
			if err != nil {
				trace = append(trace, step+" "+apperr.From(err).Code)
				if firstErr == nil {
					firstErr = err
				}
				lastErr = err
				if ae := apperr.From(err); ae.Code == apperr.Network || ae.Code == apperr.Cancelled {
					break
				}
				continue
			}
			parsed, perr := Parse(body, subscriptionID)
			if perr == nil {
				trace = append(trace, step+fmt.Sprintf(" → %d servers (%s)", len(parsed.Servers), parsed.Format))
				return Resolved{Parsed: parsed, Header: header, Report: rep, Trace: trace}, nil
			}
			if found := serversFromURIs(ExtractProxyURIs(body), subscriptionID); len(found) > 0 {
				trace = append(trace, step+fmt.Sprintf(" → %d servers extracted from page", len(found)))
				return Resolved{Parsed: Parsed{Format: "extracted", Servers: found, Headers: http.Header{}}, Header: header, Report: rep, Trace: trace}, nil
			}
			links := []string{}
			if c.depth < maxDepth {
				base, _ := url.Parse(c.url)
				if rep.FinalHost != "" && rep.FinalHost != base.Hostname() {
					base.Host = rep.FinalHost
				}
				links = ExtractLinks(body, base)
				for _, l := range links {
					queue = append(queue, candidate{url: l, depth: c.depth + 1})
				}
			}
			trace = append(trace, step+fmt.Sprintf(" %s, %d links to follow", apperr.From(perr).Code, len(links)))
			if firstErr == nil || apperr.From(firstErr).Code == apperr.HTMLResponse {
				firstErr = perr
			}
			lastErr = perr
		}
	}
	if firstErr == nil {
		firstErr = lastErr
	}
	if firstErr == nil {
		firstErr = apperr.New(apperr.EmptySubscription, "")
	}
	return Resolved{Trace: trace, Report: lastRep}, firstErr
}

func serversFromURIs(uris []string, subscriptionID string) []model.Server {
	seen := map[string]bool{}
	out := []model.Server{}
	for _, u := range uris {
		srv, err := ParseURI(u)
		if err != nil || seen[srv.Key] {
			continue
		}
		seen[srv.Key] = true
		srv.ID = model.ServerID(subscriptionID, srv.Key)
		out = append(out, srv)
		if len(out) >= MaxServers {
			break
		}
	}
	return out
}

func shortUA(ua string) string {
	if i := strings.IndexAny(ua, " /"); i > 0 {
		return ua[:i]
	}
	return ua
}

// EmbeddedURL returns the subscription URL inside an app deep link, or "".
func EmbeddedURL(link string) string { return embeddedURL(link) }
