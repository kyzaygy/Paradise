package transfer

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"net/url"
	"strings"

	"github.com/kyzaygy/paradise/core/internal/apperr"
)

// SVOI1 format: "SVOI1." + base64url(gzip(JSON)), JSON version 1.
// SVOI decoders are strict (unknown fields are rejected), so the writer only
// emits the base field set: version, name, identity, sources[name,url,configs[name,data]].
// The reader is lenient and accepts both known dialects (with and without
// responseFormat/sourceProfileCore).

type svoiProfile struct {
	Version  int          `json:"version"`
	Name     string       `json:"name"`
	Identity svoiIdentity `json:"identity"`
	Sources  []svoiSource `json:"sources"`
}

type svoiIdentity struct {
	HWID      string `json:"hwid"`
	OS        string `json:"os"`
	Model     string `json:"model"`
	Locale    string `json:"locale"`
	UserAgent string `json:"userAgent"`
}

type svoiSource struct {
	Name    string       `json:"name"`
	URL     string       `json:"url,omitempty"`
	Configs []svoiConfig `json:"configs"`
}

type svoiConfig struct {
	Name string          `json:"name"`
	Data json.RawMessage `json:"data"`
}

// svoiSourceIn is the lenient reader shape.
type svoiSourceIn struct {
	Name           string `json:"name"`
	URL            string `json:"url"`
	ResponseFormat string `json:"responseFormat"`
	Configs        []struct {
		SourceProfileCore string          `json:"sourceProfileCore"`
		Name              string          `json:"name"`
		Data              json.RawMessage `json:"data"`
	} `json:"configs"`
}

type svoiProfileIn struct {
	Version  int            `json:"version"`
	Name     string         `json:"name"`
	Identity svoiIdentity   `json:"identity"`
	Sources  []svoiSourceIn `json:"sources"`
}

// DecodeSVOI1 decodes a SVOI1 code. Skipped counts entries that need cores other than Xray.
func DecodeSVOI1(code string) (Payload, int, error) {
	if len(code) > MaxCodeChars {
		return Payload{}, 0, apperr.New(apperr.TooLarge, "code")
	}
	data := strings.TrimPrefix(code, SVOI1Prefix)
	var blob []byte
	var err error
	for _, enc := range []*base64.Encoding{base64.RawURLEncoding, base64.URLEncoding, base64.RawStdEncoding, base64.StdEncoding} {
		if blob, err = enc.DecodeString(data); err == nil {
			break
		}
	}
	if err != nil {
		return Payload{}, 0, apperr.New(apperr.TransferCorrupted, "base64")
	}
	raw, err := gunzip(blob)
	if err != nil {
		return Payload{}, 0, asCorrupted(err)
	}
	var in svoiProfileIn
	if err := json.Unmarshal(raw, &in); err != nil {
		return Payload{}, 0, apperr.New(apperr.TransferCorrupted, "json")
	}
	if in.Version != 1 {
		return Payload{}, 0, apperr.New(apperr.TransferVersion, "")
	}
	p := Payload{V: PayloadVersion, App: "SVOI", Name: in.Name}
	if in.Identity.HWID != "" {
		p.Identity = &Identity{HWID: in.Identity.HWID}
	}
	skipped := 0
	for _, s := range in.Sources {
		src := Source{Name: s.Name, URL: s.URL}
		for _, c := range s.Configs {
			if c.SourceProfileCore != "" {
				skipped++
				continue
			}
			var probe map[string]any
			if json.Unmarshal(c.Data, &probe) != nil || probe == nil {
				return Payload{}, 0, apperr.New(apperr.TransferCorrupted, "config")
			}
			if _, full := probe["outbounds"]; full {
				src.Servers = append(src.Servers, Config{Name: c.Name, Profile: c.Data})
			} else {
				src.Servers = append(src.Servers, Config{Name: c.Name, Outbound: c.Data})
			}
		}
		if src.URL == "" && len(src.Servers) == 0 {
			continue
		}
		p.Subscriptions = append(p.Subscriptions, src)
	}
	if err := validate(&p); err != nil {
		return Payload{}, skipped, err
	}
	return p, skipped, nil
}

// SVOIDevice describes identity fields written into SVOI1 codes.
type SVOIDevice struct {
	Model     string
	Locale    string
	UserAgent string
}

func svoiText(s string, n int, fallback string) string {
	s = truncate(s, n)
	if s == "" {
		return fallback
	}
	return s
}

func asciiText(s string, fallback string) string {
	b := strings.Builder{}
	for _, r := range s {
		if r >= 32 && r <= 126 {
			b.WriteRune(r)
		}
	}
	out := truncate(b.String(), 180)
	if out == "" {
		return fallback
	}
	return out
}

func randomHWID() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// svoiURL mirrors SVOI's subscription URL check: https, port 443, no credentials, no fragment.
func svoiURL(raw string) bool {
	u, err := url.Parse(raw)
	return err == nil && u.Scheme == "https" && u.Hostname() != "" && u.User == nil && u.Fragment == "" && (u.Port() == "" || u.Port() == "443")
}

// EncodeSVOI1 writes the base SVOI1 dialect. Skipped counts sources SVOI would reject.
func EncodeSVOI1(p Payload, d SVOIDevice) (string, int, error) {
	hwid := randomHWID()
	if p.Identity != nil && p.Identity.HWID != "" {
		hwid = p.Identity.HWID
	}
	out := svoiProfile{
		Version: 1,
		Name:    svoiText(p.Name, 60, "Paradise"),
		Identity: svoiIdentity{
			HWID:      asciiText(hwid, randomHWID()),
			OS:        "iOS",
			Model:     asciiText(d.Model, "iPhone"),
			Locale:    asciiText(d.Locale, "en-US"),
			UserAgent: asciiText(d.UserAgent, "Paradise"),
		},
		Sources: []svoiSource{},
	}
	skipped := 0
	for i, s := range p.Subscriptions {
		name := svoiText(s.Name, 60, "Source "+itoa(i+1))
		if s.URL != "" {
			if !svoiURL(s.URL) {
				skipped++
				continue
			}
			out.Sources = append(out.Sources, svoiSource{Name: name, URL: s.URL, Configs: []svoiConfig{}})
			continue
		}
		src := svoiSource{Name: name, Configs: []svoiConfig{}}
		for j, c := range s.Servers {
			data := c.Outbound
			if len(c.Profile) > 0 {
				data = c.Profile
			}
			src.Configs = append(src.Configs, svoiConfig{Name: svoiText(c.Name, 512, "Server "+itoa(j+1)), Data: data})
		}
		if len(src.Configs) == 0 {
			continue
		}
		out.Sources = append(out.Sources, src)
	}
	if len(out.Sources) == 0 {
		return "", skipped, apperr.New(apperr.TransferEmpty, "")
	}
	raw, err := json.Marshal(out)
	if err != nil {
		return "", skipped, apperr.New(apperr.Internal, "marshal")
	}
	if len(raw) > MaxPlainBytes {
		return "", skipped, apperr.New(apperr.TooLarge, "payload")
	}
	body, err := gz(raw)
	if err != nil {
		return "", skipped, apperr.New(apperr.Internal, "gzip")
	}
	return SVOI1Prefix + base64.RawURLEncoding.EncodeToString(body), skipped, nil
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b [20]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	return string(b[i:])
}
