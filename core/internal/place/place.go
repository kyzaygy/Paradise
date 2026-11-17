// Package place guesses the country of a server from its name and address.
//
// Providers put the location into the server name: a flag emoji, an ISO code,
// a country or a city name in English or Russian. The host name prefix
// (nl1.example.com) is used as a last resort. Nothing is looked up online.
package place

import (
	"net"
	"strings"
	"unicode"
)

// Region codes used by the UI filters.
const (
	Europe   = "europe"
	Asia     = "asia"
	Americas = "americas"
	Africa   = "africa"
	Oceania  = "oceania"
)

// Country is static data about a country.
type Country struct {
	Code   string  `json:"cc"`
	Region string  `json:"region"`
	Lat    float64 `json:"lat"`
	Lon    float64 `json:"lon"`
}

// Place is a detection result.
type Place struct {
	Code string `json:"cc,omitempty"`
	City string `json:"city,omitempty"`
}

// countries: code|region|lat|lon|names (lowercase, comma separated)
const countryTable = `
NL|europe|52.2|5.3|netherlands,holland,нидерланды,голландия,нидерландах
DE|europe|51.2|10.4|germany,deutschland,германия,германии
FI|europe|62.0|25.7|finland,финляндия,финляндии,суоми
SE|europe|60.1|18.6|sweden,швеция,швеции
NO|europe|60.5|8.5|norway,норвегия,норвегии
DK|europe|56.0|10.0|denmark,дания,дании
FR|europe|46.6|2.2|france,франция,франции
GB|europe|54.0|-2.0|uk,britain,england,великобритания,англия,британия,англии
IE|europe|53.4|-8.2|ireland,ирландия,ирландии
BE|europe|50.5|4.5|belgium,бельгия,бельгии
LU|europe|49.8|6.1|luxembourg,люксембург
CH|europe|46.8|8.2|switzerland,швейцария,швейцарии
AT|europe|47.5|14.6|austria,австрия,австрии
IT|europe|41.9|12.6|italy,италия,италии
ES|europe|40.5|-3.7|spain,испания,испании
PT|europe|39.4|-8.2|portugal,португалия,португалии
PL|europe|51.9|19.1|poland,польша,польши,польше
CZ|europe|49.8|15.5|czechia,czech,чехия,чехии
SK|europe|48.7|19.7|slovakia,словакия,словакии
HU|europe|47.2|19.5|hungary,венгрия,венгрии
RO|europe|45.9|25.0|romania,румыния,румынии
BG|europe|42.7|25.5|bulgaria,болгария,болгарии
MD|europe|47.4|28.4|moldova,молдова,молдавия
UA|europe|48.4|31.2|ukraine,украина,украины
BY|europe|53.7|28.0|belarus,беларусь,белоруссия
RU|europe|55.8|37.6|russia,россия,россии,рф
EE|europe|58.6|25.0|estonia,эстония,эстонии
LV|europe|56.9|24.6|latvia,латвия,латвии
LT|europe|55.2|23.9|lithuania,литва,литвы,литве
GR|europe|39.1|21.8|greece,греция,греции
CY|europe|35.1|33.4|cyprus,кипр
MT|europe|35.9|14.4|malta,мальта
RS|europe|44.0|21.0|serbia,сербия,сербии
HR|europe|45.1|15.2|croatia,хорватия,хорватии
SI|europe|46.2|14.9|slovenia,словения,словении
BA|europe|43.9|17.7|bosnia,босния
ME|europe|42.7|19.4|montenegro,черногория,черногории
MK|europe|41.6|21.7|macedonia,македония
AL|europe|41.2|20.2|albania,албания
IS|europe|64.9|-19.0|iceland,исландия,исландии
TR|europe|39.0|35.2|turkey,turkiye,турция,турции
GE|asia|42.3|43.4|georgia,грузия,грузии
AM|asia|40.1|45.0|armenia,армения,армении
AZ|asia|40.1|47.6|azerbaijan,азербайджан
KZ|asia|48.0|66.9|kazakhstan,казахстан
KG|asia|41.2|74.8|kyrgyzstan,киргизия,кыргызстан
UZ|asia|41.4|64.6|uzbekistan,узбекистан
TJ|asia|38.9|71.3|tajikistan,таджикистан
TM|asia|38.97|59.6|turkmenistan,туркменистан
MN|asia|46.9|103.8|mongolia,монголия
IL|asia|31.0|34.9|israel,израиль
AE|asia|23.4|53.8|emirates,uae,оаэ,эмираты
SA|asia|23.9|45.1|saudi,саудовская
QA|asia|25.4|51.2|qatar,катар
BH|asia|26.0|50.6|bahrain,бахрейн
IR|asia|32.4|53.7|iran,иран
IN|asia|20.6|79.0|india,индия,индии
PK|asia|30.4|69.3|pakistan,пакистан
BD|asia|23.7|90.4|bangladesh,бангладеш
CN|asia|35.9|104.2|china,китай,китае
HK|asia|22.3|114.2|hongkong,гонконг
TW|asia|23.7|121.0|taiwan,тайвань
MO|asia|22.2|113.5|macau,macao,макао
JP|asia|36.2|138.3|japan,япония,японии
KR|asia|35.9|127.8|korea,корея,кореи
SG|asia|1.35|103.8|singapore,сингапур
MY|asia|4.2|101.9|malaysia,малайзия
TH|asia|15.9|100.9|thailand,таиланд,тайланд
VN|asia|14.1|108.3|vietnam,вьетнам
ID|asia|-0.8|113.9|indonesia,индонезия
PH|asia|12.9|121.8|philippines,филиппины
KH|asia|12.6|104.9|cambodia,камбоджа
LK|asia|7.9|80.8|lanka,шри-ланка
NP|asia|28.4|84.1|nepal,непал
US|americas|39.8|-98.6|usa,america,сша,америка,штаты
CA|americas|56.1|-106.3|canada,канада,канаде
MX|americas|23.6|-102.6|mexico,мексика
BR|americas|-14.2|-51.9|brazil,brasil,бразилия
AR|americas|-38.4|-63.6|argentina,аргентина
CL|americas|-35.7|-71.5|chile,чили
CO|americas|4.6|-74.3|colombia,колумбия
PE|americas|-9.2|-75.0|peru,перу
PA|americas|8.5|-80.8|panama,панама
CR|americas|9.7|-83.8|rica,коста-рика
ZA|africa|-30.6|22.9|safrica,юар
EG|africa|26.8|30.8|egypt,египет
MA|africa|31.8|-7.1|morocco,марокко
NG|africa|9.1|8.7|nigeria,нигерия
KE|africa|-0.02|37.9|kenya,кения
AU|oceania|-25.3|133.8|australia,австралия,австралии
NZ|oceania|-40.9|174.9|zealand,зеландия
`

// cities: name|code|display (multi-word names use a single space)
const cityTable = `
amsterdam|NL|Amsterdam
амстердам|NL|Amsterdam
rotterdam|NL|Rotterdam
frankfurt|DE|Frankfurt
франкфурт|DE|Frankfurt
berlin|DE|Berlin
берлин|DE|Berlin
munich|DE|Munich
мюнхен|DE|Munich
nuremberg|DE|Nuremberg
falkenstein|DE|Falkenstein
dusseldorf|DE|Düsseldorf
helsinki|FI|Helsinki
хельсинки|FI|Helsinki
stockholm|SE|Stockholm
стокгольм|SE|Stockholm
oslo|NO|Oslo
copenhagen|DK|Copenhagen
paris|FR|Paris
париж|FR|Paris
marseille|FR|Marseille
london|GB|London
лондон|GB|London
manchester|GB|Manchester
dublin|IE|Dublin
brussels|BE|Brussels
zurich|CH|Zurich
цюрих|CH|Zurich
vienna|AT|Vienna
вена|AT|Vienna
milan|IT|Milan
милан|IT|Milan
rome|IT|Rome
madrid|ES|Madrid
мадрид|ES|Madrid
lisbon|PT|Lisbon
warsaw|PL|Warsaw
варшава|PL|Warsaw
prague|CZ|Prague
прага|CZ|Prague
budapest|HU|Budapest
bucharest|RO|Bucharest
sofia|BG|Sofia
chisinau|MD|Chișinău
kyiv|UA|Kyiv
kiev|UA|Kyiv
киев|UA|Kyiv
minsk|BY|Minsk
минск|BY|Minsk
moscow|RU|Moscow
москва|RU|Moscow
saint petersburg|RU|Saint Petersburg
st petersburg|RU|Saint Petersburg
санкт петербург|RU|Saint Petersburg
спб|RU|Saint Petersburg
novosibirsk|RU|Novosibirsk
новосибирск|RU|Novosibirsk
ekaterinburg|RU|Yekaterinburg
екатеринбург|RU|Yekaterinburg
tallinn|EE|Tallinn
таллин|EE|Tallinn
таллинн|EE|Tallinn
riga|LV|Riga
рига|LV|Riga
vilnius|LT|Vilnius
вильнюс|LT|Vilnius
athens|GR|Athens
belgrade|RS|Belgrade
белград|RS|Belgrade
istanbul|TR|Istanbul
стамбул|TR|Istanbul
ankara|TR|Ankara
tbilisi|GE|Tbilisi
тбилиси|GE|Tbilisi
yerevan|AM|Yerevan
ереван|AM|Yerevan
baku|AZ|Baku
баку|AZ|Baku
almaty|KZ|Almaty
алматы|KZ|Almaty
astana|KZ|Astana
астана|KZ|Astana
bishkek|KG|Bishkek
tashkent|UZ|Tashkent
ташкент|UZ|Tashkent
tel aviv|IL|Tel Aviv
dubai|AE|Dubai
дубай|AE|Dubai
mumbai|IN|Mumbai
hong kong|HK|Hong Kong
tokyo|JP|Tokyo
токио|JP|Tokyo
osaka|JP|Osaka
seoul|KR|Seoul
сеул|KR|Seoul
singapore|SG|Singapore
bangkok|TH|Bangkok
new york|US|New York
нью йорк|US|New York
los angeles|US|Los Angeles
лос анджелес|US|Los Angeles
san francisco|US|San Francisco
san jose|US|San Jose
seattle|US|Seattle
chicago|US|Chicago
dallas|US|Dallas
miami|US|Miami
atlanta|US|Atlanta
ashburn|US|Ashburn
toronto|CA|Toronto
торонто|CA|Toronto
montreal|CA|Montreal
vancouver|CA|Vancouver
sao paulo|BR|São Paulo
buenos aires|AR|Buenos Aires
sydney|AU|Sydney
сидней|AU|Sydney
melbourne|AU|Melbourne
johannesburg|ZA|Johannesburg
`

// multi-word country names
var phrases = map[string]string{
	"united states": "US", "united kingdom": "GB", "great britain": "GB", "hong kong": "HK",
	"south korea": "KR", "new zealand": "NZ", "south africa": "ZA", "saudi arabia": "SA",
	"united arab emirates": "AE", "czech republic": "CZ", "sri lanka": "LK", "costa rica": "CR",
	"соединенные штаты": "US", "соединённые штаты": "US", "южная корея": "KR", "новая зеландия": "NZ",
	"саудовская аравия": "SA", "шри ланка": "LK",
}

// uppercase aliases that are not ISO codes
var upperAliases = map[string]string{"UK": "GB", "USA": "US", "UAE": "AE", "RUS": "RU", "GER": "DE", "NLD": "NL", "FIN": "FI"}

// two-letter codes that are also common words: in host names they need a digit after them
var riskyCodes = map[string]bool{"IN": true, "IS": true, "AS": true, "BE": true, "NO": true, "ME": true, "MY": true, "AM": true, "AT": true, "TO": true, "DO": true, "SO": true, "GO": true, "ID": true, "IT": true, "PE": true, "PA": true, "CA": true, "AL": true, "MA": true}

// uppercase words that look like codes too often (NO ADS, IS, AT, ID 5)
var riskyUpper = map[string]bool{"IN": true, "IS": true, "AS": true, "BE": true, "NO": true, "ME": true, "MY": true, "AM": true, "AT": true, "TO": true, "DO": true, "SO": true, "GO": true, "ID": true, "PE": true, "PA": true, "AL": true, "MA": true}

var (
	countries = map[string]Country{}
	names     = map[string]string{}
	cities    = map[string]city{}
	cityWords = map[string]city{} // multi-word city names
)

type city struct{ code, display string }

func init() {
	for _, line := range strings.Split(strings.TrimSpace(countryTable), "\n") {
		f := strings.Split(line, "|")
		if len(f) != 5 {
			continue
		}
		c := Country{Code: f[0], Region: f[1], Lat: atof(f[2]), Lon: atof(f[3])}
		countries[c.Code] = c
		for _, n := range strings.Split(f[4], ",") {
			names[n] = c.Code
		}
	}
	for _, line := range strings.Split(strings.TrimSpace(cityTable), "\n") {
		f := strings.Split(line, "|")
		if len(f) != 3 {
			continue
		}
		c := city{code: f[1], display: f[2]}
		if strings.Contains(f[0], " ") {
			cityWords[f[0]] = c
		} else {
			cities[f[0]] = c
		}
	}
}

func atof(s string) float64 {
	var v, frac float64
	neg := false
	div := 1.0
	dot := false
	for _, r := range s {
		switch {
		case r == '-':
			neg = true
		case r == '.':
			dot = true
		case r >= '0' && r <= '9':
			if dot {
				div *= 10
				frac = frac*10 + float64(r-'0')
			} else {
				v = v*10 + float64(r-'0')
			}
		}
	}
	v += frac / div
	if neg {
		v = -v
	}
	return v
}

// Info returns static data for a country code.
func Info(code string) (Country, bool) {
	c, ok := countries[strings.ToUpper(code)]
	return c, ok
}

// Detect guesses the location of a server.
func Detect(name, address string) Place {
	if cc := flagCode(name); cc != "" {
		return Place{Code: cc, City: cityIn(name, cc)}
	}
	if cc := upperToken(name); cc != "" {
		return Place{Code: cc, City: cityIn(name, cc)}
	}
	norm := " " + normalize(name) + " "
	for phrase, cc := range phrases {
		if strings.Contains(norm, " "+phrase+" ") {
			return Place{Code: cc, City: cityIn(name, cc)}
		}
	}
	for phrase, c := range cityWords {
		if strings.Contains(norm, " "+phrase+" ") {
			return Place{Code: c.code, City: c.display}
		}
	}
	for _, tok := range strings.Fields(norm) {
		if c, ok := cities[tok]; ok {
			return Place{Code: c.code, City: c.display}
		}
	}
	for _, tok := range strings.Fields(norm) {
		if cc, ok := names[tok]; ok {
			return Place{Code: cc}
		}
	}
	if cc := hostCode(address); cc != "" {
		return Place{Code: cc}
	}
	return Place{}
}

func cityIn(name, cc string) string {
	norm := " " + normalize(name) + " "
	for phrase, c := range cityWords {
		if c.code == cc && strings.Contains(norm, " "+phrase+" ") {
			return c.display
		}
	}
	for _, tok := range strings.Fields(norm) {
		if c, ok := cities[tok]; ok && c.code == cc {
			return c.display
		}
	}
	return ""
}

// normalize lowercases and replaces everything except letters with spaces.
func normalize(s string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(s) {
		switch {
		case r == 'ё':
			b.WriteRune('е')
		case unicode.IsLetter(r):
			b.WriteRune(r)
		default:
			b.WriteRune(' ')
		}
	}
	return b.String()
}

// flagCode reads the first regional-indicator pair (🇳🇱 → NL).
func flagCode(s string) string {
	rs := []rune(s)
	for i := 0; i+1 < len(rs); i++ {
		a, b := rs[i], rs[i+1]
		if isRI(a) && isRI(b) {
			code := string([]rune{'A' + (a - 0x1F1E6), 'A' + (b - 0x1F1E6)})
			if code == "UK" {
				code = "GB"
			}
			if _, ok := countries[code]; ok {
				return code
			}
			if code != "EU" && code != "UN" {
				return code
			}
			i++
		}
	}
	if strings.Contains(s, "\U0001F3F4\U000E0067\U000E0062") { // 🏴 England / Scotland / Wales tag sequences
		return "GB"
	}
	return ""
}

func isRI(r rune) bool { return r >= 0x1F1E6 && r <= 0x1F1FF }

// upperToken finds ISO codes written in capitals as separate tokens (NL, [DE], US-2).
func upperToken(s string) string {
	var tok []rune
	flush := func() string {
		defer func() { tok = tok[:0] }()
		t := string(tok)
		if cc, ok := upperAliases[t]; ok {
			return cc
		}
		if len(tok) == 2 && !riskyUpper[t] {
			if _, ok := countries[t]; ok {
				return t
			}
		}
		return ""
	}
	for _, r := range s {
		if r >= 'A' && r <= 'Z' || r >= 'a' && r <= 'z' {
			tok = append(tok, r)
			continue
		}
		if len(tok) > 0 {
			if isUpper(tok) {
				if cc := flush(); cc != "" {
					return cc
				}
			}
			tok = tok[:0]
		}
	}
	if len(tok) > 0 && isUpper(tok) {
		return flush()
	}
	return ""
}

func isUpper(rs []rune) bool {
	for _, r := range rs {
		if r < 'A' || r > 'Z' {
			return false
		}
	}
	return true
}

// hostCode reads "nl1.example.com" or "de-fra.example.com".
func hostCode(address string) string {
	if address == "" || net.ParseIP(address) != nil {
		return ""
	}
	label := strings.ToLower(strings.SplitN(address, ".", 2)[0])
	if len(label) < 2 {
		return ""
	}
	code := strings.ToUpper(label[:2])
	if label[0] < 'a' || label[0] > 'z' || label[1] < 'a' || label[1] > 'z' {
		return ""
	}
	if _, ok := countries[code]; !ok {
		return ""
	}
	rest := label[2:]
	switch {
	case rest == "" || rest[0] == '-':
		if riskyCodes[code] {
			return ""
		}
		return code
	case rest[0] >= '0' && rest[0] <= '9':
		return code
	}
	return ""
}
