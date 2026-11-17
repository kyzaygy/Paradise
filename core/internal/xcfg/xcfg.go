// Package xcfg builds Xray configs for the tunnel and for latency probes.
package xcfg

import (
	"encoding/json"
	"strings"

	"github.com/kyzaygy/paradise/core/internal/apperr"
	"github.com/kyzaygy/paradise/core/internal/model"
)

type object = map[string]any

// PrivateCIDRs are routed directly and excluded from the tunnel.
var PrivateCIDRs = []string{
	"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8", "169.254.0.0/16",
	"100.64.0.0/10", "224.0.0.0/4", "255.255.255.255/32",
	"::1/128", "fc00::/7", "fe80::/10", "ff00::/8",
}

// Result is a built config plus the number of provider rules dropped during sanitizing.
type Result struct {
	JSON         []byte
	DroppedRules int
}

// Tunnel builds a config with a TUN inbound fed by the Network Extension.
func Tunnel(srv model.Server, s model.Settings) (Result, error) {
	cfg, dropped, err := base(srv, s)
	if err != nil {
		return Result{}, err
	}
	cfg["inbounds"] = []any{object{
		"tag":      "tun-in",
		"protocol": "tun",
		"settings": object{"name": "paradise", "mtu": 1500},
		"sniffing": object{"enabled": true, "destOverride": []any{"http", "tls", "quic"}, "routeOnly": true},
	}}
	b, err := json.Marshal(cfg)
	if err != nil {
		return Result{}, apperr.New(apperr.Config, "marshal")
	}
	return Result{JSON: b, DroppedRules: dropped}, nil
}

// Probe builds a config without inbounds; traffic is injected with core.Dial.
func Probe(srv model.Server, s model.Settings) ([]byte, error) {
	cfg, _, err := base(srv, s)
	if err != nil {
		return nil, err
	}
	cfg["inbounds"] = []any{}
	b, err := json.Marshal(cfg)
	if err != nil {
		return nil, apperr.New(apperr.Config, "marshal")
	}
	return b, nil
}

func base(srv model.Server, s model.Settings) (object, int, error) {
	if len(srv.Profile) > 0 {
		return fromProfile(srv.Profile, s.Mode == "profile")
	}
	var out object
	if err := json.Unmarshal(srv.Outbound, &out); err != nil || out == nil {
		return nil, 0, apperr.New(apperr.Config, "outbound")
	}
	out["tag"] = "proxy"
	cfg := object{
		"log":       logSection(),
		"outbounds": []any{out, object{"tag": "direct", "protocol": "freedom"}, object{"tag": "block", "protocol": "blackhole"}},
		"routing": object{
			"domainStrategy": "AsIs",
			"rules": []any{
				object{"type": "field", "ip": toAny(PrivateCIDRs), "outboundTag": "direct"},
			},
		},
	}
	return cfg, 0, nil
}

func logSection() object {
	return object{"loglevel": "warning", "access": "none", "dnsLog": false}
}

func toAny(v []string) []any {
	out := make([]any, len(v))
	for i, s := range v {
		out[i] = s
	}
	return out
}

// Sections of provider profiles that need features we do not ship, or that expose local services.
var droppedSections = []string{"inbounds", "api", "stats", "metrics", "reverse", "log", "transport"}

func fromProfile(raw json.RawMessage, keepRouting bool) (object, int, error) {
	var cfg object
	if err := json.Unmarshal(raw, &cfg); err != nil || cfg == nil {
		return nil, 0, apperr.New(apperr.Config, "profile")
	}
	for _, k := range droppedSections {
		delete(cfg, k)
	}
	cfg["log"] = logSection()
	outs, _ := cfg["outbounds"].([]any)
	if len(outs) == 0 {
		return nil, 0, apperr.New(apperr.Config, "no outbounds")
	}
	firstProxy := ""
	hasDirect := false
	for _, o := range outs {
		ob, _ := o.(map[string]any)
		if ob == nil {
			continue
		}
		p, _ := ob["protocol"].(string)
		tag, _ := ob["tag"].(string)
		if p == "freedom" && tag == "direct" {
			hasDirect = true
		}
		if firstProxy == "" && p != "freedom" && p != "blackhole" && p != "dns" && p != "loopback" {
			if tag == "" {
				tag = "proxy"
				ob["tag"] = tag
			}
			firstProxy = tag
		}
	}
	if firstProxy == "" {
		return nil, 0, apperr.New(apperr.Config, "no proxy outbound")
	}
	if !hasDirect {
		outs = append(outs, object{"tag": "direct", "protocol": "freedom"})
		cfg["outbounds"] = outs
	}
	dropped := 0
	if keepRouting {
		if routing, ok := cfg["routing"].(map[string]any); ok {
			dropped = sanitizeRouting(routing)
		}
		if dns, ok := cfg["dns"].(map[string]any); ok {
			sanitizeDNS(dns)
		}
	} else {
		delete(cfg, "dns")
		delete(cfg, "observatory")
		delete(cfg, "burstObservatory")
		cfg["routing"] = object{
			"domainStrategy": "AsIs",
			"rules": []any{
				object{"type": "field", "ip": toAny(PrivateCIDRs), "outboundTag": "direct"},
				object{"type": "field", "network": "tcp,udp", "outboundTag": firstProxy},
			},
		}
	}
	return cfg, dropped, nil
}

// isGeo reports list entries that need geoip/geosite data files, which are not bundled.
func isGeo(v string) bool {
	l := strings.ToLower(v)
	return strings.HasPrefix(l, "geosite:") || strings.HasPrefix(l, "geoip:") || strings.HasPrefix(l, "ext:") || strings.HasPrefix(l, "ext-domain:") || strings.HasPrefix(l, "ext-ip:")
}

// cleanList removes geo entries; geoip:private is expanded into CIDRs.
func cleanList(v any) (list []any, had bool) {
	items, ok := v.([]any)
	if !ok {
		if s, isStr := v.(string); isStr {
			items = []any{s}
		} else {
			return nil, false
		}
	}
	had = len(items) > 0
	for _, it := range items {
		s, _ := it.(string)
		if s == "" {
			continue
		}
		low := strings.ToLower(s)
		switch {
		case low == "geoip:private" || low == "geoip:!private":
			if low == "geoip:private" {
				list = append(list, toAny(PrivateCIDRs)...)
			}
		case isGeo(s):
		default:
			list = append(list, s)
		}
	}
	return list, had
}

func sanitizeRouting(routing object) int {
	rules, _ := routing["rules"].([]any)
	kept := []any{}
	dropped := 0
	for _, r := range rules {
		rule, _ := r.(map[string]any)
		if rule == nil {
			continue
		}
		removed := false
		for _, field := range []string{"domain", "domains", "ip", "source", "sourceIP"} {
			v, ok := rule[field]
			if !ok {
				continue
			}
			list, had := cleanList(v)
			if had && len(list) == 0 {
				removed = true
				break
			}
			rule[field] = list
		}
		if removed {
			dropped++
			continue
		}
		kept = append(kept, rule)
	}
	routing["rules"] = kept
	if bal, ok := routing["balancers"].([]any); ok {
		routing["balancers"] = bal
	}
	return dropped
}

func sanitizeDNS(dns object) {
	if hosts, ok := dns["hosts"].(map[string]any); ok {
		for k := range hosts {
			if isGeo(k) {
				delete(hosts, k)
			}
		}
	}
	servers, _ := dns["servers"].([]any)
	kept := []any{}
	for _, s := range servers {
		srv, _ := s.(map[string]any)
		if srv == nil {
			kept = append(kept, s)
			continue
		}
		drop := false
		for _, field := range []string{"domains", "expectIPs", "expectedIPs", "unexpectedIPs"} {
			if v, ok := srv[field]; ok {
				list, had := cleanList(v)
				if field == "domains" && had && len(list) == 0 {
					drop = true
				}
				srv[field] = list
			}
		}
		if !drop {
			kept = append(kept, srv)
		}
	}
	if servers != nil {
		dns["servers"] = kept
	}
}
