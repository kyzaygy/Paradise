//go:build !darwin

package engine

import "syscall"

func bindControl(index int) func(network, address string, c syscall.RawConn) error {
	return func(network, address string, c syscall.RawConn) error { return nil }
}
