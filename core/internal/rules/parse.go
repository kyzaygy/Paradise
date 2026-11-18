// Package rules reads routing configurations written in the Shadowrocket/Surge text format
// ([General], [Rule], [Host]) and compiles them into Xray routing, DNS and tunnel routes.
//
// The format is a de-facto standard shared by several clients; only the parts that have
// an Xray equivalent are supported. Everything else is reported line by line.
package rules

import (
	"fmt"
	"net"
	"strconv"
	"strings"
)

// Policies after normalization.
const (
	Proxy  = "proxy"
	Direct = "direct"
	Block  = "block"
)

// Rule kinds.
const (
	KindFull    = "full"
	KindSuffix  = "suffix"
	KindKeyword = "keyword"
	KindRegex   = "regex"
	KindIP      = "ip"
	KindGeoIP   = "geoip"
	KindGeoSite = "geosite"
	KindPort    = "port"
	KindSet     = "set"
	KindFinal   = "final"
)

// Warning codes (the UI localizes them).
const (
	WarnUnsupportedRule   = "unsupported_rule"
	WarnUnsupportedPolicy = "policy_group"
	WarnInvalid           = "invalid_value"
	WarnUnknownSection    = "unknown_section"
	WarnGeoMissing        = "geo_missing"
	WarnSetMissing        = "set_missing"
	WarnTooMany           = "too_many"
	WarnDuplicateFinal    = "duplicate_final"
	WarnUnsupportedDNS    = "unsupported_dns"
)

// Warning points at a line of the config.
type Warning struct {
	Line int    `json:"line"`
	Code string `json:"code"`
	Text string `json:"text,omitempty"`
}

// Rule is one parsed rule line.
type Rule struct {
	Line      int
	Kind      string
	Value     string
	Policy    string
	NoResolve bool
	SetDomain bool // DOMAIN-SET (plain domain list) instead of RULE-SET
}

// Host is one [Host] entry.
type Host struct {
	Line  int
	Name  string
	Value string
}

// Config is a parsed text config.
type Config struct {
	General  map[string]string
	Lines    map[string]int // general key → line
	Rules    []Rule
	Hosts    []Host
	Final    string
	Warnings []Warning
	Ignored  []string // general keys and sections without an Xray equivalent
}

// MaxTextBytes limits configs pasted or downloaded.
const MaxTextBytes = 2 << 20

var knownGeneral = map[string]bool{
	"bypass-system": true, "skip-proxy": true, "tun-excluded-routes": true, "tun-included-routes": true, "bypass-tun": true,
	"dns-server": true, "fallback-dns-server": true, "ipv6": true, "update-url": true,
	"geoip-url": true, "geosite-url": true, "domain-strategy": true,
}

var ignoredSections = map[string]bool{
	"proxy": true, "proxy group": true, "url rewrite": true, "header rewrite": true, "mitm": true,
	"script": true, "map local": true, "body rewrite": true, "replica": true, "ssid setting": true,
}

// Parse reads a text config. It never fails: problems become warnings.
func Parse(text string) *Config {
	c := &Config{General: map[string]string{}, Lines: map[string]int{}}
	section := ""
	seenIgnored := map[string]bool{}
	ignore := func(name string) {
		if !seenIgnored[name] {
			seenIgnored[name] = true
			c.Ignored = append(c.Ignored, name)
		}
	}
	for i, raw := range strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n") {
		n := i + 1
		line := strings.TrimSpace(strings.TrimPrefix(raw, "\ufeff"))
		if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, ";") || strings.HasPrefix(line, "//") {
			continue
		}
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			section = strings.ToLower(strings.TrimSpace(line[1 : len(line)-1]))
			switch {
			case section == "general" || section == "rule" || section == "host":
			case ignoredSections[section]:
				ignore("[" + line[1:len(line)-1] + "]")
			default:
				c.Warnings = append(c.Warnings, Warning{Line: n, Code: WarnUnknownSection, Text: line})
			}
			continue
		}
		switch section {
		case "general":
			k, v, ok := strings.Cut(line, "=")
			if !ok {
				c.Warnings = append(c.Warnings, Warning{Line: n, Code: WarnInvalid, Text: short(line)})
				continue
			}
			key := strings.ToLower(strings.TrimSpace(k))
			if !knownGeneral[key] {
				ignore(key)
				continue
			}
			c.General[key] = strings.TrimSpace(v)
			c.Lines[key] = n
		case "rule":
			c.parseRule(n, line)
		case "host":
			k, v, ok := strings.Cut(line, "=")
			name, value := strings.TrimSpace(k), strings.TrimSpace(v)
			if !ok || name == "" || value == "" {
				c.Warnings = append(c.Warnings, Warning{Line: n, Code: WarnInvalid, Text: short(line)})
				continue
			}
			c.Hosts = append(c.Hosts, Host{Line: n, Name: strings.ToLower(name), Value: value})
		case "":
			// lines before any section: accept bare rules for convenience
			if strings.Contains(line, ",") {
				c.parseRule(n, line)
			} else {
				c.Warnings = append(c.Warnings, Warning{Line: n, Code: WarnInvalid, Text: short(line)})
			}
		}
	}
	if c.Final == "" {
		c.Final = Proxy
	}
	return c
}

func short(s string) string {
	if r := []rune(s); len(r) > 60 {
		return string(r[:60]) + "…"
	}
	return s
}

// NormalizePolicy maps policy names to proxy/direct/block. Named groups fall back to proxy.
func NormalizePolicy(p string) (string, bool) {
	switch strings.ToUpper(strings.TrimSpace(p)) {
	case "PROXY", "PROXY-ALL", "SELECT":
		return Proxy, true
	case "DIRECT":
		return Direct, true
	case "REJECT", "REJECT-DROP", "REJECT-TINYGIF", "REJECT-DICT", "REJECT-ARRAY", "REJECT-200", "REJECT-IMG", "REJECT-NO-DROP", "BLOCK":
		return Block, true
	}
	return Proxy, false
}

func (c *Config) parseRule(n int, line string) {
	parts := strings.Split(line, ",")
	for i := range parts {
		parts[i] = strings.TrimSpace(parts[i])
	}
	typ := strings.ToUpper(parts[0])
	warn := func(code, text string) {
		c.Warnings = append(c.Warnings, Warning{Line: n, Code: code, Text: short(text)})
	}
	if typ == "FINAL" || typ == "MATCH" {
		if len(parts) < 2 {
			warn(WarnInvalid, line)
			return
		}
		p, known := NormalizePolicy(parts[1])
		if !known {
			warn(WarnUnsupportedPolicy, parts[1])
		}
		if c.hasFinal() {
			warn(WarnDuplicateFinal, line)
			return
		}
		c.Final = p
		c.Rules = append(c.Rules, Rule{Line: n, Kind: KindFinal, Policy: p})
		return
	}
	if len(parts) < 3 {
		warn(WarnInvalid, line)
		return
	}
	value := parts[1]
	policy, known := NormalizePolicy(parts[2])
	if !known {
		warn(WarnUnsupportedPolicy, parts[2])
	}
	noResolve := false
	for _, opt := range parts[3:] {
		if strings.EqualFold(opt, "no-resolve") {
			noResolve = true
		}
	}
	r, code := ParseMatcher(typ, value)
	if code != "" {
		warn(code, line)
		return
	}
	r.Line, r.Policy, r.NoResolve = n, policy, noResolve
	c.Rules = append(c.Rules, r)
}

func (c *Config) hasFinal() bool {
	for _, r := range c.Rules {
		if r.Kind == KindFinal {
			return true
		}
	}
	return false
}

// ParseMatcher parses TYPE,VALUE (also used for RULE-SET lines). Returns a warning code on failure.
func ParseMatcher(typ, value string) (Rule, string) {
	value = strings.TrimSpace(value)
	if value == "" {
		return Rule{}, WarnInvalid
	}
	switch strings.ToUpper(typ) {
	case "DOMAIN", "HOST":
		return Rule{Kind: KindFull, Value: strings.ToLower(value)}, ""
	case "DOMAIN-SUFFIX", "HOST-SUFFIX":
		return Rule{Kind: KindSuffix, Value: strings.ToLower(strings.TrimPrefix(value, "."))}, ""
	case "DOMAIN-KEYWORD", "HOST-KEYWORD":
		return Rule{Kind: KindKeyword, Value: strings.ToLower(value)}, ""
	case "DOMAIN-REGEX":
		return Rule{Kind: KindRegex, Value: value}, ""
	case "DOMAIN-WILDCARD", "HOST-WILDCARD":
		return Rule{Kind: KindRegex, Value: wildcardRegex(strings.ToLower(value))}, ""
	case "IP-CIDR", "IP-CIDR6", "IP6-CIDR":
		cidr, ok := NormalizeCIDR(value)
		if !ok {
			return Rule{}, WarnInvalid
		}
		return Rule{Kind: KindIP, Value: cidr}, ""
	case "GEOIP":
		return Rule{Kind: KindGeoIP, Value: strings.ToLower(value)}, ""
	case "GEOSITE":
		return Rule{Kind: KindGeoSite, Value: strings.ToLower(value)}, ""
	case "DST-PORT", "DEST-PORT", "IN-PORT":
		if !validPort(value) {
			return Rule{}, WarnInvalid
		}
		return Rule{Kind: KindPort, Value: value}, ""
	case "RULE-SET":
		if !strings.HasPrefix(strings.ToLower(value), "https://") && !strings.HasPrefix(strings.ToLower(value), "http://") {
			return Rule{}, WarnUnsupportedRule
		}
		return Rule{Kind: KindSet, Value: value}, ""
	case "DOMAIN-SET":
		if !strings.HasPrefix(strings.ToLower(value), "https://") && !strings.HasPrefix(strings.ToLower(value), "http://") {
			return Rule{}, WarnUnsupportedRule
		}
		return Rule{Kind: KindSet, Value: value, SetDomain: true}, ""
	}
	return Rule{}, WarnUnsupportedRule
}

func wildcardRegex(v string) string {
	var b strings.Builder
	b.WriteString("^")
	for _, r := range v {
		switch r {
		case '*':
			b.WriteString(".*")
		case '?':
			b.WriteString(".")
		case '.', '+', '(', ')', '[', ']', '{', '}', '^', '$', '|', '\\':
			b.WriteRune('\\')
			b.WriteRune(r)
		default:
			b.WriteRune(r)
		}
	}
	b.WriteString("$")
	return b.String()
}

// NormalizeCIDR accepts "1.2.3.0/24", "1.2.3.4" and IPv6 forms.
func NormalizeCIDR(v string) (string, bool) {
	v = strings.TrimSpace(v)
	if !strings.Contains(v, "/") {
		ip := net.ParseIP(v)
		if ip == nil {
			return "", false
		}
		if ip.To4() != nil {
			return ip.String() + "/32", true
		}
		return ip.String() + "/128", true
	}
	_, n, err := net.ParseCIDR(v)
	if err != nil {
		return "", false
	}
	return n.String(), true
}

func validPort(v string) bool {
	for _, part := range strings.Split(v, ",") {
		a, b, isRange := strings.Cut(strings.TrimSpace(part), "-")
		x, err := strconv.Atoi(a)
		if err != nil || x < 1 || x > 65535 {
			return false
		}
		if isRange {
			y, err := strconv.Atoi(b)
			if err != nil || y < x || y > 65535 {
				return false
			}
		}
	}
	return true
}

// List splits a comma-separated general value.
func List(v string) []string {
	var out []string
	for _, p := range strings.Split(v, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

// Bool reads true/false/yes/no/1/0.
func Bool(v string) (bool, bool) {
	switch strings.ToLower(strings.TrimSpace(v)) {
	case "true", "yes", "1", "on":
		return true, true
	case "false", "no", "0", "off":
		return false, true
	}
	return false, false
}

func (w Warning) String() string { return fmt.Sprintf("line %d: %s %s", w.Line, w.Code, w.Text) }
