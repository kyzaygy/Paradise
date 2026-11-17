package transfer

import (
	"bytes"
	"compress/gzip"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/kyzaygy/paradise/core/internal/apperr"
	"github.com/kyzaygy/paradise/core/internal/model"
)

func samplePayload() Payload {
	s := model.DefaultSettings()
	s.KillSwitch = true
	return Payload{
		Name: "Дом",
		Subscriptions: []Source{
			{Name: "Provider", URL: "https://sub.example.com/api/sub/TOKEN123"},
			{Name: "Local", Servers: []Config{{Name: "NL", Outbound: json.RawMessage(`{"protocol":"trojan","tag":"proxy","settings":{"servers":[{"address":"t.example.com","port":443,"password":"pw"}]}}`)}}},
		},
		Favorites: []string{"abc"},
		Settings:  &s,
	}
}

func code(t *testing.T, err error) string {
	t.Helper()
	return apperr.From(err).Code
}

func TestPD1PlainRoundtrip(t *testing.T) {
	c, err := EncodePD1(samplePayload(), EncodeOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(c, "PD1.") {
		t.Fatal(c)
	}
	d, err := Decode(LinkPrefix+c, "", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	p := d.Payload
	if p.Name != "Дом" || len(p.Subscriptions) != 2 || p.Subscriptions[0].URL == "" || !p.Settings.KillSwitch || p.Favorites[0] != "abc" {
		t.Fatalf("payload %+v", p)
	}
	if d.Envelope.Encrypted || d.Envelope.Format != FormatPD1 {
		t.Fatalf("envelope %+v", d.Envelope)
	}
}

func TestPD1EncryptedFlow(t *testing.T) {
	exp := time.Now().Add(time.Hour).Unix()
	c, err := EncodePD1(samplePayload(), EncodeOptions{Password: "correct horse", ExpiresAt: exp})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(c, "TOKEN123") {
		t.Fatal("secret leaked")
	}
	env, err := Inspect(c)
	if err != nil || !env.Encrypted || env.ExpiresAt != exp {
		t.Fatalf("inspect %+v %v", env, err)
	}
	if _, err := Decode(c, "", time.Now()); code(t, err) != apperr.TransferPassword {
		t.Fatalf("want password required, got %v", err)
	}
	if _, err := Decode(c, "wrong", time.Now()); code(t, err) != apperr.TransferWrongPass {
		t.Fatalf("want wrong password, got %v", err)
	}
	d, err := Decode(c, "correct horse", time.Now())
	if err != nil || d.Payload.Subscriptions[0].URL != "https://sub.example.com/api/sub/TOKEN123" {
		t.Fatalf("decode %v", err)
	}
	if _, err := Decode(c, "correct horse", time.Now().Add(2*time.Hour)); code(t, err) != apperr.TransferExpired {
		t.Fatalf("want expired, got %v", err)
	}
}

func TestPD1TamperedHeaderFails(t *testing.T) {
	c, _ := EncodePD1(samplePayload(), EncodeOptions{Password: "pw", ExpiresAt: time.Now().Add(time.Hour).Unix()})
	blob, _ := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(c, PD1Prefix))
	blob[9] ^= 0x7f // move expiry
	tampered := PD1Prefix + base64.RawURLEncoding.EncodeToString(blob)
	if _, err := Decode(tampered, "pw", time.Now()); code(t, err) != apperr.TransferWrongPass && code(t, err) != apperr.TransferExpired {
		t.Fatalf("tampering must fail, got %v", err)
	}
}

func TestPD1Corruption(t *testing.T) {
	c, _ := EncodePD1(samplePayload(), EncodeOptions{})
	for _, bad := range []string{"PD1.", "PD1.!!!!", c[:len(c)-10], "PD1." + base64.RawURLEncoding.EncodeToString([]byte{9, 2, 0, 0, 0, 0, 0, 0, 0, 0, 1})} {
		_, err := Decode(bad, "", time.Now())
		if err == nil {
			t.Fatalf("expected error for %q", bad)
		}
		got := code(t, err)
		if got != apperr.TransferCorrupted && got != apperr.TransferVersion {
			t.Fatalf("unexpected code %s", got)
		}
	}
}

func TestPD1FutureVersionAndCrit(t *testing.T) {
	for _, raw := range []string{`{"v":2,"subscriptions":[{"url":"https://a.b/c"}]}`, `{"v":1,"crit":["routing-v2"],"subscriptions":[{"url":"https://a.b/c"}]}`} {
		body, _ := gz([]byte(raw))
		header := []byte{1, flagGzip, 0, 0, 0, 0, 0, 0, 0, 0}
		c := PD1Prefix + base64.RawURLEncoding.EncodeToString(append(header, body...))
		if _, err := Decode(c, "", time.Now()); code(t, err) != apperr.TransferVersion {
			t.Fatalf("want version error for %s, got %v", raw, err)
		}
	}
}

func TestPD1UnknownFieldsIgnored(t *testing.T) {
	body, _ := gz([]byte(`{"v":1,"futureField":{"x":1},"subscriptions":[{"url":"https://a.b/c","extra":true}]}`))
	header := []byte{1, flagGzip, 0, 0, 0, 0, 0, 0, 0, 0}
	c := PD1Prefix + base64.RawURLEncoding.EncodeToString(append(header, body...))
	if _, err := Decode(c, "", time.Now()); err != nil {
		t.Fatal(err)
	}
}

func TestPD1Limits(t *testing.T) {
	p := Payload{}
	if _, err := EncodePD1(p, EncodeOptions{}); err != nil {
		t.Fatal(err)
	}
	c, _ := EncodePD1(p, EncodeOptions{})
	if _, err := Decode(c, "", time.Now()); code(t, err) != apperr.TransferEmpty {
		t.Fatalf("empty must fail: %v", err)
	}
	big := Payload{}
	for i := 0; i < MaxSources+1; i++ {
		big.Subscriptions = append(big.Subscriptions, Source{URL: "https://a.b/c"})
	}
	c, _ = EncodePD1(big, EncodeOptions{})
	if _, err := Decode(c, "", time.Now()); code(t, err) != apperr.TooLarge {
		t.Fatalf("too many sources must fail: %v", err)
	}
}

func TestExtractCode(t *testing.T) {
	for in, want := range map[string]string{
		"  PD1.abc \n":                 "PD1.abc",
		"paradise://import#PD1.xyz":    "PD1.xyz",
		"paradise://import?code=PD1.q": "PD1.q",
		"Мой код: SVOI1.zzz":           "SVOI1.zzz",
		"PD1.ab\ncd":                   "PD1.abcd",
	} {
		if got := ExtractCode(in); got != want {
			t.Fatalf("%q: got %q want %q", in, got, want)
		}
	}
	if IsCode("https://example.com") || !IsCode("paradise://import#PD1.x") {
		t.Fatal("IsCode")
	}
}

// --- SVOI1 compatibility ---

// Replica of SVOI's strict decoder (backend/transfer.go, MIT, SVOI contributors):
// DisallowUnknownFields + validText/validIdentity/subscriptionURL rules.
type svoiPortable struct {
	Version  int `json:"version"`
	Name     string
	Identity struct {
		HWID      string `json:"hwid"`
		OS        string `json:"os"`
		Model     string `json:"model"`
		Locale    string `json:"locale"`
		UserAgent string `json:"userAgent"`
	} `json:"identity"`
	Sources []struct {
		Name      string    `json:"name"`
		URL       string    `json:"url,omitempty"`
		FetchedAt time.Time `json:"fetchedAt,omitempty"`
		Configs   []struct {
			Name string          `json:"name"`
			Data json.RawMessage `json:"data"`
		} `json:"configs"`
	} `json:"sources"`
}

func svoiValidText(s string, max int) bool {
	return strings.TrimSpace(s) != "" && len([]rune(s)) <= max && !strings.ContainsAny(s, "\r\n\x00")
}

func strictSVOIDecode(t *testing.T, c string) svoiPortable {
	t.Helper()
	compressed, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(c, "SVOI1."))
	if err != nil {
		t.Fatalf("SVOI base64: %v", err)
	}
	r, err := gzip.NewReader(bytes.NewReader(compressed))
	if err != nil {
		t.Fatal(err)
	}
	b, _ := io.ReadAll(r)
	var p svoiPortable
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&p); err != nil {
		t.Fatalf("SVOI strict decode rejected our code: %v\n%s", err, b)
	}
	if p.Version != 1 || !svoiValidText(p.Name, 60) {
		t.Fatalf("SVOI would reject name/version: %+v", p)
	}
	for _, s := range []string{p.Identity.HWID, p.Identity.OS, p.Identity.Model, p.Identity.Locale, p.Identity.UserAgent} {
		if !svoiValidText(s, 180) {
			t.Fatalf("SVOI would reject identity field %q", s)
		}
		for _, r := range s {
			if r < 32 || r > 126 {
				t.Fatalf("non-ASCII identity %q", s)
			}
		}
	}
	for _, s := range p.Sources {
		if !svoiValidText(s.Name, 60) {
			t.Fatalf("SVOI would reject source name %q", s.Name)
		}
		if s.URL != "" {
			u, err := url.Parse(s.URL)
			if err != nil || u.Scheme != "https" || u.Fragment != "" || (u.Port() != "" && u.Port() != "443") {
				t.Fatalf("SVOI would reject url %q", s.URL)
			}
		}
	}
	return p
}

func TestSVOI1WriterIsAcceptedByStrictSVOI(t *testing.T) {
	p := samplePayload()
	p.Name = strings.Repeat("Очень длинное имя ", 10)
	p.Subscriptions = append(p.Subscriptions, Source{Name: "Bad port", URL: "https://x.example.com:8443/sub"}, Source{Name: "", URL: "https://y.example.com/s"})
	c, skipped, err := EncodeSVOI1(p, SVOIDevice{Model: "iPhone15,2", Locale: "ru_RU", UserAgent: "Paradise/0.1.0 (iOS 18.0)"})
	if err != nil {
		t.Fatal(err)
	}
	if skipped != 1 {
		t.Fatalf("skipped %d", skipped)
	}
	sp := strictSVOIDecode(t, c)
	if len(sp.Sources) != 3 || sp.Sources[1].Configs[0].Name != "NL" {
		t.Fatalf("sources %+v", sp.Sources)
	}
	back, sk, err := DecodeSVOI1(c)
	if err != nil || sk != 0 || len(back.Subscriptions) != 3 {
		t.Fatalf("roundtrip %v %d", err, sk)
	}
}

func makeSVOI1(t *testing.T, raw string) string {
	t.Helper()
	b, err := gz([]byte(raw))
	if err != nil {
		t.Fatal(err)
	}
	return "SVOI1." + base64.RawURLEncoding.EncodeToString(b)
}

func TestSVOI1ReadsBothDialects(t *testing.T) {
	base := `{"version":1,"name":"Windows","identity":{"hwid":"h","os":"Windows","model":"PC","locale":"ru-RU","userAgent":"Happ/0.4.1"},"sources":[
	{"name":"Remote","url":"https://sub.example.com/s","configs":[]},
	{"name":"Local","fetchedAt":"2026-11-01T10:00:00Z","configs":[{"name":"one","data":{"protocol":"vless","settings":{"vnext":[{"address":"a.com","port":443,"users":[{"id":"u"}]}]}}}]}]}`
	newer := `{"version":1,"name":"Windows","identity":{"hwid":"h","os":"Windows","model":"PC","locale":"ru-RU","userAgent":"x"},"sources":[
	{"name":"Remote","url":"https://sub.example.com/s","responseFormat":"sing-box","configs":[]},
	{"name":"Mixed","configs":[{"name":"sb","sourceProfileCore":"sing-box","data":{"type":"vless"}},{"name":"full","data":{"outbounds":[{"protocol":"trojan","settings":{"servers":[{"address":"t.com","port":443,"password":"p"}]}}]}}]}]}`
	p, skipped, err := DecodeSVOI1(makeSVOI1(t, base))
	if err != nil || skipped != 0 || len(p.Subscriptions) != 2 || p.Identity.HWID != "h" || len(p.Subscriptions[1].Servers[0].Outbound) == 0 {
		t.Fatalf("base dialect: %v %+v", err, p)
	}
	p, skipped, err = DecodeSVOI1(makeSVOI1(t, newer))
	if err != nil || skipped != 1 || len(p.Subscriptions) != 2 || len(p.Subscriptions[1].Servers[0].Profile) == 0 {
		t.Fatalf("newer dialect: %v skipped=%d %+v", err, skipped, p)
	}
}

func TestSVOI1Errors(t *testing.T) {
	if _, _, err := DecodeSVOI1(makeSVOI1(t, `{"version":2,"sources":[]}`)); code(t, err) != apperr.TransferVersion {
		t.Fatalf("version: %v", err)
	}
	if _, _, err := DecodeSVOI1("SVOI1.@@@"); code(t, err) != apperr.TransferCorrupted {
		t.Fatalf("corrupted: %v", err)
	}
	if _, _, err := DecodeSVOI1(makeSVOI1(t, `{"version":1,"sources":[]}`)); code(t, err) != apperr.TransferEmpty {
		t.Fatalf("empty: %v", err)
	}
}
