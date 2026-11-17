package logx

import (
	"strings"
	"testing"
)

func TestRedact(t *testing.T) {
	in := `Get "https://connect.example.net/to/f9509d51e6e86fcccad1a17380b7e2d3": dial tcp; vless://11111111-2222-3333-4444-555555555555@host:443?pbk=abc#name; code PD1.AAAAbbbbCCCCdddd; uuid 11111111-2222-3333-4444-555555555555; https://ok.example.com`
	out := Redact(in)
	for _, secret := range []string{"f9509d51", "11111111-2222", "AAAAbbbb", "pbk=abc"} {
		if strings.Contains(out, secret) {
			t.Fatalf("leaked %q in %s", secret, out)
		}
	}
	for _, keep := range []string{"connect.example.net", "https://ok.example.com", "vless://<…>", "PD1.<code>"} {
		if !strings.Contains(out, keep) {
			t.Fatalf("missing %q in %s", keep, out)
		}
	}
}

func TestRingBuffer(t *testing.T) {
	Clear()
	for i := 0; i < capacity+50; i++ {
		Info("test", "line %d", i)
	}
	all := Since(0)
	if len(all) != capacity {
		t.Fatalf("len %d", len(all))
	}
	last := all[len(all)-1].ID
	Info("test", "new")
	if got := Since(last); len(got) != 1 || got[0].Msg != "new" {
		t.Fatalf("since %+v", got)
	}
}
