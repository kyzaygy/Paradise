package engine

import (
	"time"

	"github.com/kyzaygy/paradise/core/internal/model"
	"github.com/kyzaygy/paradise/core/internal/place"
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
	Country        string `json:"cc,omitempty"`
	City           string `json:"city,omitempty"`
	Region         string `json:"region,omitempty"`
	Desc           string `json:"desc,omitempty"`
	Fragment       bool   `json:"fragment,omitempty"`
	Bandwidth      string `json:"bandwidth,omitempty"`
	Label          string `json:"label,omitempty"` // name without flag, country and city
}

// PublicCountry is a country present in the user's servers.
type PublicCountry struct {
	place.Country
	Servers int `json:"servers"`
}

// State is the full UI snapshot.
type State struct {
	Subscriptions []PublicSubscription `json:"subscriptions"`
	Servers       []PublicServer       `json:"servers"`
	Selected      string               `json:"selected"`
	Settings      model.Settings       `json:"settings"`
	HWID          string               `json:"hwid"`
	Configs       []PublicConfig       `json:"configs"`
	Countries     []PublicCountry      `json:"countries"`
}

func (e *Engine) stateLocked() State {
	d := e.doc
	st := State{Subscriptions: []PublicSubscription{}, Servers: []PublicServer{}, Settings: d.Settings, HWID: d.HWID, Configs: []PublicConfig{}, Countries: []PublicCountry{}}
	countries := map[string]int{}
	var order []string
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
			loc := e.placeOf(srv)
			ps := PublicServer{
				ID: srv.ID, Key: srv.Key, SubscriptionID: s.ID, Name: srv.Name, Protocol: srv.Protocol,
				Address: srv.Address, Port: srv.Port, Network: srv.Network, Security: srv.Security,
				Favorite: d.IsFavorite(srv.Key), FullProfile: len(srv.Profile) > 0,
				Country: loc.Code, City: loc.City, Desc: srv.Desc, Fragment: srv.Fragment != nil,
				Bandwidth: place.Bandwidth(srv.Name + " " + srv.Desc), Label: place.Remainder(srv.Name, loc.Code, loc.City),
			}
			if c, ok := place.Info(loc.Code); ok {
				ps.Region = c.Region
			}
			st.Servers = append(st.Servers, ps)
			if _, seen := countries[loc.Code]; !seen {
				order = append(order, loc.Code)
			}
			countries[loc.Code]++
		}
	}
	for _, cc := range order {
		c, ok := place.Info(cc)
		if !ok {
			c = place.Country{Code: cc}
		}
		st.Countries = append(st.Countries, PublicCountry{Country: c, Servers: countries[cc]})
	}
	for i := range d.Configs {
		st.Configs = append(st.Configs, publicConfig(d, &d.Configs[i]))
	}
	st.Selected = explicitSelection(d)
	return st
}

// explicitSelection is the server the user picked (by id, or by key after a refresh); "" when none.
func explicitSelection(d *model.Document) string {
	if d.Selected != "" {
		if _, srv := d.FindServer(d.Selected); srv != nil {
			return srv.ID
		}
	}
	if d.SelectedKey != "" {
		for _, s := range d.Subscriptions {
			for _, srv := range s.Servers {
				if srv.Key == d.SelectedKey {
					return srv.ID
				}
			}
		}
	}
	return ""
}
