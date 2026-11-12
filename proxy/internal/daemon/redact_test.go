package daemon

import "testing"

// --- §5.3/§7: one pass over every form of every held value -------------

func TestScrubTextOverlappingValues(t *testing.T) {
	for _, values := range [][]string{{"abcd", "cdef"}, {"cdef", "abcd"}} {
		got, changed := scrubText("x=abcdef", values)
		if got != "x=[redacted]" || !changed {
			t.Fatalf("values %q: got %q (changed %v), want %q", values, got, changed, "x=[redacted]")
		}
	}
}

func TestScrubTextNestedValues(t *testing.T) {
	for _, values := range [][]string{{"ab", "abcd"}, {"abcd", "ab"}} {
		got, _ := scrubText("abcd ab", values)
		if got != "[redacted] [redacted]" {
			t.Fatalf("values %q: got %q", values, got)
		}
	}
}

func TestScrubTextEncodedForm(t *testing.T) {
	got, changed := scrubText("/q?token=tok%21en%201 raw=tok!en 1", []string{"tok!en 1"})
	if got != "/q?token=[redacted] raw=[redacted]" || !changed {
		t.Fatalf("got %q (changed %v)", got, changed)
	}
}

// A held value that is part of another value's encoded form must not
// split it, in either order.
func TestScrubTextPercentInsideAnEncodedForm(t *testing.T) {
	for _, values := range [][]string{{"%", "secret!"}, {"secret!", "%"}} {
		got, _ := scrubText("token=secret%21", values)
		if got != "token=[redacted]" {
			t.Fatalf("values %q: got %q", values, got)
		}
	}
}

func TestScrubTextNothingToReplace(t *testing.T) {
	for _, values := range [][]string{nil, {""}, {"abcd"}} {
		got, changed := scrubText("nothing here", values)
		if got != "nothing here" || changed {
			t.Fatalf("values %q: got %q (changed %v)", values, got, changed)
		}
	}
}

func TestBrokerScrubOverlappingHeldValues(t *testing.T) {
	b, err := newBroker(nil)
	if err != nil {
		t.Fatal(err)
	}
	b.held = []string{"abcd", "cdef"}
	if got := b.scrub("upstream request failed: x=abcdef"); got != "upstream request failed: x=[redacted]" {
		t.Fatalf("got %q", got)
	}
}

// §15: a body credential the scrub will remove, in any form it removes,
// does not degrade the capture.
func TestBodyCredentialCoveredByItsEncodedForm(t *testing.T) {
	body := "client_secret=tok%21en%201"
	if hasUnscrubbableBodyCredential(body, []string{"tok!en 1"}) {
		t.Fatal("an encoded held value counted as unscrubbable")
	}
	if !hasUnscrubbableBodyCredential(body, nil) {
		t.Fatal("a body credential with nothing to scrub it counted as covered")
	}
}

func TestEncodeQueryValue(t *testing.T) {
	for in, want := range map[string]string{
		"tok!en 1": "tok%21en%201",
		"é":        "%C3%A9",
		"-._~aZ09": "-._~aZ09",
		"a/b?c=d":  "a%2Fb%3Fc%3Dd",
	} {
		if got := encodeQueryValue(in); got != want {
			t.Fatalf("%q: got %q, want %q", in, got, want)
		}
	}
}
