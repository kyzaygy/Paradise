// Package store persists the profile document encrypted with AES-256-GCM.
// The key lives in the iOS Keychain and is passed in by the app.
package store

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"

	"github.com/kyzaygy/paradise/core/internal/apperr"
	"github.com/kyzaygy/paradise/core/internal/model"
)

const (
	fileName = "profile.pdx"
	magic    = "PDX1"
)

// Store reads and writes the document.
type Store struct {
	path string
	aead cipher.AEAD
}

// Open prepares a store in dir with a 32-byte key.
func Open(dir string, key []byte) (*Store, error) {
	if len(key) != 32 {
		return nil, apperr.New(apperr.Storage, "key")
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, apperr.New(apperr.Storage, "mkdir")
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, apperr.New(apperr.Storage, "cipher")
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, apperr.New(apperr.Storage, "gcm")
	}
	return &Store{path: filepath.Join(dir, fileName), aead: aead}, nil
}

// Load returns the stored document or a fresh one.
func (s *Store) Load() (*model.Document, error) {
	data, err := os.ReadFile(s.path)
	if errors.Is(err, os.ErrNotExist) {
		return &model.Document{Version: 1, Settings: model.DefaultSettings()}, nil
	}
	if err != nil {
		return nil, apperr.New(apperr.Storage, "read")
	}
	ns := s.aead.NonceSize()
	if len(data) < len(magic)+ns+s.aead.Overhead() || string(data[:len(magic)]) != magic {
		return nil, apperr.New(apperr.Storage, "format")
	}
	nonce := data[len(magic) : len(magic)+ns]
	plain, err := s.aead.Open(nil, nonce, data[len(magic)+ns:], []byte(magic))
	if err != nil {
		return nil, apperr.New(apperr.Storage, "decrypt")
	}
	var doc model.Document
	if err := json.Unmarshal(plain, &doc); err != nil {
		return nil, apperr.New(apperr.Storage, "json")
	}
	if doc.Version == 0 {
		doc.Version = 1
	}
	doc.Settings.Normalize()
	return &doc, nil
}

// Save writes the document atomically.
func (s *Store) Save(doc *model.Document) error {
	plain, err := json.Marshal(doc)
	if err != nil {
		return apperr.New(apperr.Storage, "marshal")
	}
	nonce := make([]byte, s.aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return apperr.New(apperr.Storage, "rand")
	}
	out := append([]byte(magic), nonce...)
	out = s.aead.Seal(out, nonce, plain, []byte(magic))
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, out, 0o600); err != nil {
		return apperr.New(apperr.Storage, "write")
	}
	if err := os.Rename(tmp, s.path); err != nil {
		return apperr.New(apperr.Storage, "rename")
	}
	return nil
}

// Path returns the file path (for tests).
func (s *Store) Path() string { return s.path }
