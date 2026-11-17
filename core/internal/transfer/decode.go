package transfer

import (
	"strings"
	"time"

	"github.com/kyzaygy/paradise/core/internal/apperr"
)

// Decoded is the result of decoding any supported code.
type Decoded struct {
	Payload  Payload
	Envelope Envelope
	Skipped  int
}

// Inspect returns the envelope of a code without decrypting it.
func Inspect(text string) (Envelope, error) {
	code := ExtractCode(text)
	switch {
	case strings.HasPrefix(code, PD1Prefix):
		return InspectPD1(code)
	case strings.HasPrefix(code, SVOI1Prefix):
		return Envelope{Format: FormatSVOI1}, nil
	}
	return Envelope{}, apperr.New(apperr.TransferCorrupted, "prefix")
}

// Decode decodes any supported code or link.
func Decode(text, password string, now time.Time) (Decoded, error) {
	code := ExtractCode(text)
	switch {
	case strings.HasPrefix(code, PD1Prefix):
		p, env, err := DecodePD1(code, password, now)
		return Decoded{Payload: p, Envelope: env}, err
	case strings.HasPrefix(code, SVOI1Prefix):
		p, skipped, err := DecodeSVOI1(code)
		return Decoded{Payload: p, Envelope: Envelope{Format: FormatSVOI1}, Skipped: skipped}, err
	}
	return Decoded{}, apperr.New(apperr.TransferCorrupted, "prefix")
}
