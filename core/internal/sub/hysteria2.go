package sub

// Hysteria2 link parsing, adapted from SVOI (https://github.com/1atex/svoi),
// Copyright (c) 2026 SVOI contributors, MIT License. See third_party/SVOI-LICENSE.

import (
	"encoding/base64"
	"errors"
	"fmt"
	"net"
	"net/url"
	"strconv"
	"strings"

	"github.com/kyzaygy/paradise/core/internal/model"
)

func hysteriaPorts(value string) (string, int, bool, error) {
	if len(value) > 1024 {
		return "", 0, false, errors.New("hysteria2: port list too long")
	}
	parts := strings.Split(value, ",")
	first, hopping := 0, len(parts) > 1
	for i, part := range parts {
		limits := strings.Split(part, "-")
		if len(limits) > 2 {
			return "", 0, false, errors.New("hysteria2: bad port range")
		}
		low, err := strconv.ParseUint(limits[0], 10, 16)
		if err != nil || low == 0 {
			return "", 0, false, errors.New("hysteria2: bad port")
		}
		high := low
		if len(limits) == 2 {
			high, err = strconv.ParseUint(limits[1], 10, 16)
			if err != nil || high < low {
				return "", 0, false, errors.New("hysteria2: bad port range")
			}
		}
		if i == 0 {
			first = int(low)
		}
		parts[i] = strconv.FormatUint(low, 10)
		if high != low {
			parts[i] += "-" + strconv.FormatUint(high, 10)
			hopping = true
		}
	}
	return strings.Join(parts, ","), first, hopping, nil
}

func parseHysteria2(raw string) (model.Server, error) {
	invalid := func(message string) (model.Server, error) { return model.Server{}, errors.New("hysteria2: " + message) }
	schemeEnd := strings.Index(raw, "://")
	if schemeEnd < 0 || len(raw) > 16384 {
		return invalid("invalid link")
	}
	rest := raw[schemeEnd+3:]
	end := strings.IndexAny(rest, "/?#")
	if end < 0 {
		end = len(rest)
	}
	authority, tail := rest[:end], rest[end:]
	credentials, address := "", authority
	if at := strings.LastIndexByte(authority, '@'); at >= 0 {
		credentials, address = authority[:at+1], authority[at+1:]
	}
	host, ports := address, "443"
	if strings.HasPrefix(address, "[") {
		closing := strings.IndexByte(address, ']')
		if closing < 0 || net.ParseIP(address[1:closing]) == nil {
			return invalid("bad IPv6 address")
		}
		host = address[:closing+1]
		if suffix := address[closing+1:]; suffix != "" {
			if !strings.HasPrefix(suffix, ":") {
				return invalid("bad address")
			}
			ports = suffix[1:]
		}
	} else if colon := strings.IndexByte(address, ':'); colon >= 0 {
		host, ports = address[:colon], address[colon+1:]
	}
	ports, port, hopping, err := hysteriaPorts(ports)
	if err != nil {
		return model.Server{}, err
	}
	u, err := url.Parse("hysteria2://" + credentials + host + ":" + strconv.Itoa(port) + tail)
	if err != nil || u.Hostname() == "" || (u.Path != "" && u.Path != "/") {
		return invalid("bad address or path")
	}
	q, err := url.ParseQuery(u.RawQuery)
	if err != nil {
		return invalid("bad query")
	}
	for _, key := range []string{"insecure", "allowInsecure"} {
		if q.Has(key) {
			if v, err := strconv.ParseBool(q.Get(key)); err == nil && v {
				return invalid("insecure TLS is not supported by Xray hysteria")
			}
		}
	}
	if q.Get("pinSHA256") != "" {
		return invalid("pinSHA256 is not supported")
	}
	if s := q.Get("security"); s != "" && s != "tls" {
		return invalid("only TLS is supported")
	}
	for _, key := range []string{"ports", "mport", "port"} {
		if key == "port" && !strings.ContainsAny(q.Get(key), ",-") {
			continue
		}
		if q.Has(key) && !hopping {
			ports, port, hopping, err = hysteriaPorts(q.Get(key))
			if err != nil {
				return model.Server{}, err
			}
		}
	}
	auth := ""
	if u.User != nil {
		auth = u.User.Username()
		if password, present := u.User.Password(); present {
			auth += ":" + password
		}
	}
	if auth == "" {
		auth = q.Get("auth")
	}
	tls := object{"serverName": defaultString(q.Get("sni"), u.Hostname())}
	if alpn := q.Get("alpn"); alpn != "" {
		tls["alpn"] = strings.Split(alpn, ",")
	}
	if ech := q.Get("ech"); ech != "" {
		decoded, err := DecodeBase64(ech)
		if err != nil {
			return invalid("bad ECH config")
		}
		tls["echConfigList"] = base64.StdEncoding.EncodeToString(decoded)
	}
	stream := object{"network": "hysteria", "security": "tls", "tlsSettings": tls, "hysteriaSettings": object{"version": 2, "auth": auth}}
	masks := []any{}
	switch q.Get("obfs") {
	case "", "none":
	case "salamander":
		if len(q.Get("obfs-password")) < 4 {
			return invalid("salamander password too short")
		}
		masks = append(masks, object{"type": "salamander", "settings": object{"password": q.Get("obfs-password")}})
	default:
		return invalid(fmt.Sprintf("obfs %q is not supported", q.Get("obfs")))
	}
	if hopping {
		interval := 30
		for _, key := range []string{"hop-interval", "mportHopInt", "hopInterval"} {
			if q.Has(key) {
				if v, err := strconv.Atoi(strings.TrimSuffix(q.Get(key), "s")); err == nil && v >= 5 && v <= 86400 {
					interval = v
				}
			}
		}
		masks = append(masks, object{"type": "udphop", "settings": object{"mode": "intervalLocal,intervalRemote", "interval": interval, "remotePorts": ports}})
	}
	if len(masks) > 0 {
		stream["finalmask"] = object{"udp": masks}
	}
	name, _ := url.PathUnescape(u.EscapedFragment())
	srv, err := ServerFromOutbound(name, object{"protocol": "hysteria", "settings": object{"version": 2, "address": u.Hostname(), "port": port}, "streamSettings": stream})
	if err == nil {
		srv.Protocol = "hysteria2"
	}
	return srv, err
}
