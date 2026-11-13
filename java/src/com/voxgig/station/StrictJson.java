// RFC 8259 JSON, checked strictly before sekreto's reader decodes it. That
// reader never throws and answers whatever it can read, so `{"a": 1,`
// would load as a config; csharp checks with the BCL's JsonDocument for
// the same reason, and java's standard library has no parser to ask.

package com.voxgig.station;

final class StrictJson {
  private static final int MAX_DEPTH = 512;

  private final String text;
  private int at;
  private int depth;

  private StrictJson(String text) {
    this.text = text;
  }

  /** Returns when the text is a JSON value with nothing after it; else throws, saying where. */
  static void check(String text) {
    StrictJson json = new StrictJson(text);
    json.space();
    json.value();
    json.space();
    if (json.at < text.length()) {
      throw json.fail("unexpected text after the value");
    }
  }

  private IllegalArgumentException fail(String what) {
    return new IllegalArgumentException(what + " at offset " + at);
  }

  private boolean next(char c) {
    return at < text.length() && c == text.charAt(at);
  }

  private boolean digit() {
    return at < text.length() && '0' <= text.charAt(at) && '9' >= text.charAt(at);
  }

  private void expect(char c) {
    if (!next(c)) {
      throw fail(at < text.length() ? "expected '" + c + "'" : "unexpected end of text");
    }
    at++;
  }

  private void space() {
    while (next(' ') || next('\t') || next('\n') || next('\r')) {
      at++;
    }
  }

  private void value() {
    if (at >= text.length()) {
      throw fail("unexpected end of text");
    }
    char c = text.charAt(at);
    if ('{' == c || '[' == c) {
      if (MAX_DEPTH < ++depth) {
        throw fail("nested too deeply");
      }
      if ('{' == c) {
        object();
      } else {
        array();
      }
      depth--;
    } else if ('"' == c) {
      string();
    } else if ('-' == c || ('0' <= c && '9' >= c)) {
      number();
    } else if ('t' == c) {
      word("true");
    } else if ('f' == c) {
      word("false");
    } else {
      word("null");
    }
  }

  private void word(String word) {
    if (!text.startsWith(word, at)) {
      throw fail("unexpected character");
    }
    at += word.length();
  }

  private void object() {
    at++;
    space();
    if (next('}')) {
      at++;
      return;
    }
    while (true) {
      space();
      if (!next('"')) {
        throw fail(at < text.length() ? "expected a string key" : "unexpected end of text");
      }
      string();
      space();
      expect(':');
      space();
      value();
      space();
      if (!next(',')) {
        expect('}');
        return;
      }
      at++;
    }
  }

  private void array() {
    at++;
    space();
    if (next(']')) {
      at++;
      return;
    }
    while (true) {
      space();
      value();
      space();
      if (!next(',')) {
        expect(']');
        return;
      }
      at++;
    }
  }

  private void string() {
    at++;
    while (at < text.length()) {
      char c = text.charAt(at++);
      if ('"' == c) {
        return;
      }
      if (0x20 > c) {
        throw fail("unescaped control character in a string");
      }
      if ('\\' == c) {
        escape();
      }
    }
    throw fail("unterminated string");
  }

  private void escape() {
    if (at >= text.length()) {
      throw fail("unterminated string");
    }
    char e = text.charAt(at++);
    if ('u' == e) {
      for (int i = 0; i < 4; i++) {
        if (at >= text.length() || 0 > "0123456789abcdefABCDEF".indexOf(text.charAt(at))) {
          throw fail("bad \\u escape");
        }
        at++;
      }
    } else if (0 > "\"\\/bfnrt".indexOf(e)) {
      throw fail("bad escape");
    }
  }

  private void number() {
    if (next('-')) {
      at++;
    }
    if (next('0')) {
      at++;
    } else if (digit()) {
      while (digit()) {
        at++;
      }
    } else {
      throw fail("expected a digit");
    }
    if (next('.')) {
      at++;
      digits();
    }
    if (next('e') || next('E')) {
      at++;
      if (next('+') || next('-')) {
        at++;
      }
      digits();
    }
  }

  private void digits() {
    if (!digit()) {
      throw fail("expected a digit");
    }
    while (digit()) {
      at++;
    }
  }
}
