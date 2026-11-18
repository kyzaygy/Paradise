package place

import (
	"regexp"
	"strconv"
	"strings"
	"unicode"
)

var bandwidthRe = regexp.MustCompile(`(?i)(\d+(?:[.,]\d+)?)\s*(gbps|gbit/s|gbit|gb/s|гбит/с|гбит|mbps|mbit/s|mbit|mb/s|мбит/с|мбит)`)
var shortGRe = regexp.MustCompile(`(?i)(?:^|[^\w.])(1|2|10|20|25|40|100)\s?g(?:$|[^\w])`)

// Bandwidth extracts a link speed published in a server name or description ("10 Gbps", "NL 10G").
func Bandwidth(text string) string {
	if m := bandwidthRe.FindStringSubmatch(text); m != nil {
		n := strings.Replace(m[1], ",", ".", 1)
		unit := "Gbps"
		if u := strings.ToLower(m[2]); strings.HasPrefix(u, "m") || strings.HasPrefix(u, "м") {
			unit = "Mbps"
		}
		if f, err := strconv.ParseFloat(n, 64); err == nil && f > 0 && f < 100000 {
			return strconv.FormatFloat(f, 'f', -1, 64) + " " + unit
		}
	}
	if m := shortGRe.FindStringSubmatch(text); m != nil {
		return m[1] + " Gbps"
	}
	return ""
}

// Remainder returns what is left of a server name after removing the flag, the country and the city,
// e.g. "🇩🇪 Germany Premium #2" → "Premium #2". Empty when nothing meaningful is left.
func Remainder(name, cc, city string) string {
	name = bandwidthRe.ReplaceAllString(name, " ")
	name = shortGRe.ReplaceAllString(name, " ")
	var b strings.Builder
	for _, r := range name {
		if isRI(r) || r == '\U0001F3F4' || (r >= 0xE0020 && r <= 0xE007F) || r == 0xFE0F {
			continue
		}
		b.WriteRune(r)
	}
	words := map[string]bool{strings.ToLower(cc): true}
	for n, code := range names {
		if code == cc {
			words[n] = true
		}
	}
	for alias, code := range upperAliases {
		if code == cc {
			words[strings.ToLower(alias)] = true
		}
	}
	cityWordsSet := map[string]bool{}
	for k, c := range cities {
		if c.code == cc {
			cityWordsSet[k] = true
		}
	}
	for k, c := range cityWords {
		if c.code == cc {
			for _, w := range strings.Fields(k) {
				cityWordsSet[w] = true
			}
		}
	}
	for _, w := range strings.Fields(normalize(city)) {
		cityWordsSet[w] = true
	}
	for phrase, code := range phrases {
		if code == cc {
			for _, w := range strings.Fields(phrase) {
				words[w] = true
			}
		}
	}
	var kept []string
	for _, tok := range strings.FieldsFunc(b.String(), func(r rune) bool {
		return unicode.IsSpace(r) || r == '|' || r == '·' || r == ',' || r == '-' || r == '_' || r == '/' || r == '(' || r == ')' || r == '[' || r == ']'
	}) {
		n := strings.TrimSpace(normalize(tok))
		if n == "" {
			if strings.TrimSpace(tok) != "" && len([]rune(tok)) <= 4 && strings.ContainsAny(tok, "0123456789#") {
				kept = append(kept, tok)
			}
			continue
		}
		all := true
		for _, w := range strings.Fields(n) {
			if !words[w] && !cityWordsSet[w] {
				all = false
			}
		}
		if all {
			continue
		}
		kept = append(kept, tok)
	}
	out := strings.TrimSpace(strings.Join(kept, " "))
	letters := 0
	for _, r := range out {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			letters++
		}
	}
	if letters < 2 {
		return ""
	}
	return out
}
