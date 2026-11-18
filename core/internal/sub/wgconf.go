package sub

import (
	"errors"
	"fmt"
	"net"
	"strconv"
	"strings"

	"github.com/kyzaygy/paradise/core/internal/model"
)

// IsWireGuardConf reports text in the wg-quick format ([Interface] / [Peer]).
func IsWireGuardConf(s string) bool {
	low := strings.ToLower(s)
	return strings.Contains(low, "[interface]") && strings.Contains(low, "privatekey") && strings.Contains(low, "[peer]")
}

// ParseWireGuardConf converts a wg-quick config into servers (one per peer).
//
//	[Interface] PrivateKey, Address, DNS, MTU (and the non-standard Reserved used by WARP tools)
//	[Peer]      PublicKey, PresharedKey, AllowedIPs, Endpoint, PersistentKeepalive
func ParseWireGuardConf(text string) ([]model.Server, []string, error) {
	type peer struct {
		public, psk, endpoint string
		allowed               []any
		keepalive             int
		line                  int
	}
	var (
		secret, name string
		addresses    []any
		reserved     []any
		mtu          int
		peers        []peer
		warnings     []string
		section      string
	)
	for i, raw := range strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n") {
		n := i + 1
		line := strings.TrimSpace(raw)
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "#") {
			// "# Name = Germany" or "# Germany" before the [Interface] works as a name
			c := strings.TrimSpace(strings.TrimLeft(line, "#"))
			if k, v, ok := strings.Cut(c, "="); ok && strings.EqualFold(strings.TrimSpace(k), "name") {
				name = strings.TrimSpace(v)
			} else if section == "" && name == "" {
				name = c
			}
			continue
		}
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			section = strings.ToLower(strings.TrimSpace(line[1 : len(line)-1]))
			if section == "peer" {
				peers = append(peers, peer{line: n})
			}
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			warnings = append(warnings, fmt.Sprintf("line %d: not key = value", n))
			continue
		}
		key := strings.ToLower(strings.TrimSpace(k))
		val := strings.TrimSpace(v)
		switch section {
		case "interface":
			switch key {
			case "privatekey":
				k, ok := wgKey(val)
				if !ok {
					return nil, warnings, fmt.Errorf("line %d: invalid PrivateKey", n)
				}
				secret = k
			case "address":
				for _, a := range strings.Split(val, ",") {
					a = strings.TrimSpace(a)
					if a == "" {
						continue
					}
					if !strings.Contains(a, "/") {
						if ip := net.ParseIP(a); ip != nil && ip.To4() != nil {
							a += "/32"
						} else {
							a += "/128"
						}
					}
					if _, _, err := net.ParseCIDR(a); err != nil {
						return nil, warnings, fmt.Errorf("line %d: invalid Address %q", n, a)
					}
					addresses = append(addresses, a)
				}
			case "mtu":
				m, err := strconv.Atoi(val)
				if err != nil || m < 576 || m > 1500 {
					return nil, warnings, fmt.Errorf("line %d: MTU must be 576–1500", n)
				}
				mtu = m
			case "reserved":
				for _, part := range strings.Split(val, ",") {
					b, err := strconv.Atoi(strings.TrimSpace(part))
					if err != nil || b < 0 || b > 255 {
						return nil, warnings, fmt.Errorf("line %d: invalid Reserved", n)
					}
					reserved = append(reserved, b)
				}
				if len(reserved) != 3 {
					return nil, warnings, fmt.Errorf("line %d: Reserved needs 3 bytes", n)
				}
			case "dns", "listenport", "table", "preup", "postup", "predown", "postdown", "saveconfig", "fwmark":
				// handled by the app's own tunnel settings or meaningless on iOS
			default:
				warnings = append(warnings, fmt.Sprintf("line %d: %s ignored", n, k))
			}
		case "peer":
			p := &peers[len(peers)-1]
			switch key {
			case "publickey":
				k, ok := wgKey(val)
				if !ok {
					return nil, warnings, fmt.Errorf("line %d: invalid PublicKey", n)
				}
				p.public = k
			case "presharedkey":
				k, ok := wgKey(val)
				if !ok {
					return nil, warnings, fmt.Errorf("line %d: invalid PresharedKey", n)
				}
				p.psk = k
			case "endpoint":
				host, port, err := net.SplitHostPort(val)
				pn, perr := strconv.Atoi(port)
				if err != nil || host == "" || perr != nil || pn < 1 || pn > 65535 {
					return nil, warnings, fmt.Errorf("line %d: Endpoint must be host:port", n)
				}
				p.endpoint = net.JoinHostPort(host, port)
			case "allowedips":
				for _, a := range strings.Split(val, ",") {
					a = strings.TrimSpace(a)
					if a == "" {
						continue
					}
					if _, _, err := net.ParseCIDR(a); err != nil {
						return nil, warnings, fmt.Errorf("line %d: invalid AllowedIPs %q", n, a)
					}
					p.allowed = append(p.allowed, a)
				}
			case "persistentkeepalive":
				ka, err := strconv.Atoi(val)
				if err != nil || ka < 0 || ka > 65535 {
					return nil, warnings, fmt.Errorf("line %d: invalid PersistentKeepalive", n)
				}
				p.keepalive = ka
			default:
				warnings = append(warnings, fmt.Sprintf("line %d: %s ignored", n, k))
			}
		default:
			warnings = append(warnings, fmt.Sprintf("line %d: outside [Interface]/[Peer]", n))
		}
	}
	if secret == "" {
		return nil, warnings, errors.New("[Interface] has no PrivateKey")
	}
	if len(peers) == 0 {
		return nil, warnings, errors.New("no [Peer]")
	}
	var servers []model.Server
	for i, p := range peers {
		if p.public == "" || p.endpoint == "" {
			warnings = append(warnings, fmt.Sprintf("line %d: peer without PublicKey or Endpoint skipped", p.line))
			continue
		}
		pc := object{"publicKey": p.public, "endpoint": p.endpoint}
		if p.psk != "" {
			pc["preSharedKey"] = p.psk
		}
		if len(p.allowed) > 0 {
			pc["allowedIPs"] = p.allowed
		}
		if p.keepalive > 0 {
			pc["keepAlive"] = p.keepalive
		}
		settings := object{"secretKey": secret, "peers": []any{pc}, "noKernelTun": true}
		if len(addresses) > 0 {
			settings["address"] = addresses
		}
		if mtu > 0 {
			settings["mtu"] = mtu
		}
		if len(reserved) == 3 {
			settings["reserved"] = reserved
		}
		label := name
		if label == "" {
			label = "WireGuard " + p.endpoint
		} else if len(peers) > 1 {
			label = fmt.Sprintf("%s %d", name, i+1)
		}
		srv, err := ServerFromOutbound(label, object{"protocol": "wireguard", "settings": settings})
		if err != nil {
			warnings = append(warnings, fmt.Sprintf("line %d: %v", p.line, err))
			continue
		}
		servers = append(servers, srv)
	}
	if len(servers) == 0 {
		return nil, warnings, errors.New("no usable [Peer]")
	}
	return servers, warnings, nil
}
