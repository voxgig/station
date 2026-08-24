package daemon

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"
)

func TestLoadOrCreateToken(t *testing.T) {
	dir := filepath.Join(t.TempDir(), ".voxgig", "station")
	path := filepath.Join(dir, "token")

	token, err := LoadOrCreateToken(path)
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if len(token) != 64 {
		t.Fatalf("token length = %d, want 64 hex chars", len(token))
	}
	if _, err := hex.DecodeString(token); err != nil {
		t.Fatalf("token is not hex: %v", err)
	}

	// §8.1: 0600 file inside a 0700 directory.
	fi, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat token: %v", err)
	}
	if got := fi.Mode().Perm(); got != 0o600 {
		t.Errorf("token file mode = %o, want 600", got)
	}
	di, err := os.Stat(dir)
	if err != nil {
		t.Fatalf("stat dir: %v", err)
	}
	if got := di.Mode().Perm(); got != 0o700 {
		t.Errorf("token dir mode = %o, want 700", got)
	}

	// Second run reads the same token back.
	again, err := LoadOrCreateToken(path)
	if err != nil {
		t.Fatalf("reload: %v", err)
	}
	if again != token {
		t.Errorf("reload returned a different token")
	}
}

func TestLoadOrCreateTokenExisting(t *testing.T) {
	path := filepath.Join(t.TempDir(), "token")
	if err := os.WriteFile(path, []byte("  seekrit-token \n"), 0o600); err != nil {
		t.Fatal(err)
	}
	token, err := LoadOrCreateToken(path)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if token != "seekrit-token" {
		t.Errorf("token = %q, want trimmed %q", token, "seekrit-token")
	}
}

func TestLoadOrCreateTokenEmpty(t *testing.T) {
	path := filepath.Join(t.TempDir(), "token")
	if err := os.WriteFile(path, []byte("\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadOrCreateToken(path); err == nil {
		t.Fatal("empty token file should be an error, got nil")
	}
}

// TestProof plays the client side of §8.1's proof-of-token: the client
// computes hex(HMAC-SHA256(token, nonce)) itself and compares.
func TestProof(t *testing.T) {
	cases := []struct {
		name  string
		token string
		nonce string
	}{
		{"simple", "tok", "nonce-1"},
		{"long nonce", "tok", string(make([]byte, 4096))},
		{"binary-ish nonce", "another-token", "\x00\x01\xff nonce"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			mac := hmac.New(sha256.New, []byte(c.token))
			mac.Write([]byte(c.nonce))
			want := hex.EncodeToString(mac.Sum(nil))
			if got := Proof(c.token, c.nonce); got != want {
				t.Errorf("Proof = %s, want %s", got, want)
			}
		})
	}

	if Proof("token-a", "n") == Proof("token-b", "n") {
		t.Error("different tokens must yield different proofs")
	}
	if Proof("token-a", "n1") == Proof("token-a", "n2") {
		t.Error("different nonces must yield different proofs")
	}
}

func TestTokenEqual(t *testing.T) {
	cases := []struct {
		name      string
		presented string
		actual    string
		want      bool
	}{
		{"equal", "abc", "abc", true},
		{"different", "abc", "abd", false},
		{"different length", "ab", "abc", false},
		{"empty presented", "", "abc", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := tokenEqual(c.presented, c.actual); got != c.want {
				t.Errorf("tokenEqual(%q, %q) = %v, want %v", c.presented, c.actual, got, c.want)
			}
		})
	}
}
