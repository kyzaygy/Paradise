// Package transfer encodes and decodes profile transfer codes.
//
// Two formats are supported:
//   - PD1: Paradise format, versioned, optional password (Argon2id + AES-256-GCM) and expiry.
//   - SVOI1: compatibility with SVOI (https://github.com/1atex/svoi), read and write.
package transfer

import (
	"encoding/json"
	"net/url"
	"strings"

	"github.com/kyzaygy/paradise/core/internal/model"
)

// PayloadVersion is the current PD1 payload version.
const PayloadVersion = 1

// Limits for untrusted transfer data.
const (
	MaxCodeChars      = 12 << 20
	MaxPlainBytes     = 8 << 20
	MaxSources        = 64
	MaxServersPerSrc  = 2000
	MaxServersTotal   = 5000
	MaxNameRunes      = 120
	QRMaxChars        = 2300
	LinkScheme        = "paradise"
	LinkPrefix        = "paradise://import#"
	PD1Prefix         = "PD1."
	SVOI1Prefix       = "SVOI1."
	supportedCritNone = ""
)

// Payload is the decoded content of a transfer code.
type Payload struct {
	V             int             `json:"v"`
	Crit          []string        `json:"crit,omitempty"` // features the reader must understand
	App           string          `json:"app,omitempty"`
	Created       int64           `json:"created,omitempty"`
	Name          string          `json:"name,omitempty"`
	Subscriptions []Source        `json:"subscriptions"`
	Favorites     []string        `json:"favorites,omitempty"`
	Selected      string          `json:"selected,omitempty"`
	Settings      *model.Settings `json:"settings,omitempty"`
	Identity      *Identity       `json:"identity,omitempty"`
	Configs       []RoutingConfig `json:"configs,omitempty"`      // optional, ignored by older readers
	ActiveConfig  string          `json:"activeConfig,omitempty"` // config name
}

// RoutingConfig is a text routing config carried with settings.
type RoutingConfig struct {
	Name string `json:"name"`
	Text string `json:"text"`
	URL  string `json:"url,omitempty"`
}

// Source is a subscription link or a set of embedded configs.
type Source struct {
	Name    string   `json:"name,omitempty"`
	URL     string   `json:"url,omitempty"`
	Servers []Config `json:"servers,omitempty"`
}

// Config is one embedded server.
type Config struct {
	Name     string          `json:"name,omitempty"`
	Outbound json.RawMessage `json:"outbound,omitempty"`
	Profile  json.RawMessage `json:"profile,omitempty"`
}

// Identity is the device identity sent to providers (x-hwid).
type Identity struct {
	HWID string `json:"hwid"`
}

// Format of a decoded code.
const (
	FormatPD1   = "pd1"
	FormatSVOI1 = "svoi1"
)

// Envelope describes a code before decryption.
type Envelope struct {
	Format    string `json:"format"`
	Encrypted bool   `json:"encrypted"`
	ExpiresAt int64  `json:"expiresAt,omitempty"`
}

// ExtractCode finds a transfer code in pasted text, a paradise:// link or a file.
func ExtractCode(text string) string {
	t := strings.TrimSpace(strings.TrimPrefix(text, "\ufeff"))
	if strings.HasPrefix(strings.ToLower(t), LinkScheme+"://") {
		if u, err := url.Parse(t); err == nil {
			if u.Fragment != "" {
				t = u.Fragment
			} else if c := u.Query().Get("code"); c != "" {
				t = c
			}
		}
	}
	t = strings.Join(strings.Fields(t), "")
	for _, p := range []string{PD1Prefix, SVOI1Prefix} {
		if i := strings.Index(t, p); i >= 0 {
			return t[i:]
		}
	}
	return t
}

// IsCode reports whether text contains a transfer code or link.
func IsCode(text string) bool {
	c := ExtractCode(text)
	return strings.HasPrefix(c, PD1Prefix) || strings.HasPrefix(c, SVOI1Prefix)
}

// Counts summarizes a payload without secrets.
type Counts struct {
	Subscriptions int `json:"subscriptions"`
	Remote        int `json:"remote"`
	Servers       int `json:"servers"`
	Favorites     int `json:"favorites"`
}

// Count summarizes a payload.
func (p *Payload) Count() Counts {
	c := Counts{Subscriptions: len(p.Subscriptions), Favorites: len(p.Favorites)}
	for _, s := range p.Subscriptions {
		if s.URL != "" {
			c.Remote++
		}
		c.Servers += len(s.Servers)
	}
	return c
}

func truncate(s string, n int) string {
	s = strings.TrimSpace(strings.Map(func(r rune) rune {
		if r < 32 || r == 127 {
			return -1
		}
		return r
	}, s))
	if r := []rune(s); len(r) > n {
		return string(r[:n])
	}
	return s
}
