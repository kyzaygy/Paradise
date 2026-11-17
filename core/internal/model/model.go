// Package model holds the persistent profile document.
package model

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
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
	Mode        string `json:"mode"`        // "all" | "profile"
	KillSwitch  bool   `json:"killSwitch"`  // includeAllNetworks on iOS
	AutoRefresh bool   `json:"autoRefresh"` // refresh subscriptions on launch
	SendHWID    bool   `json:"sendHwid"`    // send x-hwid and device headers
	ProbeURL    string `json:"probeUrl"`
}

// DefaultSettings returns defaults for a fresh install.
func DefaultSettings() Settings {
	return Settings{Mode: "all", AutoRefresh: true, SendHWID: true, ProbeURL: "https://www.gstatic.com/generate_204"}
}

// Normalize fixes invalid values.
func (s *Settings) Normalize() {
	if s.Mode != "all" && s.Mode != "profile" {
		s.Mode = "all"
	}
	if s.ProbeURL == "" {
		s.ProbeURL = DefaultSettings().ProbeURL
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
