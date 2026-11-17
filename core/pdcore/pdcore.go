// Package pdcore is the gomobile surface of the Paradise core.
//
// The app calls Open once and then Call(method, jsonArgs); every call returns
// a JSON envelope {"ok":bool,"data":...,"error":{"code","detail"}}.
// The Network Extension only uses StartTunnel / StopTunnel.
package pdcore

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"os"
	"runtime"
	"runtime/debug"
	"strconv"
	"strings"
	"sync"
	"time"

	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/core"

	"github.com/kyzaygy/paradise/core/internal/apperr"
	"github.com/kyzaygy/paradise/core/internal/engine"
	"github.com/kyzaygy/paradise/core/internal/logx"
)

var (
	engineMu sync.Mutex
	eng      *engine.Engine
)

func envelopeError(code, detail string) string {
	b, _ := json.Marshal(map[string]any{"ok": false, "error": apperr.New(code, detail)})
	return string(b)
}

// Open initializes the engine. key is a base64 32-byte key from the Keychain;
// device is JSON {"platform","osVersion","model","locale","appVersion"}.
func Open(dir, key, device string) string {
	engineMu.Lock()
	defer engineMu.Unlock()
	if eng != nil {
		return `{"ok":true}`
	}
	k, err := base64.StdEncoding.DecodeString(key)
	if err != nil || len(k) != 32 {
		return envelopeError(apperr.Storage, "key")
	}
	var dev engine.Device
	_ = json.Unmarshal([]byte(device), &dev)
	logx.Info("core", "xray %s, %s/%s, app %s, iOS %s, %s", core.Version(), runtime.GOOS, runtime.GOARCH, dev.AppVersion, dev.OSVersion, dev.Model)
	e, err := engine.New(dir, k, dev, xrayProber{})
	if err != nil {
		ae := apperr.From(err)
		logx.Error("core", "open failed: %s %s", ae.Code, ae.Detail)
		return envelopeError(ae.Code, ae.Detail)
	}
	e.SetValidator(validateConfig)
	eng = e
	return `{"ok":true}`
}

// Call runs an engine method.
func Call(method, args string) string {
	engineMu.Lock()
	e := eng
	engineMu.Unlock()
	if e == nil {
		return envelopeError(apperr.Internal, "not opened")
	}
	return e.Call(method, args)
}

// Log adds a line to the in-process log buffer (used by Swift in the app and the extension).
func Log(level, source, msg string) {
	if level != "warn" && level != "error" {
		level = "info"
	}
	logx.Add(level, source, "%s", msg)
}

func validateConfig(b []byte) error {
	_, err := core.LoadConfig("json", bytes.NewReader(b))
	return err
}

// Version returns the Xray core version.
func Version() string { return core.Version() }

// MemoryStats returns Go heap statistics as JSON (diagnostics, no secrets).
func MemoryStats() string {
	var s runtime.MemStats
	runtime.ReadMemStats(&s)
	b, _ := json.Marshal(map[string]any{"heapAlloc": s.HeapAlloc, "heapInuse": s.HeapInuse, "sys": s.Sys, "goroutines": runtime.NumGoroutine(), "gc": s.NumGC})
	return string(b)
}

// ---- Tunnel (Network Extension) ----

var (
	tunnelMu sync.Mutex
	tunnel   *core.Instance
)

// StartTunnel starts Xray reading packets from fd (4-byte AF header, utun framing).
// When logPath is set, Xray warnings and errors are written there for diagnostics.
// Returns an empty string on success or an error message.
func StartTunnel(config string, fd int32, logPath string) string {
	tunnelMu.Lock()
	defer tunnelMu.Unlock()
	if tunnel != nil {
		return "already running"
	}
	if fd < 0 {
		return "invalid descriptor"
	}
	debug.SetMemoryLimit(30 << 20)
	debug.SetGCPercent(50)
	_ = os.Setenv("XRAY_TUN_FD", strconv.Itoa(int(fd)))
	if logPath != "" {
		var cfg map[string]any
		if json.Unmarshal([]byte(config), &cfg) == nil {
			cfg["log"] = map[string]any{"loglevel": "warning", "access": "none", "dnsLog": false, "error": logPath}
			if b, err := json.Marshal(cfg); err == nil {
				config = string(b)
			}
		}
	}
	start := time.Now()
	inst, err := core.StartInstance("json", []byte(config))
	if err != nil {
		logx.Error("tunnel", "xray start failed: %v", err)
		return err.Error()
	}
	tunnel = inst
	var m runtime.MemStats
	runtime.ReadMemStats(&m)
	logx.Info("tunnel", "xray %s started in %dms, heap %d MB", core.Version(), time.Since(start).Milliseconds(), m.HeapAlloc>>20)
	return ""
}

// TunnelLogs returns the extension's log buffer and the tail of the Xray log file as JSON.
func TunnelLogs(logPath string) string {
	tail := ""
	if logPath != "" {
		if f, err := os.Open(logPath); err == nil {
			if st, err := f.Stat(); err == nil {
				size := st.Size()
				const max = 12 << 10
				if size > max {
					_, _ = f.Seek(size-max, io.SeekStart)
				}
				b, _ := io.ReadAll(io.LimitReader(f, max))
				lines := strings.Split(string(b), "\n")
				for i := range lines {
					lines[i] = logx.Redact(lines[i])
				}
				tail = strings.Join(lines, "\n")
			}
			_ = f.Close()
		}
	}
	var m runtime.MemStats
	runtime.ReadMemStats(&m)
	b, _ := json.Marshal(map[string]any{
		"entries":    logx.Since(0),
		"xray":       tail,
		"heapMB":     m.HeapAlloc >> 20,
		"sysMB":      m.Sys >> 20,
		"goroutines": runtime.NumGoroutine(),
	})
	return string(b)
}

// StopTunnel stops the running instance.
func StopTunnel() string {
	tunnelMu.Lock()
	defer tunnelMu.Unlock()
	if tunnel == nil {
		return ""
	}
	err := tunnel.Close()
	tunnel = nil
	debug.FreeOSMemory()
	logx.Info("tunnel", "xray stopped")
	if err != nil {
		return err.Error()
	}
	return ""
}

// ---- Latency probe ----

type xrayProber struct{}

func (xrayProber) Probe(ctx context.Context, config []byte, url string) (int64, error) {
	inst, err := core.StartInstance("json", config)
	if err != nil {
		return 0, apperr.New(apperr.Config, "start")
	}
	defer inst.Close()
	transport := &http.Transport{
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			dest, err := xnet.ParseDestination("tcp:" + addr)
			if err != nil {
				return nil, err
			}
			return core.Dial(ctx, inst, dest)
		},
		DisableKeepAlives:   true,
		TLSHandshakeTimeout: 5 * time.Second,
		ForceAttemptHTTP2:   false,
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return 0, apperr.New(apperr.InvalidInput, "probe url")
	}
	start := time.Now()
	resp, err := client.Do(req)
	if err != nil {
		if ctx.Err() == context.Canceled {
			return 0, apperr.New(apperr.Cancelled, "")
		}
		return 0, apperr.New(apperr.ProbeFailed, "")
	}
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 64<<10))
	_ = resp.Body.Close()
	if resp.StatusCode >= 500 {
		return 0, apperr.New(apperr.ProbeFailed, strconv.Itoa(resp.StatusCode))
	}
	return time.Since(start).Milliseconds(), nil
}
