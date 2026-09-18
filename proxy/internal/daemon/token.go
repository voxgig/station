package daemon

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Local auth is a token file (§8.1): ~/.voxgig/station/token, 0600 inside
// a 0700 directory, created by the proxy on first run. The path is a
// parameter so tests (and later, packaging) can relocate it.

func LoadOrCreateToken(path string) (string, error) {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", fmt.Errorf("station: cannot create token directory %s: %w", dir, err)
	}

	if b, err := os.ReadFile(path); err == nil {
		token := strings.TrimSpace(string(b))
		if token == "" {
			return "", fmt.Errorf("station: token file %s is empty", path)
		}
		return token, nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return "", fmt.Errorf("station: cannot read token file %s: %w", path, err)
	}

	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", fmt.Errorf("station: cannot generate token: %w", err)
	}
	token := hex.EncodeToString(raw)

	// O_EXCL so a concurrently starting daemon cannot truncate a token
	// another process already handed out; on collision, read theirs.
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		if errors.Is(err, os.ErrExist) {
			return LoadOrCreateToken(path)
		}
		return "", fmt.Errorf("station: cannot create token file %s: %w", path, err)
	}
	if _, err := f.WriteString(token + "\n"); err != nil {
		f.Close()
		return "", fmt.Errorf("station: cannot write token file %s: %w", path, err)
	}
	if err := f.Close(); err != nil {
		return "", fmt.Errorf("station: cannot write token file %s: %w", path, err)
	}
	return token, nil
}

func DefaultTokenPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("station: cannot resolve home directory: %w", err)
	}
	return filepath.Join(home, ".voxgig", "station", "token"), nil
}

func Proof(token string, nonce string) string {
	mac := hmac.New(sha256.New, []byte(token))
	mac.Write([]byte(nonce))
	return hex.EncodeToString(mac.Sum(nil))
}

// tokenEqual compares a presented bearer token against the real one in
// constant time. Both sides are hashed first so the comparison length is
// fixed and no length information leaks either.
func tokenEqual(presented string, actual string) bool {
	hp := sha256.Sum256([]byte(presented))
	ha := sha256.Sum256([]byte(actual))
	return subtle.ConstantTimeCompare(hp[:], ha[:]) == 1
}
