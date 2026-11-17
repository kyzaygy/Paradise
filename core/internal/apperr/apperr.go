// Package apperr defines error codes shared between the Go core and the UI.
// The UI translates codes into localized text; Detail is a short technical hint
// that must never contain secrets (subscription URLs, keys, transfer codes).
package apperr

import "errors"

const (
	InvalidInput       = "invalid_input"
	Network            = "network"
	HTTPStatus         = "http_status"
	HTMLResponse       = "html_response"
	EmptySubscription  = "empty_subscription"
	UnsupportedFormat  = "unsupported_format"
	TooLarge           = "too_large"
	NotFound           = "not_found"
	Storage            = "storage"
	Config             = "config"
	ProbeFailed        = "probe_failed"
	ProbeBusy          = "probe_busy"
	Cancelled          = "cancelled"
	TransferCorrupted  = "transfer_corrupted"
	TransferVersion    = "transfer_version"
	TransferPassword   = "transfer_password_required"
	TransferWrongPass  = "transfer_password_wrong"
	TransferExpired    = "transfer_expired"
	TransferEmpty      = "transfer_empty"
	TransferTooLargeQR = "transfer_too_large"
	Tunnel             = "tunnel"
	Internal           = "internal"
)

// Error is a coded error.
type Error struct {
	Code   string `json:"code"`
	Detail string `json:"detail,omitempty"`
}

func (e *Error) Error() string {
	if e.Detail == "" {
		return e.Code
	}
	return e.Code + ": " + e.Detail
}

// New creates a coded error.
func New(code, detail string) *Error { return &Error{Code: code, Detail: detail} }

// From converts any error into a coded error.
func From(err error) *Error {
	if err == nil {
		return nil
	}
	var e *Error
	if errors.As(err, &e) {
		return e
	}
	return &Error{Code: Internal, Detail: err.Error()}
}
