//go:build darwin

package engine

import (
	"strings"
	"syscall"
)

// Darwin socket options that pin a socket to an interface (netinet/in.h, netinet6/in6.h).
const (
	ipBoundIf   = 25  // IP_BOUND_IF
	ipv6BoundIf = 125 // IPV6_BOUND_IF
)

func bindControl(index int) func(network, address string, c syscall.RawConn) error {
	return func(network, address string, c syscall.RawConn) error {
		var serr error
		err := c.Control(func(fd uintptr) {
			if strings.HasSuffix(network, "6") {
				serr = syscall.SetsockoptInt(int(fd), syscall.IPPROTO_IPV6, ipv6BoundIf, index)
			} else {
				serr = syscall.SetsockoptInt(int(fd), syscall.IPPROTO_IP, ipBoundIf, index)
			}
		})
		if err != nil {
			return err
		}
		return serr
	}
}
