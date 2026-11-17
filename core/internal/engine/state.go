package engine

import (
	"time"

	"github.com/kyzaygy/paradise/core/internal/model"
	"github.com/kyzaygy/paradise/core/internal/sub"
)

// PublicSubscription is what the UI sees (no URL, only host).
type PublicSubscription struct {
	ID        string      `json:"id"`
	Name      string      `json:"name"`
	Host      string      `json:"host,omitempty"`
	Remote    bool        `json:"remote"`
	Count     int         `json:"count"`
	Meta      *model.Meta `json:"meta,omitempty"`
	UpdatedAt *time.Time  `json:"updatedAt,omitempty"`
	LastError string      `json:"lastError,omitempty"`
	Warnings  int         `json:"warnings,omitempty"`
}

// PublicServer is what the UI sees (no credentials).
type PublicServer struct {
	ID             string `json:"id"`
	Key            string `json:"key"`
	SubscriptionID string `json:"subscriptionId"`
	Name           string `json:"name"`
	Protocol       string `json:"protocol"`
	Address        string `json:"address"`
	Port           int    `json:"port"`
	Network        string `json:"network"`
	Security       string `json:"security"`
	Favorite       bool   `json:"favorite"`
	FullProfile    bool   `json:"fullProfile"`
}

// State is the full UI snapshot.
type State struct {
	Subscriptions []PublicSubscription `json:"subscriptions"`
	Servers       []PublicServer       `json:"servers"`
	Selected      string               `json:"selected"`
	Settings      model.Settings       `json:"settings"`
	HWID          string               `json:"hwid"`
}

func (e *Engine) stateLocked() State {
	d := e.doc
	st := State{Subscriptions: []PublicSubscription{}, Servers: []PublicServer{}, Settings: d.Settings, HWID: d.HWID}
	for _, s := range d.Subscriptions {
		ps := PublicSubscription{ID: s.ID, Name: s.Name, Remote: s.URL != "", Count: len(s.Servers), Meta: s.Meta, LastError: s.LastError, Warnings: s.Warnings}
		if s.URL != "" {
			ps.Host = sub.HostOf(s.URL)
		}
		if !s.UpdatedAt.IsZero() {
			t := s.UpdatedAt
			ps.UpdatedAt = &t
		}
		st.Subscriptions = append(st.Subscriptions, ps)
		for _, srv := range s.Servers {
			st.Servers = append(st.Servers, PublicServer{
				ID: srv.ID, Key: srv.Key, SubscriptionID: s.ID, Name: srv.Name, Protocol: srv.Protocol,
				Address: srv.Address, Port: srv.Port, Network: srv.Network, Security: srv.Security,
				Favorite: d.IsFavorite(srv.Key), FullProfile: len(srv.Profile) > 0,
			})
		}
	}
	if _, srv := d.ResolveSelected(); srv != nil {
		st.Selected = srv.ID
	}
	return st
}
