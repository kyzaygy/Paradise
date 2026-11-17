package sub

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/kyzaygy/paradise/core/internal/apperr"
	"github.com/kyzaygy/paradise/core/internal/model"
)

// MaxBody is the maximum subscription response size.
const MaxBody = 4 << 20

// Device describes headers sent to subscription providers.
type Device struct {
	HWID      string
	OS        string
	OSVersion string
	Model     string
	Locale    string
	UserAgent string
	SendHWID  bool
}

// ValidateURL accepts http(s) subscription links without credentials.
func ValidateURL(raw string) (*url.URL, error) {
	raw = strings.TrimSpace(raw)
	if len(raw) > 4096 {
		return nil, apperr.New(apperr.InvalidInput, "url too long")
	}
	u, err := url.Parse(raw)
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Hostname() == "" || u.User != nil {
		return nil, apperr.New(apperr.InvalidInput, "url")
	}
	return u, nil
}

// NewClient returns an HTTP client for subscription downloads.
func NewClient() *http.Client {
	return &http.Client{
		Timeout: 25 * time.Second,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= 5 {
				return errors.New("too many redirects")
			}
			if req.URL.Scheme != "https" && req.URL.Scheme != "http" {
				return errors.New("bad redirect")
			}
			return nil
		},
	}
}

// Fetch downloads a subscription and returns the body and response headers.
func Fetch(ctx context.Context, client *http.Client, raw string, d Device) ([]byte, http.Header, error) {
	u, err := ValidateURL(raw)
	if err != nil {
		return nil, nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, nil, apperr.New(apperr.InvalidInput, "request")
	}
	req.Header.Set("Accept", "text/plain, application/json;q=0.9, */*;q=0.5")
	req.Header.Set("User-Agent", d.UserAgent)
	if d.SendHWID {
		set := func(k, v string) {
			if v != "" {
				req.Header.Set(k, v)
			}
		}
		set("x-hwid", d.HWID)
		set("x-device-os", d.OS)
		set("x-ver-os", d.OSVersion)
		set("x-device-model", d.Model)
		set("x-device-locale", d.Locale)
	}
	resp, err := client.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return nil, nil, apperr.New(apperr.Cancelled, "")
		}
		return nil, nil, apperr.New(apperr.Network, "")
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, nil, apperr.New(apperr.HTTPStatus, strconv.Itoa(resp.StatusCode))
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, MaxBody+1))
	if err != nil {
		return nil, nil, apperr.New(apperr.Network, "read")
	}
	if len(body) > MaxBody {
		return nil, nil, apperr.New(apperr.TooLarge, "body")
	}
	return body, resp.Header, nil
}

// ParseMeta extracts provider metadata from headers (response headers merged with body metadata).
func ParseMeta(h http.Header) *model.Meta {
	m := &model.Meta{
		Title:      metaText(h.Get("profile-title"), 120),
		SupportURL: publicLink(h.Get("support-url")),
		WebURL:     publicLink(h.Get("profile-web-page-url")),
		Announce:   metaText(h.Get("announce"), 2000),
	}
	for _, field := range strings.Split(h.Get("subscription-userinfo"), ";") {
		k, v, ok := strings.Cut(field, "=")
		if !ok {
			continue
		}
		n, err := strconv.ParseInt(strings.TrimSpace(v), 10, 64)
		if err != nil || n < 0 {
			continue
		}
		switch strings.ToLower(strings.TrimSpace(k)) {
		case "upload":
			m.Upload = n
		case "download":
			m.Download = n
		case "total":
			m.Total = n
		case "expire":
			m.Expire = n
		}
	}
	if n, err := strconv.Atoi(strings.TrimSpace(h.Get("profile-update-interval"))); err == nil && n > 0 && n <= 8760 {
		m.UpdateHours = n
	}
	if *m == (model.Meta{}) {
		return nil
	}
	return m
}

// MergeHeaders overlays body metadata with response headers (response wins).
func MergeHeaders(body, resp http.Header) http.Header {
	out := http.Header{}
	for k, v := range body {
		out[k] = v
	}
	for k, v := range resp {
		out[k] = v
	}
	return out
}

func metaText(raw string, limit int) string {
	raw = strings.TrimSpace(raw)
	if strings.HasPrefix(strings.ToLower(raw), "base64:") {
		if b, err := base64.StdEncoding.DecodeString(strings.TrimSpace(raw[7:])); err == nil {
			raw = string(b)
		} else if b, err := DecodeBase64(raw[7:]); err == nil {
			raw = string(b)
		}
	}
	if !utf8.ValidString(raw) {
		return ""
	}
	raw = strings.Map(func(r rune) rune {
		if r == '\n' || r == '\t' {
			return r
		}
		if r < 32 || r == 127 {
			return -1
		}
		return r
	}, raw)
	if r := []rune(raw); len(r) > limit {
		raw = string(r[:limit])
	}
	return strings.TrimSpace(raw)
}

func publicLink(raw string) string {
	raw = strings.TrimSpace(raw)
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" {
		return ""
	}
	switch u.Scheme {
	case "https", "http", "tg":
		return u.String()
	}
	return ""
}

// HostOf returns the host part of a URL for display.
func HostOf(raw string) string {
	u, err := url.Parse(raw)
	if err != nil {
		return ""
	}
	return u.Hostname()
}

// Describe returns a short human description of an error for logs (no secrets).
func Describe(err error) string { return fmt.Sprint(apperr.From(err).Code) }
