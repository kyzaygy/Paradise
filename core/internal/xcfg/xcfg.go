// Package xcfg builds Xray configs for the tunnel and for latency probes.
package xcfg

import (
	"encoding/json"
	"strings"

	"github.com/kyzaygy/paradise/core/internal/apperr"
	"github.com/kyzaygy/paradise/core/internal/model"
	"github.com/kyzaygy/paradise/core/internal/rules"
)

type object = map[string]any

// PrivateCIDRs are routed directly and excluded from the tunnel.
var PrivateCIDRs = []string{
	"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8", "169.254.0.0/16",
	"100.64.0.0/10", "224.0.0.0/4", "255.255.255.255/32",
	"::1/128", "fc00::/7", "fe80::/10", "ff00::/8",
}

// DNSAddress is the in-tunnel address answered by Xray's DNS module when a config hijacks DNS.
const DNSAddress = "172.19.0.2"

// DefaultExcluded are routed outside the tunnel unless a config lists its own.
var DefaultExcluded = []string{
	"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "100.64.0.0/10", "224.0.0.0/4",
	"fe80::/10", "fc00::/7",
}

// Options control how a config is built.
type Options struct {
	Settings model.Settings
	Rules    *rules.Compiled // used in "config" mode
	// Interface binds outbound sockets to a physical interface (probes while the VPN is up).
	Interface string
}

// Net is handed to the Network Extension next to the Xray config.
type Net struct {
	MTU      int      `json:"mtu"`
	IPv6     bool     `json:"ipv6"`
	DNS      []string `json:"dns"`
	Excluded []string `json:"excluded"`
	Included []string `json:"included"`
	Reflect  []string `json:"reflect"`
	KeepLogs bool     `json:"keepLogs"`
}

// Result is a built config plus the number of provider rules dropped during sanitizing.
type Result struct {
	JSON         []byte
	DroppedRules int
	Net          Net
}

// Tunnel builds a config with a TUN inbound fed by the Network Extension.
func Tunnel(srv model.Server, o Options) (Result, error) {
	s := o.Settings
	cfg, _, dropped, err := base(srv, o, true)
	if err != nil {
		return Result{}, err
	}
	sniff := object{"enabled": s.Sniffing, "destOverride": []any{"http", "tls", "quic"}, "routeOnly": true}
	inbounds := []any{object{
		"tag":      "tun-in",
		"protocol": "tun",
		"settings": object{"name": "paradise", "mtu": s.MTU},
		"sniffing": sniff,
	}}
	if s.ProxyShare {
		listen := "127.0.0.1"
		if s.ProxyLAN {
			listen = "0.0.0.0"
		}
		inbounds = append(inbounds, object{
			"tag": "share-in", "protocol": "mixed", "listen": listen, "port": s.ProxyPort,
			"settings": object{"auth": "noauth", "udp": true}, "sniffing": sniff,
		})
	}
	cfg["inbounds"] = inbounds
	n := Net{MTU: s.MTU, IPv6: s.IPv6, DNS: append([]string{}, s.DNS...), KeepLogs: !s.AutoDeleteLogs}
	n.Excluded = append([]string{}, DefaultExcluded...)
	if s.Mode == "config" && o.Rules != nil {
		if len(o.Rules.Excluded) > 0 {
			n.Excluded = append([]string{"fe80::/10"}, o.Rules.Excluded...)
		}
		n.Included = append(n.Included, o.Rules.Included...)
		if o.Rules.IPv6 != nil && !*o.Rules.IPv6 {
			n.IPv6 = false
		}
		if o.Rules.Hijack {
			n.DNS = []string{DNSAddress}
		}
	}
	if s.HideVPNIcon {
		n.Excluded = append(n.Excluded, "0.0.0.0/31")
	}
	if s.LoopbackRoute {
		n.Included = append(n.Included, "10.7.0.1/32")
		n.Reflect = []string{"10.7.0.1"}
	}
	b, err := json.Marshal(cfg)
	if err != nil {
		return Result{}, apperr.New(apperr.Config, "marshal")
	}
	return Result{JSON: b, DroppedRules: dropped, Net: n}, nil
}

// Probe builds a config without inbounds; traffic is injected with core.Dial and always goes to the proxy.
func Probe(srv model.Server, o Options) ([]byte, error) {
	o.Settings.Mode = "all"
	o.Settings.ProxyShare = false
	o.Settings.UDPRelay = true
	o.Settings.BlockQUIC = false
	o.Rules = nil
	cfg, _, _, err := base(srv, o, false)
	if err != nil {
		return nil, err
	}
	cfg["inbounds"] = []any{}
	cfg["log"] = object{"loglevel": "none", "access": "none", "dnsLog": false}
	b, err := json.Marshal(cfg)
	if err != nil {
		return nil, apperr.New(apperr.Config, "marshal")
	}
	return b, nil
}

func isProxy(ob object) bool {
	p, _ := ob["protocol"].(string)
	switch p {
	case "freedom", "blackhole", "dns", "loopback", "":
		return false
	}
	return true
}

// tuneOutbound applies socket options, fragmentation and mux to a proxy outbound.
func tuneOutbound(ob object, s model.Settings, frag *model.Fragment, iface string) (usesFragment bool) {
	stream, _ := ob["streamSettings"].(map[string]any)
	if stream == nil {
		stream = object{}
	}
	// Xray 26 refuses configs that still carry the removed allowInsecure flag
	if tls, ok := stream["tlsSettings"].(map[string]any); ok {
		delete(tls, "allowInsecure")
	}
	network, _ := stream["network"].(string)
	protocol, _ := ob["protocol"].(string)
	udp := protocol == "hysteria" || protocol == "wireguard" || network == "hysteria" || network == "kcp" || network == "mkcp"
	sock, _ := stream["sockopt"].(map[string]any)
	if sock == nil {
		sock = object{}
	}
	if s.TCPFastOpen && !udp {
		sock["tcpFastOpen"] = true
	}
	if s.KeepAlive > 0 && !udp {
		sock["tcpKeepAliveInterval"] = s.KeepAlive
	}
	if iface != "" {
		sock["interface"] = iface
	}
	_, hasDialer := sock["dialerProxy"]
	_, chained := ob["proxySettings"]
	if frag != nil && !udp && !hasDialer && !chained {
		sock["dialerProxy"] = "fragment"
		usesFragment = true
	}
	if len(sock) > 0 {
		stream["sockopt"] = sock
		ob["streamSettings"] = stream
	}
	if s.Mux && !udp && network != "xhttp" && network != "splithttp" {
		flow := ""
		if settings, ok := ob["settings"].(map[string]any); ok {
			if vnext, ok := settings["vnext"].([]any); ok && len(vnext) > 0 {
				if v, ok := vnext[0].(map[string]any); ok {
					if users, ok := v["users"].([]any); ok && len(users) > 0 {
						if u, ok := users[0].(map[string]any); ok {
							flow, _ = u["flow"].(string)
						}
					}
				}
			}
		}
		switch protocol {
		case "vless", "vmess", "trojan", "shadowsocks":
			if flow == "" {
				if _, set := ob["mux"]; !set {
					ob["mux"] = object{"enabled": true, "concurrency": 8, "xudpConcurrency": 8, "xudpProxyUDP443": "reject"}
				}
			}
		}
	}
	return usesFragment
}

func fragmentOutbound(f *model.Fragment) object {
	frag := object{"packets": f.Packets, "length": f.Length, "interval": f.Interval}
	if f.MaxSplit != "" {
		frag["maxSplit"] = f.MaxSplit
	}
	settings := object{"fragment": frag}
	if len(f.Noises) > 0 {
		var noises []any
		for _, n := range f.Noises {
			e := object{"type": n.Type, "packet": n.Packet, "delay": n.Delay}
			if n.ApplyTo != "" {
				e["applyTo"] = n.ApplyTo
			}
			noises = append(noises, e)
		}
		settings["noises"] = noises
	}
	return object{"tag": "fragment", "protocol": "freedom", "settings": settings}
}

func base(srv model.Server, o Options, tunnel bool) (object, string, int, error) {
	s := o.Settings
	var cfg object
	proxyTag := "proxy"
	dropped := 0
	keepProfile := false
	if len(srv.Profile) > 0 {
		var err error
		keepProfile = s.Mode == "profile"
		cfg, proxyTag, dropped, err = fromProfile(srv.Profile, keepProfile)
		if err != nil {
			return nil, "", 0, err
		}
	} else {
		var out object
		if err := json.Unmarshal(srv.Outbound, &out); err != nil || out == nil {
			return nil, "", 0, apperr.New(apperr.Config, "outbound")
		}
		out["tag"] = "proxy"
		cfg = object{"outbounds": []any{out, object{"tag": "direct", "protocol": "freedom"}}}
	}
	cfg["log"] = logSection(s)

	frag := srv.Fragment
	if frag == nil && s.Fragment {
		frag = &model.Fragment{Packets: s.FragmentPackets, Length: s.FragmentLength, Interval: s.FragmentInterval}
	}
	outs, _ := cfg["outbounds"].([]any)
	usesFragment := false
	hasBlock := false
	for _, o2 := range outs {
		ob, _ := o2.(map[string]any)
		if ob == nil {
			continue
		}
		if tag, _ := ob["tag"].(string); tag == "block" {
			hasBlock = true
		}
		if isProxy(ob) && tuneOutbound(ob, s, frag, o.Interface) {
			usesFragment = true
		}
	}
	if !hasBlock {
		outs = append(outs, object{"tag": "block", "protocol": "blackhole"})
	}
	if usesFragment {
		outs = append(outs, fragmentOutbound(frag))
	}
	hijack := tunnel && s.Mode == "config" && o.Rules != nil && o.Rules.Hijack
	if hijack {
		outs = append(outs, object{"tag": "dns-out", "protocol": "dns"})
	}
	cfg["outbounds"] = outs

	var pre []any
	if hijack {
		pre = append(pre, object{"type": "field", "ip": []any{DNSAddress}, "port": "53", "outboundTag": "dns-out"})
	}
	if tunnel && !s.UDPRelay {
		pre = append(pre, object{"type": "field", "network": "udp", "port": "1-52,54-65535", "outboundTag": "block"})
	}
	if tunnel && s.BlockQUIC {
		pre = append(pre, object{"type": "field", "network": "udp", "port": "443", "outboundTag": "block"})
	}
	ipv6 := s.IPv6 && (o.Rules == nil || s.Mode != "config" || o.Rules.IPv6 == nil || *o.Rules.IPv6)
	if tunnel && !ipv6 {
		// IPv6 stays captured by the tunnel (no leak) and is refused, so apps fall back to IPv4
		pre = append(pre, object{"type": "field", "ip": []any{"::/0"}, "outboundTag": "block"})
	}

	if keepProfile {
		routing, _ := cfg["routing"].(map[string]any)
		if routing == nil {
			routing = object{"domainStrategy": "AsIs"}
			cfg["routing"] = routing
		}
		existing, _ := routing["rules"].([]any)
		routing["rules"] = append(pre, existing...)
		return cfg, proxyTag, dropped, nil
	}
	delete(cfg, "dns")
	delete(cfg, "observatory")
	delete(cfg, "burstObservatory")
	routing := object{"domainStrategy": "AsIs"}
	switch {
	case s.Mode == "direct" && tunnel:
		pre = append(pre, object{"type": "field", "network": "tcp,udp", "outboundTag": "direct"})
	case s.Mode == "config" && o.Rules != nil && tunnel:
		if hijack {
			// queries of Xray's own DNS client: direct servers first, the rest through the proxy
			if len(o.Rules.DNSDirect) > 0 {
				pre = append(pre, object{"type": "field", "inboundTag": []any{"dns-internal"}, "ip": toAny(o.Rules.DNSDirect), "outboundTag": "direct"})
			}
			pre = append(pre, object{"type": "field", "inboundTag": []any{"dns-internal"}, "outboundTag": proxyTag})
		}
		for _, r := range o.Rules.Rules {
			rule := object{"type": "field"}
			for k, v := range r {
				rule[k] = v
			}
			if rule["outboundTag"] == "proxy" {
				rule["outboundTag"] = proxyTag
			}
			pre = append(pre, rule)
		}
		routing["domainStrategy"] = o.Rules.DomainStrategy
		if hijack {
			servers := o.Rules.DNSServers
			hasPlain := false
			for _, sv := range servers {
				if _, ok := sv.(string); ok {
					hasPlain = true
				}
			}
			if !hasPlain {
				for _, d := range s.DNS {
					servers = append(servers, d)
				}
			}
			dns := object{"servers": servers, "tag": "dns-internal", "queryStrategy": "UseIP"}
			if !s.IPv6 || (o.Rules.IPv6 != nil && !*o.Rules.IPv6) {
				dns["queryStrategy"] = "UseIPv4"
			}
			if len(o.Rules.Hosts) > 0 {
				dns["hosts"] = o.Rules.Hosts
			}
			cfg["dns"] = dns
		}
	default:
		pre = append(pre,
			object{"type": "field", "ip": toAny(PrivateCIDRs), "outboundTag": "direct"},
			object{"type": "field", "network": "tcp,udp", "outboundTag": proxyTag},
		)
	}
	routing["rules"] = pre
	cfg["routing"] = routing
	return cfg, proxyTag, dropped, nil
}

func logSection(s model.Settings) object {
	access := "none"
	if s.ConnectionLog {
		access = "file"
	}
	return object{"loglevel": s.LogLevel, "access": access, "dnsLog": s.DNSLog}
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

func fromProfile(raw json.RawMessage, keepRouting bool) (object, string, int, error) {
	var cfg object
	if err := json.Unmarshal(raw, &cfg); err != nil || cfg == nil {
		return nil, "", 0, apperr.New(apperr.Config, "profile")
	}
	for _, k := range droppedSections {
		delete(cfg, k)
	}
	outs, _ := cfg["outbounds"].([]any)
	if len(outs) == 0 {
		return nil, "", 0, apperr.New(apperr.Config, "no outbounds")
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
		return nil, "", 0, apperr.New(apperr.Config, "no proxy outbound")
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
	}
	return cfg, firstProxy, dropped, nil
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
