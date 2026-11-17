// Package model holds the persistent profile document.
package model

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net"
	"net/url"
	"regexp"
	"strings"
	"time"
)

// Server is one connectable node. Outbound is a single Xray outbound;
// Profile is a full Xray config (outbounds + routing) when the provider ships one.
type Server struct {
	ID       string          `json:"id"`
	Key      string          `json:"key"`
	Name     string          `json:"name"`
	Protocol string          `json:"protocol"`
	Address  string          `json:"address"`
	Port     int             `json:"port"`
	Network  string          `json:"network"`
	Security string          `json:"security"`
	Outbound json.RawMessage `json:"outbound,omitempty"`
	Profile  json.RawMessage `json:"profile,omitempty"`
	Desc     string          `json:"desc,omitempty"`
	Fragment *Fragment       `json:"fragment,omitempty"`
}

// Fragment is per-server TLS fragmentation and UDP noise (Happ-style link parameters).
type Fragment struct {
	Packets  string  `json:"packets,omitempty"`
	Length   string  `json:"length,omitempty"`
	Interval string  `json:"interval,omitempty"`
	MaxSplit string  `json:"maxSplit,omitempty"`
	Noises   []Noise `json:"noises,omitempty"`
}

// Noise is one Xray freedom noise entry.
type Noise struct {
	Type    string `json:"type"`
	Packet  string `json:"packet"`
	Delay   string `json:"delay,omitempty"`
	ApplyTo string `json:"applyTo,omitempty"`
}

// RuleConfig is a routing configuration in Shadowrocket-like text form.
type RuleConfig struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	Text      string    `json:"text"`
	URL       string    `json:"url,omitempty"`    // remote source for updates
	Source    string    `json:"source,omitempty"` // subscription id when provided by a subscription
	Builtin   bool      `json:"builtin,omitempty"`
	UpdatedAt time.Time `json:"updatedAt,omitempty"`
	LastError string    `json:"lastError,omitempty"`
}

// Meta is provider metadata from subscription response headers.
type Meta struct {
	Title       string `json:"title,omitempty"`
	Upload      int64  `json:"upload,omitempty"`
	Download    int64  `json:"download,omitempty"`
	Total       int64  `json:"total,omitempty"`
	Expire      int64  `json:"expire,omitempty"`
	UpdateHours int    `json:"updateHours,omitempty"`
	SupportURL  string `json:"supportUrl,omitempty"`
	WebURL      string `json:"webUrl,omitempty"`
	Announce    string `json:"announce,omitempty"`
}

// Subscription is a remote (URL) or local (imported configs) source of servers.
type Subscription struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	URL       string    `json:"url,omitempty"`
	Servers   []Server  `json:"servers"`
	Meta      *Meta     `json:"meta,omitempty"`
	UpdatedAt time.Time `json:"updatedAt,omitempty"`
	LastError string    `json:"lastError,omitempty"`
	Warnings  int       `json:"warnings,omitempty"`
}

// Settings are user preferences that affect connections.
type Settings struct {
	Mode         string `json:"mode"` // "all" | "config" | "profile" | "direct"
	ActiveConfig string `json:"activeConfig,omitempty"`
	KillSwitch   bool   `json:"killSwitch"`  // includeAllNetworks on iOS
	AutoRefresh  bool   `json:"autoRefresh"` // refresh subscriptions on launch
	RefreshHours int    `json:"refreshHours"`
	SendHWID     bool   `json:"sendHwid"` // send x-hwid and device headers
	ProbeURL     string `json:"probeUrl"`
	TestMethod   string `json:"testMethod"` // "tcp" | "proxy"

	MTU          int      `json:"mtu"`
	IPv6         bool     `json:"ipv6"`
	DNS          []string `json:"dns"`
	ExcludeLocal bool     `json:"excludeLocal"`
	ExcludeAPNs  bool     `json:"excludeApns"`
	Sniffing     bool     `json:"sniffing"`

	TCPFastOpen bool `json:"tcpFastOpen"`
	KeepAlive   int  `json:"keepAlive"` // seconds, 0 = system default
	Mux         bool `json:"mux"`

	UDPRelay  bool `json:"udpRelay"`
	BlockQUIC bool `json:"blockQuic"`

	ProxyShare bool `json:"proxyShare"`
	ProxyPort  int  `json:"proxyPort"`
	ProxyLAN   bool `json:"proxyLan"`

	Fragment         bool   `json:"fragment"`
	FragmentPackets  string `json:"fragmentPackets"`
	FragmentLength   string `json:"fragmentLength"`
	FragmentInterval string `json:"fragmentInterval"`

	LogLevel       string `json:"logLevel"` // none | error | warning | info | debug
	DNSLog         bool   `json:"dnsLog"`
	ConnectionLog  bool   `json:"connectionLog"`
	AutoDeleteLogs bool   `json:"autoDeleteLogs"`

	HideVPNIcon   bool `json:"hideVpnIcon"`   // exclude 0.0.0.0/31
	LoopbackRoute bool `json:"loopbackRoute"` // include 10.7.0.1/32 and reflect it back (StikDebug, SideStore)

	OverwriteExisting bool `json:"overwriteExisting"`
	AutoRename        bool `json:"autoRename"`

	GeoIPURL          string `json:"geoipUrl"`
	GeoSiteURL        string `json:"geositeUrl"`
	AutoUpdateConfigs bool   `json:"autoUpdateConfigs"`
}

// Geo database presets.
const (
	GeoIPLoyalsoldier   = "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
	GeoSiteLoyalsoldier = "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
	GeoIPRunet          = "https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geoip.dat"
	GeoSiteRunet        = "https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geosite.dat"
)

// DefaultSettings returns defaults for a fresh install.
func DefaultSettings() Settings {
	return Settings{
		Mode: "all", AutoRefresh: true, SendHWID: true, ProbeURL: "https://www.gstatic.com/generate_204", TestMethod: "tcp",
		MTU: 1500, IPv6: true, DNS: []string{"1.1.1.1", "8.8.8.8"}, ExcludeLocal: true, ExcludeAPNs: true, Sniffing: true,
		UDPRelay: true, ProxyPort: 1080,
		FragmentPackets: "tlshello", FragmentLength: "100-200", FragmentInterval: "10-20",
		LogLevel: "warning", AutoDeleteLogs: true, AutoRename: true,
		GeoIPURL: GeoIPLoyalsoldier, GeoSiteURL: GeoSiteLoyalsoldier, AutoUpdateConfigs: true,
	}
}

// UnmarshalJSON fills fields missing in older documents with defaults.
func (s *Settings) UnmarshalJSON(b []byte) error {
	type plain Settings
	p := plain(DefaultSettings())
	if err := json.Unmarshal(b, &p); err != nil {
		return err
	}
	*s = Settings(p)
	return nil
}

var rangeRe = regexp.MustCompile(`^[0-9]{1,5}(-[0-9]{1,5})?$`)

// ValidRange reports values like "10" or "10-20".
func ValidRange(v string) bool { return rangeRe.MatchString(v) }

func validHTTPS(raw string) bool {
	u, err := url.Parse(raw)
	return err == nil && u.Scheme == "https" && u.Host != ""
}

// Normalize fixes invalid values.
func (s *Settings) Normalize() {
	d := DefaultSettings()
	switch s.Mode {
	case "all", "config", "profile", "direct":
	default:
		s.Mode = "all"
	}
	if s.ProbeURL == "" {
		s.ProbeURL = d.ProbeURL
	}
	if s.TestMethod != "tcp" && s.TestMethod != "proxy" {
		s.TestMethod = d.TestMethod
	}
	if s.RefreshHours < 0 || s.RefreshHours > 168 {
		s.RefreshHours = 0
	}
	if s.MTU < 1280 || s.MTU > 9000 {
		s.MTU = d.MTU
	}
	var dns []string
	for _, v := range s.DNS {
		v = strings.TrimSpace(v)
		if net.ParseIP(v) != nil && len(dns) < 4 {
			dns = append(dns, v)
		}
	}
	if len(dns) == 0 {
		dns = d.DNS
	}
	s.DNS = dns
	if s.KeepAlive < 0 || s.KeepAlive > 600 {
		s.KeepAlive = 0
	}
	if s.ProxyPort < 1024 || s.ProxyPort > 65534 {
		s.ProxyPort = d.ProxyPort
	}
	if s.FragmentPackets != "tlshello" && !ValidRange(s.FragmentPackets) {
		s.FragmentPackets = d.FragmentPackets
	}
	if !ValidRange(s.FragmentLength) {
		s.FragmentLength = d.FragmentLength
	}
	if !ValidRange(s.FragmentInterval) {
		s.FragmentInterval = d.FragmentInterval
	}
	switch s.LogLevel {
	case "none", "error", "warning", "info", "debug":
	default:
		s.LogLevel = d.LogLevel
	}
	if !validHTTPS(s.GeoIPURL) {
		s.GeoIPURL = d.GeoIPURL
	}
	if !validHTTPS(s.GeoSiteURL) {
		s.GeoSiteURL = d.GeoSiteURL
	}
}

// Document is everything persisted by the core.
type Document struct {
	Version       int            `json:"version"`
	HWID          string         `json:"hwid"`
	Subscriptions []Subscription `json:"subscriptions"`
	Favorites     []string       `json:"favorites"`             // server keys
	Selected      string         `json:"selected"`              // server id
	SelectedKey   string         `json:"selectedKey,omitempty"` // fallback after refresh or transfer
	Settings      Settings       `json:"settings"`
	Configs       []RuleConfig   `json:"configs,omitempty"`
}

// FindConfig looks a routing config up by id.
func (d *Document) FindConfig(id string) *RuleConfig {
	for i := range d.Configs {
		if d.Configs[i].ID == id {
			return &d.Configs[i]
		}
	}
	return nil
}

// ActiveConfig returns the config used in "config" mode (the first one when none is chosen).
func (d *Document) ActiveConfig() *RuleConfig {
	if c := d.FindConfig(d.Settings.ActiveConfig); c != nil {
		return c
	}
	if len(d.Configs) > 0 {
		return &d.Configs[0]
	}
	return nil
}

// ResolveSelected returns the selected server, falling back to SelectedKey and then the first server.
func (d *Document) ResolveSelected() (*Subscription, *Server) {
	if d.Selected != "" {
		if s, srv := d.FindServer(d.Selected); srv != nil {
			return s, srv
		}
	}
	var firstSub *Subscription
	var first *Server
	for i := range d.Subscriptions {
		s := &d.Subscriptions[i]
		for j := range s.Servers {
			srv := &s.Servers[j]
			if d.SelectedKey != "" && srv.Key == d.SelectedKey {
				return s, srv
			}
			if first == nil {
				firstSub, first = s, srv
			}
		}
	}
	return firstSub, first
}

// ContentKey returns a stable key of a JSON value (map keys are sorted by encoding/json).
func ContentKey(v any) string {
	b, _ := json.Marshal(v)
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])[:24]
}

// ServerID combines a subscription id and a content key.
func ServerID(subscriptionID, key string) string {
	p := subscriptionID
	if len(p) > 8 {
		p = p[:8]
	}
	return p + "-" + key[:16]
}

// FindServer looks a server up by id.
func (d *Document) FindServer(id string) (*Subscription, *Server) {
	for i := range d.Subscriptions {
		s := &d.Subscriptions[i]
		for j := range s.Servers {
			if s.Servers[j].ID == id {
				return s, &s.Servers[j]
			}
		}
	}
	return nil, nil
}

// FindSubscription looks a subscription up by id.
func (d *Document) FindSubscription(id string) *Subscription {
	for i := range d.Subscriptions {
		if d.Subscriptions[i].ID == id {
			return &d.Subscriptions[i]
		}
	}
	return nil
}

// IsFavorite reports whether a server key is a favorite.
func (d *Document) IsFavorite(key string) bool {
	for _, k := range d.Favorites {
		if k == key {
			return true
		}
	}
	return false
}
