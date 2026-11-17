// Package logx is an in-memory log ring buffer with secret redaction.
// Nothing is written to disk and nothing leaves the device unless the user copies it.
package logx

import (
	"fmt"
	"regexp"
	"strings"
	"sync"
	"time"
)

// Entry is one log line.
type Entry struct {
	ID     int64  `json:"id"`
	Time   int64  `json:"time"` // unix milliseconds
	Level  string `json:"level"`
	Source string `json:"source"`
	Msg    string `json:"msg"`
}

const capacity = 800

var (
	mu      sync.Mutex
	entries []Entry
	nextID  int64 = 1
)

var (
	reURL    = regexp.MustCompile(`(?i)\b([a-z][a-z0-9+.-]*)://([^\s/?#"']+)[^\s"']*`)
	reUUID   = regexp.MustCompile(`(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b`)
	reCode   = regexp.MustCompile(`\b(PD1|SVOI1)\.[A-Za-z0-9_\-+/=]{8,}`)
	reLongID = regexp.MustCompile(`\b[A-Za-z0-9_\-]{32,}\b`)
)

// Redact removes subscription paths, credentials, UUIDs and transfer codes.
func Redact(s string) string {
	s = reCode.ReplaceAllString(s, "$1.<code>")
	s = reURL.ReplaceAllStringFunc(s, func(m string) string {
		sub := reURL.FindStringSubmatch(m)
		scheme, host := strings.ToLower(sub[1]), sub[2]
		if i := strings.LastIndex(host, "@"); i >= 0 {
			host = "<cred>@" + host[i+1:]
		}
		switch scheme {
		case "http", "https":
			if len(m) > len(sub[1])+3+len(sub[2]) {
				return scheme + "://" + host + "/<…>"
			}
			return scheme + "://" + host
		}
		return scheme + "://<…>"
	})
	s = reUUID.ReplaceAllString(s, "<uuid>")
	s = reLongID.ReplaceAllString(s, "<id>")
	if len(s) > 600 {
		s = s[:600] + "…"
	}
	return s
}

// Add appends a redacted entry.
func Add(level, source, format string, args ...any) {
	msg := Redact(fmt.Sprintf(format, args...))
	mu.Lock()
	defer mu.Unlock()
	entries = append(entries, Entry{ID: nextID, Time: time.Now().UnixMilli(), Level: level, Source: source, Msg: msg})
	nextID++
	if len(entries) > capacity {
		entries = append([]Entry(nil), entries[len(entries)-capacity:]...)
	}
}

// Info logs an informational line.
func Info(source, format string, args ...any) { Add("info", source, format, args...) }

// Warn logs a warning.
func Warn(source, format string, args ...any) { Add("warn", source, format, args...) }

// Error logs an error.
func Error(source, format string, args ...any) { Add("error", source, format, args...) }

// Since returns entries with ID > after.
func Since(after int64) []Entry {
	mu.Lock()
	defer mu.Unlock()
	out := []Entry{}
	for _, e := range entries {
		if e.ID > after {
			out = append(out, e)
		}
	}
	return out
}

// Clear drops all entries.
func Clear() {
	mu.Lock()
	defer mu.Unlock()
	entries = nil
}
