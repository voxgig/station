// The station JSON value model, with a small in-tree parser.
//
// The library reads station.json and normalizes embedded SDK configs, and
// must add no third-party dependencies (station design 10), so it carries
// its own JSON support. A hand-written model also keeps booleans and
// numbers distinct, which Foundation's NSNumber bridge does not guarantee
// on every platform - the same reason the omni Swift port carries one.

import Foundation

/// A JSON value. There is no `absent` case: the library's data is always
/// concrete JSON; "no value" is a missing map key, read back as `.null`.
public indirect enum Json {
  case null
  case bool(Bool)
  case num(Double)
  case str(String)
  case list([Json])
  case map([String: Json])

  public var isNull: Bool {
    if case .null = self { return true }
    return false
  }

  public var isMap: Bool {
    if case .map = self { return true }
    return false
  }

  public var asBool: Bool? {
    if case .bool(let val) = self { return val }
    return nil
  }

  public var asNum: Double? {
    if case .num(let val) = self { return val }
    return nil
  }

  public var asStr: String? {
    if case .str(let val) = self { return val }
    return nil
  }

  public var asList: [Json]? {
    if case .list(let val) = self { return val }
    return nil
  }

  public var asMap: [String: Json]? {
    if case .map(let val) = self { return val }
    return nil
  }

  /// Read a map entry; `.null` when missing or not a map.
  public func get(_ key: String) -> Json {
    if case .map(let entries) = self, let entry = entries[key] {
      return entry
    }
    return .null
  }

  /// Is a map key present at all (even holding null)?
  public func has(_ key: String) -> Bool {
    if case .map(let entries) = self {
      return nil != entries[key]
    }
    return false
  }

  /// A non-empty string entry, or nil.
  public func text(_ key: String) -> String? {
    if let text = get(key).asStr, !text.isEmpty {
      return text
    }
    return nil
  }

  // ---- parsing (for station.json; strict JSON) ----

  public static func parse(_ text: String) throws -> Json {
    var chars = Array(text)
    var pos = 0

    skipws(chars, &pos)
    let val = try parseval(&chars, &pos)
    skipws(chars, &pos)

    if pos < chars.count {
      throw JsonError("station: trailing JSON content at \(pos)")
    }

    return val
  }

  private static func skipws(_ chars: [Character], _ pos: inout Int) {
    while pos < chars.count {
      let ch = chars[pos]
      if " " == ch || "\t" == ch || "\n" == ch || "\r" == ch {
        pos += 1
      } else {
        break
      }
    }
  }

  private static func parseval(_ chars: inout [Character], _ pos: inout Int) throws -> Json {
    guard pos < chars.count else {
      throw JsonError("station: unexpected end of JSON")
    }

    switch chars[pos] {
    case "{": return try parsemap(&chars, &pos)
    case "[": return try parselist(&chars, &pos)
    case "\"": return .str(try parsestr(&chars, &pos))
    case "t":
      try parseword(chars, &pos, "true")
      return .bool(true)
    case "f":
      try parseword(chars, &pos, "false")
      return .bool(false)
    case "n":
      try parseword(chars, &pos, "null")
      return .null
    default: return try parsenum(chars, &pos)
    }
  }

  private static func parseword(_ chars: [Character], _ pos: inout Int, _ word: String) throws {
    for expect in word {
      guard pos < chars.count, chars[pos] == expect else {
        throw JsonError("station: bad JSON literal at \(pos)")
      }
      pos += 1
    }
  }

  private static func parsemap(_ chars: inout [Character], _ pos: inout Int) throws -> Json {
    var out: [String: Json] = [:]
    pos += 1  // {

    skipws(chars, &pos)
    if pos < chars.count, "}" == chars[pos] {
      pos += 1
      return .map(out)
    }

    while true {
      skipws(chars, &pos)
      let key = try parsestr(&chars, &pos)
      skipws(chars, &pos)

      guard pos < chars.count, ":" == chars[pos] else {
        throw JsonError("station: expected ':' at \(pos)")
      }
      pos += 1

      skipws(chars, &pos)
      out[key] = try parseval(&chars, &pos)
      skipws(chars, &pos)

      guard pos < chars.count else {
        throw JsonError("station: unterminated JSON object")
      }
      if "," == chars[pos] {
        pos += 1
        continue
      }
      if "}" == chars[pos] {
        pos += 1
        return .map(out)
      }
      throw JsonError("station: expected ',' or '}' at \(pos)")
    }
  }

  private static func parselist(_ chars: inout [Character], _ pos: inout Int) throws -> Json {
    var out: [Json] = []
    pos += 1  // [

    skipws(chars, &pos)
    if pos < chars.count, "]" == chars[pos] {
      pos += 1
      return .list(out)
    }

    while true {
      skipws(chars, &pos)
      out.append(try parseval(&chars, &pos))
      skipws(chars, &pos)

      guard pos < chars.count else {
        throw JsonError("station: unterminated JSON array")
      }
      if "," == chars[pos] {
        pos += 1
        continue
      }
      if "]" == chars[pos] {
        pos += 1
        return .list(out)
      }
      throw JsonError("station: expected ',' or ']' at \(pos)")
    }
  }

  private static func parsestr(_ chars: inout [Character], _ pos: inout Int) throws -> String {
    guard pos < chars.count, "\"" == chars[pos] else {
      throw JsonError("station: expected string at \(pos)")
    }
    pos += 1

    var out = ""

    while pos < chars.count {
      let ch = chars[pos]
      pos += 1

      if "\"" == ch {
        return out
      }

      if "\\" != ch {
        out.append(ch)
        continue
      }

      guard pos < chars.count else { break }

      let escape = chars[pos]
      pos += 1

      switch escape {
      case "\"": out.append("\"")
      case "\\": out.append("\\")
      case "/": out.append("/")
      case "b": out.append("\u{8}")
      case "f": out.append("\u{c}")
      case "n": out.append("\n")
      case "r": out.append("\r")
      case "t": out.append("\t")
      case "u":
        guard pos + 4 <= chars.count else {
          throw JsonError("station: bad JSON unicode escape")
        }
        let hex = String(chars[pos..<(pos + 4)])
        pos += 4
        guard let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) else {
          throw JsonError("station: bad JSON unicode escape")
        }
        out.append(Character(scalar))
      default:
        throw JsonError("station: bad JSON escape at \(pos)")
      }
    }

    throw JsonError("station: unterminated JSON string")
  }

  private static func parsenum(_ chars: [Character], _ pos: inout Int) throws -> Json {
    let start = pos

    if pos < chars.count, "-" == chars[pos] {
      pos += 1
    }

    while pos < chars.count {
      let ch = chars[pos]
      if ch.isNumber || "." == ch || "e" == ch || "E" == ch || "-" == ch || "+" == ch {
        pos += 1
      } else {
        break
      }
    }

    let span = String(chars[start..<pos])
    guard let val = Double(span) else {
      throw JsonError("station: bad JSON number [\(span)] at \(start)")
    }

    return .num(val)
  }
}
