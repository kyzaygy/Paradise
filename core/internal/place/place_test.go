package place

import "testing"

func TestDetect(t *testing.T) {
	cases := []struct{ name, addr, cc, city string }{
		{"🇳🇱 Netherlands", "1.2.3.4", "NL", ""},
		{"🇩🇪 Франкфурт #2", "", "DE", "Frankfurt"},
		{"NL-Amsterdam VLESS", "", "NL", "Amsterdam"},
		{"[US] New York 1", "", "US", "New York"},
		{"Нью-Йорк", "", "US", "New York"},
		{"Финляндия · Reality", "", "FI", ""},
		{"Server 1", "nl3.example.com", "NL", ""},
		{"Server 2", "it-fra.example.com", "", ""},
		{"Server 3", "it2.example.com", "IT", ""},
		{"NO ADS fast", "", "", ""},
		{"Hong Kong premium", "", "HK", "Hong Kong"},
		{"Санкт-Петербург", "", "RU", "Saint Petersburg"},
		{"🇬🇧 UK", "", "GB", ""},
		{"UK London", "", "GB", "London"},
		{"vless-reality", "1.2.3.4", "", ""},
		{"Стамбул", "", "TR", "Istanbul"},
	}
	for _, c := range cases {
		p := Detect(c.name, c.addr)
		if p.Code != c.cc || p.City != c.city {
			t.Errorf("%q %q: got %+v, want %s %s", c.name, c.addr, p, c.cc, c.city)
		}
	}
	if c, ok := Info("nl"); !ok || c.Region != Europe || c.Lat < 50 {
		t.Fatalf("info: %+v", c)
	}
}
