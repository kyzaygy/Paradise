package rules

import (
	"errors"
	"net"
	"sort"
	"strconv"
	"strings"
)

// geoip.dat / geosite.dat are protobuf lists (v2ray/Xray "router" messages):
//
//	GeoIPList   { repeated GeoIP entry = 1 }   GeoIP   { string code = 1; repeated CIDR cidr = 2 }
//	CIDR        { bytes ip = 1; uint32 prefix = 2 }
//	GeoSiteList { repeated GeoSite entry = 1 } GeoSite { string code = 1; repeated Domain domain = 2 }
//	Domain      { Type type = 1; string value = 2; repeated Attribute attribute = 3 }
//	Attribute   { string key = 1; ... }
//
// Only the requested codes are decoded, so a 20 MB file costs little memory.

var errProto = errors.New("invalid geo data")

type reader struct {
	b []byte
	i int
}

func (r *reader) done() bool { return r.i >= len(r.b) }

func (r *reader) varint() (uint64, error) {
	var v uint64
	for shift := uint(0); shift < 64; shift += 7 {
		if r.i >= len(r.b) {
			return 0, errProto
		}
		c := r.b[r.i]
		r.i++
		v |= uint64(c&0x7f) << shift
		if c < 0x80 {
			return v, nil
		}
	}
	return 0, errProto
}

// next returns field number, wire type, and for length-delimited fields the payload.
func (r *reader) next() (int, int, []byte, uint64, error) {
	key, err := r.varint()
	if err != nil {
		return 0, 0, nil, 0, err
	}
	field, wire := int(key>>3), int(key&7)
	switch wire {
	case 0:
		v, err := r.varint()
		return field, wire, nil, v, err
	case 1:
		if r.i+8 > len(r.b) {
			return 0, 0, nil, 0, errProto
		}
		r.i += 8
		return field, wire, nil, 0, nil
	case 2:
		n, err := r.varint()
		if err != nil || n > uint64(len(r.b)-r.i) {
			return 0, 0, nil, 0, errProto
		}
		p := r.b[r.i : r.i+int(n)]
		r.i += int(n)
		return field, wire, p, 0, nil
	case 5:
		if r.i+4 > len(r.b) {
			return 0, 0, nil, 0, errProto
		}
		r.i += 4
		return field, wire, nil, 0, nil
	}
	return 0, 0, nil, 0, errProto
}

// entryCode reads the code (field 1) of a GeoIP/GeoSite entry without decoding the rest.
func entryCode(entry []byte) string {
	r := &reader{b: entry}
	for !r.done() {
		f, w, p, _, err := r.next()
		if err != nil {
			return ""
		}
		if f == 1 && w == 2 {
			return strings.ToLower(string(p))
		}
	}
	return ""
}

// eachEntry calls fn for every top-level entry (field 1) of a list.
func eachEntry(data []byte, fn func(entry []byte) bool) error {
	r := &reader{b: data}
	for !r.done() {
		f, w, p, _, err := r.next()
		if err != nil {
			return err
		}
		if f == 1 && w == 2 && !fn(p) {
			return nil
		}
	}
	return nil
}

// GeoCodes lists the codes in a dat file.
func GeoCodes(data []byte) ([]string, error) {
	var out []string
	err := eachEntry(data, func(e []byte) bool {
		if c := entryCode(e); c != "" {
			out = append(out, c)
		}
		return true
	})
	sort.Strings(out)
	return out, err
}

// ReadGeoIP returns CIDRs for the requested lowercase codes.
func ReadGeoIP(data []byte, codes map[string]bool) (map[string][]string, error) {
	out := map[string][]string{}
	err := eachEntry(data, func(e []byte) bool {
		code := entryCode(e)
		if !codes[code] {
			return true
		}
		var list []string
		r := &reader{b: e}
		for !r.done() {
			f, w, p, _, err := r.next()
			if err != nil {
				return false
			}
			if f != 2 || w != 2 {
				continue
			}
			if c, ok := decodeCIDR(p); ok {
				list = append(list, c)
			}
		}
		out[code] = list
		return true
	})
	return out, err
}

func decodeCIDR(b []byte) (string, bool) {
	r := &reader{b: b}
	var ip []byte
	prefix := -1
	for !r.done() {
		f, w, p, v, err := r.next()
		if err != nil {
			return "", false
		}
		switch {
		case f == 1 && w == 2:
			ip = p
		case f == 2 && w == 0:
			prefix = int(v)
		}
	}
	if len(ip) != 4 && len(ip) != 16 {
		return "", false
	}
	if prefix < 0 {
		prefix = len(ip) * 8
	}
	if prefix > len(ip)*8 {
		return "", false
	}
	return net.IP(ip).String() + "/" + strconv.Itoa(prefix), true
}

// ReadGeoSite returns Xray domain matchers for the requested codes.
// A code may carry an attribute filter: "google@cn".
func ReadGeoSite(data []byte, codes map[string]bool) (map[string][]string, error) {
	want := map[string][]string{} // base code → requested full codes
	for c := range codes {
		base, _, _ := strings.Cut(c, "@")
		want[base] = append(want[base], c)
	}
	out := map[string][]string{}
	err := eachEntry(data, func(e []byte) bool {
		code := entryCode(e)
		full, ok := want[code]
		if !ok {
			return true
		}
		r := &reader{b: e}
		for !r.done() {
			f, w, p, _, err := r.next()
			if err != nil {
				return false
			}
			if f != 2 || w != 2 {
				continue
			}
			value, attrs, ok := decodeDomain(p)
			if !ok {
				continue
			}
			for _, fc := range full {
				_, attr, hasAttr := strings.Cut(fc, "@")
				if hasAttr && !attrs[attr] {
					continue
				}
				out[fc] = append(out[fc], value)
			}
		}
		for _, fc := range full {
			if _, ok := out[fc]; !ok {
				out[fc] = []string{}
			}
		}
		return true
	})
	return out, err
}

func decodeDomain(b []byte) (string, map[string]bool, bool) {
	r := &reader{b: b}
	typ := uint64(0)
	value := ""
	var attrs map[string]bool
	for !r.done() {
		f, w, p, v, err := r.next()
		if err != nil {
			return "", nil, false
		}
		switch {
		case f == 1 && w == 0:
			typ = v
		case f == 2 && w == 2:
			value = string(p)
		case f == 3 && w == 2:
			ar := &reader{b: p}
			for !ar.done() {
				af, aw, ap, _, err := ar.next()
				if err != nil {
					break
				}
				if af == 1 && aw == 2 {
					if attrs == nil {
						attrs = map[string]bool{}
					}
					attrs[strings.ToLower(string(ap))] = true
				}
			}
		}
	}
	if value == "" {
		return "", nil, false
	}
	switch typ {
	case 0:
		return "keyword:" + value, attrs, true
	case 1:
		return "regexp:" + value, attrs, true
	case 2:
		return "domain:" + value, attrs, true
	case 3:
		return "full:" + value, attrs, true
	}
	return "", nil, false
}

// EncodeGeoIPForTest builds a tiny geoip.dat (tests).
func EncodeGeoIPForTest(entries map[string][]string) []byte {
	var list []byte
	names := make([]string, 0, len(entries))
	for k := range entries {
		names = append(names, k)
	}
	sort.Strings(names)
	for _, code := range names {
		var entry []byte
		entry = appendBytes(entry, 1, []byte(strings.ToUpper(code)))
		for _, c := range entries[code] {
			_, n, err := net.ParseCIDR(c)
			if err != nil {
				continue
			}
			ones, _ := n.Mask.Size()
			ip := n.IP
			if v4 := ip.To4(); v4 != nil {
				ip = v4
			}
			var cidr []byte
			cidr = appendBytes(cidr, 1, ip)
			cidr = appendVarint(cidr, 2, uint64(ones))
			entry = appendBytes(entry, 2, cidr)
		}
		list = appendBytes(list, 1, entry)
	}
	return list
}

// EncodeGeoSiteForTest builds a tiny geosite.dat (tests). Values use type prefixes.
func EncodeGeoSiteForTest(entries map[string][]string) []byte {
	var list []byte
	names := make([]string, 0, len(entries))
	for k := range entries {
		names = append(names, k)
	}
	sort.Strings(names)
	for _, code := range names {
		var entry []byte
		entry = appendBytes(entry, 1, []byte(strings.ToUpper(code)))
		for _, d := range entries[code] {
			typ, value := uint64(2), d
			for i, p := range []string{"keyword:", "regexp:", "domain:", "full:"} {
				if strings.HasPrefix(d, p) {
					typ, value = uint64(i), d[len(p):]
				}
			}
			attr := ""
			if v, a, ok := strings.Cut(value, "@"); ok {
				value, attr = v, a
			}
			var dom []byte
			dom = appendVarint(dom, 1, typ)
			dom = appendBytes(dom, 2, []byte(value))
			if attr != "" {
				dom = appendBytes(dom, 3, appendBytes(nil, 1, []byte(attr)))
			}
			entry = appendBytes(entry, 2, dom)
		}
		list = appendBytes(list, 1, entry)
	}
	return list
}

func appendVarint(b []byte, field int, v uint64) []byte {
	b = putVarint(b, uint64(field<<3))
	return putVarint(b, v)
}

func appendBytes(b []byte, field int, p []byte) []byte {
	b = putVarint(b, uint64(field<<3|2))
	b = putVarint(b, uint64(len(p)))
	return append(b, p...)
}

func putVarint(b []byte, v uint64) []byte {
	for v >= 0x80 {
		b = append(b, byte(v)|0x80)
		v >>= 7
	}
	return append(b, byte(v))
}
