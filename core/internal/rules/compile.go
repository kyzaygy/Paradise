package rules

import (
	"net"
	"sort"
	"strings"
)

// Limits keep the Network Extension under its memory ceiling.
const (
	MaxDomains = 60000
	MaxIPs     = 60000
)

// GeoSource returns CIDRs (geoip) and Xray domain matchers (geosite) for a code.
type GeoSource interface {
	IP(code string) ([]string, bool)
	Site(code string) ([]string, bool)
}

// SetSource returns cached lines of a RULE-SET / DOMAIN-SET URL.
type SetSource func(url string) ([]string, bool)

// Options control compilation.
type Options struct {
	Geo  GeoSource
	Sets SetSource
}

// Stats summarize a compiled config.
type Stats struct {
	Rules   int `json:"rules"`
	Domains int `json:"domains"`
	IPs     int `json:"ips"`
}

// Compiled is the Xray side of a text config.
type Compiled struct {
	Rules          []map[string]any
	DomainStrategy string
	Final          string
	Hosts          map[string]any
	DNSServers     []any
	DNSDirect      []string // plain-IP DNS servers queried directly (no #proxy)
	Hijack         bool     // send the device DNS into Xray's DNS module
	Excluded       []string
	Included       []string
	IPv6           *bool
	Stats          Stats
	Warnings       []Warning
	MissingGeo     []string
	MissingSets    []string
	GeoCodes       []string
	Sets           []string
	UpdateURL      string
	UpdateMinutes  int // update-url … interval=N
	GeoIPURL       string
	GeoSiteURL     string
}

// Tags maps policies to Xray outbound tags.
var Tags = map[string]string{Proxy: "proxy", Direct: "direct", Block: "block"}

type emitter struct {
	out     *Compiled
	policy  string
	field   string
	values  []any
	domains int
	ips     int
	capped  map[string]bool
}

func (e *emitter) flush() {
	if len(e.values) == 0 {
		return
	}
	rule := map[string]any{"outboundTag": Tags[e.policy]}
	if e.field == "port" {
		parts := make([]string, 0, len(e.values))
		for _, v := range e.values {
			parts = append(parts, v.(string))
		}
		rule["port"] = strings.Join(parts, ",")
	} else {
		rule[e.field] = e.values
	}
	e.out.Rules = append(e.out.Rules, rule)
	e.values = nil
}

func (e *emitter) add(line int, policy, field, value string) {
	switch field {
	case "domain":
		if e.domains >= MaxDomains {
			e.cap(line, "domains")
			return
		}
		e.domains++
	case "ip":
		if e.ips >= MaxIPs {
			e.cap(line, "ips")
			return
		}
		e.ips++
	}
	if policy != e.policy || field != e.field {
		e.flush()
		e.policy, e.field = policy, field
	}
	e.values = append(e.values, value)
}

func (e *emitter) cap(line int, what string) {
	if !e.capped[what] {
		e.capped[what] = true
		e.out.Warnings = append(e.out.Warnings, Warning{Line: line, Code: WarnTooMany, Text: what})
	}
}

func domainValue(kind, v string) string {
	switch kind {
	case KindFull:
		return "full:" + v
	case KindSuffix:
		return "domain:" + v
	case KindKeyword:
		return "keyword:" + v
	case KindRegex:
		return "regexp:" + v
	}
	return v
}

// Compile turns a parsed config into Xray routing, DNS and routes.
func Compile(c *Config, o Options) *Compiled {
	out := &Compiled{Final: c.Final, Warnings: append([]Warning{}, c.Warnings...), DomainStrategy: "AsIs"}
	e := &emitter{out: out, capped: map[string]bool{}}
	resolve := false
	missingGeo := map[string]bool{}
	missingSet := map[string]bool{}
	usedGeo := map[string]bool{}
	usedSet := map[string]bool{}

	// skip-proxy: always direct, before everything else
	for _, item := range List(c.General["skip-proxy"]) {
		line := c.Lines["skip-proxy"]
		if cidr, ok := NormalizeCIDR(item); ok {
			e.add(line, Direct, "ip", cidr)
			continue
		}
		item = strings.ToLower(item)
		switch {
		case strings.HasPrefix(item, "*.") && !strings.ContainsAny(item[2:], "*?"):
			e.add(line, Direct, "domain", "domain:"+item[2:])
		case strings.ContainsAny(item, "*?"):
			e.add(line, Direct, "domain", "regexp:"+wildcardRegex(item))
		default:
			e.add(line, Direct, "domain", "full:"+item)
		}
	}

	var emit func(r Rule, policy string, depth int)
	emit = func(r Rule, policy string, depth int) {
		switch r.Kind {
		case KindFull, KindSuffix, KindKeyword, KindRegex:
			e.add(r.Line, policy, "domain", domainValue(r.Kind, r.Value))
			out.Stats.Domains++
		case KindIP:
			e.add(r.Line, policy, "ip", r.Value)
			out.Stats.IPs++
			if !r.NoResolve {
				resolve = true
			}
		case KindPort:
			e.add(r.Line, policy, "port", r.Value)
		case KindGeoIP:
			code := strings.TrimPrefix(r.Value, "!")
			usedGeo["geoip:"+code] = true
			list, ok := []string(nil), false
			if o.Geo != nil {
				list, ok = o.Geo.IP(code)
			}
			if !ok {
				if !missingGeo["geoip:"+code] {
					missingGeo["geoip:"+code] = true
					out.Warnings = append(out.Warnings, Warning{Line: r.Line, Code: WarnGeoMissing, Text: "GEOIP," + strings.ToUpper(code)})
				}
				return
			}
			for _, v := range list {
				e.add(r.Line, policy, "ip", v)
			}
			out.Stats.IPs += len(list)
			if !r.NoResolve {
				resolve = true
			}
		case KindGeoSite:
			code := r.Value
			usedGeo["geosite:"+code] = true
			list, ok := []string(nil), false
			if o.Geo != nil {
				list, ok = o.Geo.Site(code)
			}
			if !ok {
				if !missingGeo["geosite:"+code] {
					missingGeo["geosite:"+code] = true
					out.Warnings = append(out.Warnings, Warning{Line: r.Line, Code: WarnGeoMissing, Text: "GEOSITE," + code})
				}
				return
			}
			for _, v := range list {
				e.add(r.Line, policy, "domain", v)
			}
			out.Stats.Domains += len(list)
		case KindSet:
			usedSet[r.Value] = true
			if depth > 0 {
				return
			}
			lines, ok := []string(nil), false
			if o.Sets != nil {
				lines, ok = o.Sets(r.Value)
			}
			if !ok {
				if !missingSet[r.Value] {
					missingSet[r.Value] = true
					out.Warnings = append(out.Warnings, Warning{Line: r.Line, Code: WarnSetMissing, Text: r.Value})
				}
				return
			}
			skipped := 0
			for _, l := range lines {
				sub, ok := setLine(l, r.SetDomain)
				if !ok {
					skipped++
					continue
				}
				sub.Line = r.Line
				if r.NoResolve {
					sub.NoResolve = true
				}
				emit(sub, policy, depth+1)
			}
			if skipped > 0 {
				out.Warnings = append(out.Warnings, Warning{Line: r.Line, Code: WarnUnsupportedRule, Text: itoa(skipped) + " × " + short(r.Value)})
			}
		}
	}

	for _, r := range c.Rules {
		if r.Kind == KindFinal {
			break
		}
		emit(r, r.Policy, 0)
		out.Stats.Rules++
	}
	e.flush()
	out.Rules = append(out.Rules, map[string]any{"network": "tcp,udp", "outboundTag": Tags[out.Final]})
	if resolve {
		out.DomainStrategy = "IPIfNonMatch"
	}
	if ds := c.General["domain-strategy"]; ds != "" {
		switch strings.ToLower(ds) {
		case "asis":
			out.DomainStrategy = "AsIs"
		case "ipifnonmatch":
			out.DomainStrategy = "IPIfNonMatch"
		case "ipondemand":
			out.DomainStrategy = "IPOnDemand"
		default:
			out.Warnings = append(out.Warnings, Warning{Line: c.Lines["domain-strategy"], Code: WarnInvalid, Text: ds})
		}
	}

	compileDNS(c, out)

	seenRoute := map[string]bool{}
	for _, key := range []string{"tun-excluded-routes", "bypass-tun", "tun-included-routes"} {
		for _, v := range List(c.General[key]) {
			cidr, ok := NormalizeCIDR(v)
			if !ok {
				out.Warnings = append(out.Warnings, Warning{Line: c.Lines[key], Code: WarnInvalid, Text: v})
				continue
			}
			if seenRoute[key[:3]+cidr] {
				continue
			}
			seenRoute[key[:3]+cidr] = true
			if key == "tun-included-routes" {
				out.Included = append(out.Included, cidr)
			} else {
				out.Excluded = append(out.Excluded, cidr)
			}
		}
	}
	if v, ok := c.General["ipv6"]; ok {
		if b, valid := Bool(v); valid {
			out.IPv6 = &b
		} else {
			out.Warnings = append(out.Warnings, Warning{Line: c.Lines["ipv6"], Code: WarnInvalid, Text: v})
		}
	}
	out.UpdateURL, out.UpdateMinutes = updateURL(c.General["update-url"])
	out.GeoIPURL = httpsURL(c.General["geoip-url"])
	out.GeoSiteURL = httpsURL(c.General["geosite-url"])
	out.MissingGeo = keys(missingGeo)
	out.MissingSets = keys(missingSet)
	out.GeoCodes = keys(usedGeo)
	out.Sets = keys(usedSet)
	sort.SliceStable(out.Warnings, func(i, j int) bool { return out.Warnings[i].Line < out.Warnings[j].Line })
	return out
}

// dnsServer maps a Shadowrocket DNS entry to Xray. Without "#proxy" servers are queried
// directly (Shadowrocket semantics); "#proxy" sends the query through the proxy.
// plainIP is set for direct UDP servers that need a routing rule.
func dnsServer(raw string) (server string, plainIP string, code string) {
	v := strings.TrimSpace(raw)
	viaProxy := false
	if i := strings.Index(v, "#"); i >= 0 {
		viaProxy = strings.EqualFold(strings.TrimSpace(v[i+1:]), "proxy")
		v = strings.TrimSpace(v[:i])
	}
	low := strings.ToLower(v)
	switch {
	case v == "":
		return "", "", WarnInvalid
	case low == "system":
		return "localhost", "", ""
	case net.ParseIP(strings.Trim(v, "[]")) != nil:
		if viaProxy {
			return strings.Trim(v, "[]"), "", ""
		}
		return strings.Trim(v, "[]"), strings.Trim(v, "[]"), ""
	case strings.HasPrefix(low, "https://"):
		if viaProxy {
			return v, "", ""
		}
		return "https+local://" + v[len("https://"):], "", ""
	case strings.HasPrefix(low, "quic://"):
		return "quic+local://" + v[len("quic://"):], "", ""
	case strings.HasPrefix(low, "tcp://"):
		if viaProxy {
			return v, "", ""
		}
		return "tcp+local://" + v[len("tcp://"):], "", ""
	case strings.HasPrefix(low, "https+local://"), strings.HasPrefix(low, "quic+local://"), strings.HasPrefix(low, "tcp+local://"):
		return v, "", ""
	}
	if host, port, err := net.SplitHostPort(v); err == nil && net.ParseIP(host) != nil && port != "" {
		if viaProxy {
			return v, "", ""
		}
		return v, host, ""
	}
	// tls:// (DNS over TLS) and anything else has no Xray client
	return "", "", WarnUnsupportedDNS
}

func compileDNS(c *Config, out *Compiled) {
	var servers []any
	system := false
	for _, key := range []string{"dns-server", "fallback-dns-server"} {
		for _, v := range List(c.General[key]) {
			srv, plain, code := dnsServer(v)
			if code != "" {
				out.Warnings = append(out.Warnings, Warning{Line: c.Lines[key], Code: code, Text: v})
				continue
			}
			if srv == "localhost" {
				system = true
			}
			if plain != "" {
				out.DNSDirect = append(out.DNSDirect, plain)
			}
			servers = append(servers, srv)
		}
	}
	hosts := map[string]any{}
	var perDomain []any
	for _, h := range c.Hosts {
		key := h.Name
		if strings.HasPrefix(key, "*.") {
			key = "domain:" + key[2:]
		} else if strings.ContainsAny(key, "*?") {
			key = "regexp:" + wildcardRegex(key)
		}
		if strings.HasPrefix(strings.ToLower(h.Value), "server:") {
			srv, plain, code := dnsServer(h.Value[len("server:"):])
			if code != "" {
				out.Warnings = append(out.Warnings, Warning{Line: h.Line, Code: code, Text: h.Value})
				continue
			}
			if plain != "" {
				out.DNSDirect = append(out.DNSDirect, plain)
			}
			perDomain = append(perDomain, map[string]any{"address": srv, "domains": []any{hostDomain(key)}})
			continue
		}
		hosts[key] = h.Value
	}
	if len(hosts) > 0 {
		out.Hosts = hosts
	}
	onlySystem := system && len(servers) == 1
	if len(perDomain) > 0 || (len(servers) > 0 && !onlySystem) || len(hosts) > 0 {
		out.Hijack = true
		out.DNSServers = append(perDomain, servers...)
	}
}

// updateURL reads "https://… interval=60 strict=true".
func updateURL(v string) (string, int) {
	fields := strings.Fields(v)
	if len(fields) == 0 {
		return "", 0
	}
	u := httpsURL(fields[0])
	minutes := 0
	for _, f := range fields[1:] {
		if k, val, ok := strings.Cut(f, "="); ok && strings.EqualFold(k, "interval") {
			n := 0
			for _, r := range val {
				if r < '0' || r > '9' {
					n = 0
					break
				}
				n = n*10 + int(r-'0')
			}
			if n >= 5 && n <= 10080 {
				minutes = n
			}
		}
	}
	return u, minutes
}

func hostDomain(key string) string {
	if strings.Contains(key, ":") {
		return key
	}
	return "full:" + key
}

func setLine(l string, domainSet bool) (Rule, bool) {
	l = strings.TrimSpace(l)
	if l == "" || strings.HasPrefix(l, "#") || strings.HasPrefix(l, ";") || strings.HasPrefix(l, "//") {
		return Rule{}, false
	}
	if domainSet {
		if strings.HasPrefix(l, ".") {
			return Rule{Kind: KindSuffix, Value: strings.ToLower(l[1:])}, true
		}
		if strings.Contains(l, ",") {
			return Rule{}, false
		}
		return Rule{Kind: KindFull, Value: strings.ToLower(l)}, true
	}
	parts := strings.Split(l, ",")
	if len(parts) < 2 {
		// plain domain lists are accepted in RULE-SET too
		if strings.HasPrefix(l, ".") {
			return Rule{Kind: KindSuffix, Value: strings.ToLower(l[1:])}, true
		}
		if cidr, ok := NormalizeCIDR(l); ok {
			return Rule{Kind: KindIP, Value: cidr}, true
		}
		return Rule{Kind: KindFull, Value: strings.ToLower(l)}, true
	}
	r, code := ParseMatcher(strings.TrimSpace(parts[0]), parts[1])
	if code != "" || r.Kind == KindSet {
		return Rule{}, false
	}
	for _, opt := range parts[2:] {
		if strings.EqualFold(strings.TrimSpace(opt), "no-resolve") {
			r.NoResolve = true
		}
	}
	return r, true
}

func httpsURL(v string) string {
	v = strings.TrimSpace(v)
	if strings.HasPrefix(strings.ToLower(v), "https://") {
		return v
	}
	return ""
}

func keys(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b []byte
	for n > 0 {
		b = append([]byte{byte('0' + n%10)}, b...)
		n /= 10
	}
	return string(b)
}
