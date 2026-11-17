package rules

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"sort"
	"strings"
)

// Routing profile links used by Happ-compatible providers:
//
//	happ://routing/add/{base64 JSON}    add the profile
//	happ://routing/onadd/{base64 JSON}  add and activate it
//	happ://routing/off                  turn routing off
//
// The JSON fields (Name, GlobalProxy, DirectSites, DirectIp, ProxySites, ProxyIp, BlockSites,
// BlockIp, RemoteDNS*, DomesticDNS*, DnsHosts, Geoipurl, Geositeurl, DomainStrategy) are
// converted into an editable text config.

// RoutingLink is a parsed routing link.
type RoutingLink struct {
	Off      bool
	Activate bool
	Name     string
	Text     string
}

// IsRoutingLink reports happ://routing/… links.
func IsRoutingLink(s string) bool {
	return strings.HasPrefix(strings.ToLower(strings.TrimSpace(s)), "happ://routing/")
}

// ParseRoutingLink converts a routing link into a text config.
func ParseRoutingLink(link string) (RoutingLink, error) {
	link = strings.TrimSpace(link)
	rest := link[len("happ://routing/"):]
	action, payload, _ := strings.Cut(rest, "/")
	switch strings.ToLower(action) {
	case "off":
		return RoutingLink{Off: true}, nil
	case "add", "onadd":
	default:
		return RoutingLink{}, errors.New("unknown routing action")
	}
	payload = strings.TrimSpace(payload)
	var raw []byte
	var err error
	for _, enc := range []*base64.Encoding{base64.StdEncoding, base64.RawStdEncoding, base64.URLEncoding, base64.RawURLEncoding} {
		if raw, err = enc.DecodeString(payload); err == nil {
			break
		}
	}
	if err != nil {
		return RoutingLink{}, errors.New("invalid base64")
	}
	var p map[string]any
	if json.Unmarshal(raw, &p) != nil {
		return RoutingLink{}, errors.New("invalid json")
	}
	name, text := happText(p)
	return RoutingLink{Activate: strings.EqualFold(action, "onadd"), Name: name, Text: text}, nil
}

func happString(v any) string {
	switch x := v.(type) {
	case string:
		return strings.TrimSpace(x)
	case bool:
		if x {
			return "true"
		}
		return "false"
	case float64:
		return fmt.Sprint(x)
	}
	return ""
}

func happList(v any) []string {
	var out []string
	switch x := v.(type) {
	case []any:
		for _, it := range x {
			if s := happString(it); s != "" {
				out = append(out, s)
			}
		}
	case string:
		out = List(x)
	}
	return out
}

func happSite(entry, policy string) string {
	low := strings.ToLower(entry)
	switch {
	case strings.HasPrefix(low, "geosite:"):
		return "GEOSITE," + entry[len("geosite:"):] + "," + policy
	case strings.HasPrefix(low, "domain:"):
		return "DOMAIN-SUFFIX," + entry[len("domain:"):] + "," + policy
	case strings.HasPrefix(low, "full:"):
		return "DOMAIN," + entry[len("full:"):] + "," + policy
	case strings.HasPrefix(low, "keyword:"):
		return "DOMAIN-KEYWORD," + entry[len("keyword:"):] + "," + policy
	case strings.HasPrefix(low, "regexp:"):
		return "DOMAIN-REGEX," + entry[len("regexp:"):] + "," + policy
	}
	return "DOMAIN-SUFFIX," + entry + "," + policy
}

func happIP(entry, policy string) string {
	low := strings.ToLower(entry)
	if strings.HasPrefix(low, "geoip:") {
		return "GEOIP," + entry[len("geoip:"):] + "," + policy + ",no-resolve"
	}
	if strings.Contains(entry, ":") && !strings.Contains(entry, "/") && net.ParseIP(entry) == nil {
		return "# " + entry
	}
	return "IP-CIDR," + entry + "," + policy + ",no-resolve"
}

func happText(p map[string]any) (string, string) {
	name := happString(p["Name"])
	if name == "" {
		name = "Routing"
	}
	var b strings.Builder
	fmt.Fprintf(&b, "# %s\n# Imported from a routing link. Edit freely.\n\n[General]\n", name)
	var dns []string
	if d := happString(p["RemoteDNSDomain"]); strings.HasPrefix(strings.ToLower(d), "https://") {
		dns = append(dns, d)
	} else if ip := happString(p["RemoteDNSIP"]); net.ParseIP(ip) != nil {
		dns = append(dns, ip)
	}
	if len(dns) > 0 {
		fmt.Fprintf(&b, "dns-server = %s\n", strings.Join(dns, ", "))
	}
	if ds := happString(p["DomainStrategy"]); ds != "" {
		fmt.Fprintf(&b, "domain-strategy = %s\n", ds)
	}
	if u := happString(p["Geoipurl"]); strings.HasPrefix(strings.ToLower(u), "https://") {
		fmt.Fprintf(&b, "geoip-url = %s\n", u)
	}
	if u := happString(p["Geositeurl"]); strings.HasPrefix(strings.ToLower(u), "https://") {
		fmt.Fprintf(&b, "geosite-url = %s\n", u)
	}
	b.WriteString("\n[Rule]\n")
	for _, group := range []struct{ sites, ips, policy string }{
		{"BlockSites", "BlockIp", "REJECT"},
		{"ProxySites", "ProxyIp", "PROXY"},
		{"DirectSites", "DirectIp", "DIRECT"},
	} {
		for _, s := range happList(p[group.sites]) {
			b.WriteString(happSite(s, group.policy) + "\n")
		}
		for _, s := range happList(p[group.ips]) {
			b.WriteString(happIP(s, group.policy) + "\n")
		}
	}
	final := "PROXY"
	if g, ok := Bool(happString(p["GlobalProxy"])); ok && !g {
		final = "DIRECT"
	}
	fmt.Fprintf(&b, "FINAL,%s\n", final)
	if hosts, ok := p["DnsHosts"].(map[string]any); ok && len(hosts) > 0 {
		b.WriteString("\n[Host]\n")
		names := make([]string, 0, len(hosts))
		for k := range hosts {
			names = append(names, k)
		}
		sort.Strings(names)
		for _, k := range names {
			if v := happString(hosts[k]); v != "" {
				fmt.Fprintf(&b, "%s = %s\n", k, v)
			}
		}
	}
	return name, b.String()
}
