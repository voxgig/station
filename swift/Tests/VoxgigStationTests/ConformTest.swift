// RUN: make test   (or: swift test)
//
// The station conformance suite: the pure-contract half of the design's
// (13) corpus, from spec/station.json, through voxgig/omni - the same
// file every port runs. Sections that need live SDK machinery (inject,
// order, event correlation) live in the consumer end-to-end suites
// against real generated SDKs; the corpus carries what a port can prove
// with no SDK present.
//
// A failing omni check throws OmniError, which XCTest reports as a
// failure (the omni Swift port's own harness contract).

import Foundation
import Omni
import VoxgigStation
import XCTest

typealias OJson = Omni.Json
typealias SJson = VoxgigStation.Json

// The shared spec, from the repo root (this file sits at
// swift/Tests/VoxgigStationTests/).
func specfile() -> String {
  let here = URL(fileURLWithPath: #filePath)
  return here
    .deletingLastPathComponent()  // VoxgigStationTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // swift
    .deletingLastPathComponent()  // station
    .appendingPathComponent("spec/station.json").path
}

// Spec nulls arrive as omni's NULLMARK sentinel; restore them so the
// subjects see what the spec means.
func denull(_ val: OJson) -> OJson {
  if case .str(let text) = val, NULLMARK == text {
    return .null
  }
  if case .list(let items) = val {
    return .list(items.map(denull))
  }
  if case .map(let entries) = val {
    // omni's map is an INSERTION-ORDERED association list, not a Swift
    // Dictionary (Omni/Json.swift): rebuild it in place so the spec's
    // own key order survives the walk.
    return .map(entries.map { ($0.0, denull($0.1)) })
  }
  return val
}

// The omni value model as the station library's Json (absent -> null).
func stationJson(_ val: OJson) -> SJson {
  switch val {
  case .bool(let flag): return .bool(flag)
  case .num(let num): return .num(num)
  case .str(let text): return .str(text)
  case .list(let items): return .list(items.map(stationJson))
  case .map(let entries):
    var out: [String: SJson] = [:]
    for (key, entry) in entries {
      out[key] = stationJson(entry)
    }
    return .map(out)
  default: return .null
  }
}

// And back, for subject results.
func omniJson(_ val: SJson) -> OJson {
  switch val {
  case .null: return .null
  case .bool(let flag): return .bool(flag)
  case .num(let num): return .num(num)
  case .str(let text): return .str(text)
  case .list(let items): return .list(items.map(omniJson))
  case .map(let entries):
    // The station library's map IS a Swift Dictionary and so carries no
    // order; omni's is an association list. Sort by key so what this
    // port hands back is stable from run to run - omni's deepequal is
    // order-independent, but a stable order keeps failure output
    // readable and diffable.
    return .map(entries.keys.sorted().map { ($0, omniJson(entries[$0]!)) })
  }
}

final class ConformTest: XCTestCase {

  func pack() throws -> RunPack {
    return try makeRunner(specfile(), Provider()).runner("station")
  }

  func testSecretname() throws {
    let R = try pack()
    try R.runset(
      R.set("secretname"),
      { args in
        let slug = args[0].get("slug").asstr ?? ""
        let secretname = Descriptor.secretnameDefault(slug)
        return OJson.mapOf([
          ("envtoken", .str(Descriptor.envToken(slug))),
          ("secretname", .str(secretname)),
          ("envkey", .str(SecretBroker.envkey(secretname))),
        ])
      })
  }

  func testPlaceholder() throws {
    let R = try pack()
    try R.runset(
      R.set("placeholder"),
      { args in
        .str(SecretBroker.placeholderFor(args[0].asstr ?? ""))
      })
  }

  func testDescriptor() throws {
    let R = try pack()
    try R.runset(
      R.set("descriptor"),
      { args in
        let (descriptor, _) = Descriptor.normalizeDescriptor(
          stationJson(denull(args[0].get("config"))),
          stationJson(denull(args[0].get("feature"))))
        return omniJson(descriptor)
      })
  }

  func testDescriptorwarnings() throws {
    let R = try pack()
    try R.runset(
      R.set("descriptorwarnings"),
      { args in
        let (_, warnings) = Descriptor.normalizeDescriptor(
          stationJson(denull(args[0].get("config"))),
          stationJson(denull(args[0].get("feature"))))
        return .num(Double(warnings.count))
      })
  }

  func testCanonical() throws {
    let R = try pack()
    try R.runset(
      R.set("canonical"),
      { args in
        .str(Descriptor.canonicalSerialize(stationJson(denull(args[0]))))
      })
  }

  // The 3.3 merge, and the whole of this port's profile contract.
  func testInstance() throws {
    let R = try pack()
    try R.runset(
      R.set("instance"),
      { args in
        let out = try Profile.resolveProfile(
          stationJson(denull(args[0].get("config"))),
          args[0].get("profile").asstr ?? "")
        return omniJson(out)
      })
  }

  func testErrors() throws {
    let R = try pack()
    try R.runset(
      R.set("errors"),
      { args in
        .bool(StationError.isKnownCode(args[0].asstr))
      })
  }
}
