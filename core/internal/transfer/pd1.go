package transfer

import (
	"bytes"
	"compress/gzip"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"io"
	"strings"
	"time"

	"golang.org/x/crypto/argon2"

	"github.com/kyzaygy/paradise/core/internal/apperr"
)

// PD1 binary layout (all integers big-endian):
//
//	0      version (1)
//	1      flags: bit0 encrypted, bit1 gzip
//	2..9   expiresAt, unix seconds, 0 = never
//	encrypted only:
//	10..25 salt (16)
//	26     kdf id (1 = Argon2id)
//	27     argon2 time
//	28..31 argon2 memory, KiB
//	32     argon2 threads
//	33..44 AES-GCM nonce (12)
//
// The body is gzip(JSON payload), AES-256-GCM sealed with the header as
// additional data when encrypted. Expiry is enforced by the app; it is only
// tamper-proof for encrypted codes.
const (
	pd1Version     = 1
	flagEncrypted  = 1
	flagGzip       = 2
	headerPlain    = 10
	headerSealed   = 45
	kdfArgon2id    = 1
	argonTime      = 3
	argonMemoryKiB = 64 * 1024
	argonThreads   = 2
	maxArgonMemory = 256 * 1024
	maxArgonTime   = 10
	maxArgonThread = 8
)

// EncodeOptions control PD1 encoding.
type EncodeOptions struct {
	Password  string
	ExpiresAt int64
}

// EncodePD1 encodes a payload into a PD1 code.
func EncodePD1(p Payload, opt EncodeOptions) (string, error) {
	p.V = PayloadVersion
	if p.Created == 0 {
		p.Created = time.Now().Unix()
	}
	raw, err := json.Marshal(p)
	if err != nil {
		return "", apperr.New(apperr.Internal, "marshal")
	}
	if len(raw) > MaxPlainBytes {
		return "", apperr.New(apperr.TooLarge, "payload")
	}
	body, err := gz(raw)
	if err != nil {
		return "", apperr.New(apperr.Internal, "gzip")
	}
	flags := byte(flagGzip)
	headerLen := headerPlain
	if opt.Password != "" {
		flags |= flagEncrypted
		headerLen = headerSealed
	}
	header := make([]byte, headerLen)
	header[0] = pd1Version
	header[1] = flags
	expires := opt.ExpiresAt
	if expires < 0 {
		expires = 0
	}
	binary.BigEndian.PutUint64(header[2:10], uint64(expires))
	if opt.Password != "" {
		salt := header[10:26]
		if _, err = rand.Read(salt); err != nil {
			return "", apperr.New(apperr.Internal, "rand")
		}
		header[26] = kdfArgon2id
		header[27] = argonTime
		binary.BigEndian.PutUint32(header[28:32], argonMemoryKiB)
		header[32] = argonThreads
		nonce := header[33:45]
		if _, err = rand.Read(nonce); err != nil {
			return "", apperr.New(apperr.Internal, "rand")
		}
		aead, err := newAEAD(opt.Password, salt, argonTime, argonMemoryKiB, argonThreads)
		if err != nil {
			return "", err
		}
		body = aead.Seal(nil, nonce, body, header)
	}
	return PD1Prefix + base64.RawURLEncoding.EncodeToString(append(header, body...)), nil
}

func newAEAD(password string, salt []byte, t uint32, mem uint32, threads uint8) (cipher.AEAD, error) {
	key := argon2.IDKey([]byte(password), salt, t, mem, threads, 32)
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, apperr.New(apperr.Internal, "cipher")
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, apperr.New(apperr.Internal, "gcm")
	}
	return aead, nil
}

func gz(b []byte) ([]byte, error) {
	var out bytes.Buffer
	w, _ := gzip.NewWriterLevel(&out, gzip.BestCompression)
	if _, err := w.Write(b); err != nil {
		return nil, err
	}
	if err := w.Close(); err != nil {
		return nil, err
	}
	return out.Bytes(), nil
}

func gunzip(b []byte) ([]byte, error) {
	r, err := gzip.NewReader(bytes.NewReader(b))
	if err != nil {
		return nil, err
	}
	defer r.Close()
	out, err := io.ReadAll(io.LimitReader(r, MaxPlainBytes+1))
	if err != nil {
		return nil, err
	}
	if len(out) > MaxPlainBytes {
		return nil, apperr.New(apperr.TooLarge, "payload")
	}
	return out, nil
}

func decodeBlob(code string) ([]byte, error) {
	data := strings.TrimPrefix(code, PD1Prefix)
	for _, enc := range []*base64.Encoding{base64.RawURLEncoding, base64.URLEncoding, base64.RawStdEncoding, base64.StdEncoding} {
		if b, err := enc.DecodeString(data); err == nil {
			return b, nil
		}
	}
	return nil, apperr.New(apperr.TransferCorrupted, "base64")
}

// InspectPD1 reads the PD1 header without decrypting.
func InspectPD1(code string) (Envelope, error) {
	blob, err := decodeBlob(code)
	if err != nil {
		return Envelope{}, err
	}
	if len(blob) < headerPlain {
		return Envelope{}, apperr.New(apperr.TransferCorrupted, "short")
	}
	if blob[0] != pd1Version {
		return Envelope{}, apperr.New(apperr.TransferVersion, "")
	}
	return Envelope{Format: FormatPD1, Encrypted: blob[1]&flagEncrypted != 0, ExpiresAt: int64(binary.BigEndian.Uint64(blob[2:10]))}, nil
}

// DecodePD1 decrypts (if needed) and decodes a PD1 code.
func DecodePD1(code, password string, now time.Time) (Payload, Envelope, error) {
	if len(code) > MaxCodeChars {
		return Payload{}, Envelope{}, apperr.New(apperr.TooLarge, "code")
	}
	blob, err := decodeBlob(code)
	if err != nil {
		return Payload{}, Envelope{}, err
	}
	env, err := InspectPD1(code)
	if err != nil {
		return Payload{}, env, err
	}
	flags := blob[1]
	if flags&flagGzip == 0 || flags&^byte(flagEncrypted|flagGzip) != 0 {
		return Payload{}, env, apperr.New(apperr.TransferVersion, "flags")
	}
	if env.ExpiresAt > 0 && now.Unix() > env.ExpiresAt {
		return Payload{}, env, apperr.New(apperr.TransferExpired, "")
	}
	var body []byte
	if env.Encrypted {
		if len(blob) < headerSealed+16 {
			return Payload{}, env, apperr.New(apperr.TransferCorrupted, "short")
		}
		if password == "" {
			return Payload{}, env, apperr.New(apperr.TransferPassword, "")
		}
		header := blob[:headerSealed]
		if header[26] != kdfArgon2id {
			return Payload{}, env, apperr.New(apperr.TransferVersion, "kdf")
		}
		t := uint32(header[27])
		mem := binary.BigEndian.Uint32(header[28:32])
		threads := header[32]
		if t == 0 || t > maxArgonTime || mem < 8*1024 || mem > maxArgonMemory || threads == 0 || threads > maxArgonThread {
			return Payload{}, env, apperr.New(apperr.TransferCorrupted, "kdf params")
		}
		aead, err := newAEAD(password, header[10:26], t, mem, threads)
		if err != nil {
			return Payload{}, env, err
		}
		body, err = aead.Open(nil, header[33:45], blob[headerSealed:], header)
		if err != nil {
			return Payload{}, env, apperr.New(apperr.TransferWrongPass, "")
		}
	} else {
		body = blob[headerPlain:]
	}
	raw, err := gunzip(body)
	if err != nil {
		return Payload{}, env, apperr.From(asCorrupted(err))
	}
	var p Payload
	if err := json.Unmarshal(raw, &p); err != nil {
		return Payload{}, env, apperr.New(apperr.TransferCorrupted, "json")
	}
	if p.V < 1 || p.V > PayloadVersion {
		return Payload{}, env, apperr.New(apperr.TransferVersion, "")
	}
	if len(p.Crit) > 0 {
		return Payload{}, env, apperr.New(apperr.TransferVersion, "crit")
	}
	if err := validate(&p); err != nil {
		return Payload{}, env, err
	}
	return p, env, nil
}

func asCorrupted(err error) error {
	if e, ok := err.(*apperr.Error); ok {
		return e
	}
	return apperr.New(apperr.TransferCorrupted, "gzip")
}

func validate(p *Payload) error {
	if len(p.Subscriptions) == 0 {
		return apperr.New(apperr.TransferEmpty, "")
	}
	if len(p.Subscriptions) > MaxSources {
		return apperr.New(apperr.TooLarge, "sources")
	}
	total := 0
	for i := range p.Subscriptions {
		s := &p.Subscriptions[i]
		s.Name = truncate(s.Name, MaxNameRunes)
		if len(s.Servers) > MaxServersPerSrc {
			return apperr.New(apperr.TooLarge, "servers")
		}
		total += len(s.Servers)
		if s.URL == "" && len(s.Servers) == 0 {
			return apperr.New(apperr.TransferCorrupted, "empty source")
		}
		for j := range s.Servers {
			c := &s.Servers[j]
			c.Name = truncate(c.Name, 512)
			if len(c.Outbound) == 0 && len(c.Profile) == 0 {
				return apperr.New(apperr.TransferCorrupted, "empty config")
			}
		}
	}
	if total > MaxServersTotal {
		return apperr.New(apperr.TooLarge, "servers")
	}
	p.Name = truncate(p.Name, MaxNameRunes)
	if len(p.Favorites) > MaxServersTotal {
		p.Favorites = p.Favorites[:MaxServersTotal]
	}
	if p.Identity != nil && (p.Identity.HWID == "" || len(p.Identity.HWID) > 180) {
		p.Identity = nil
	}
	if p.Settings != nil {
		p.Settings.Normalize()
	}
	return nil
}
