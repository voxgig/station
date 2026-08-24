// RUN: make test   (or: swift test)
//
// Focused unit cases: the station mechanics the corpus cannot reach
// without an SDK - the event ring, the env-only broker's miss-vs-error
// and floor-less scrub, the binding guards, and the transport
// middleware's injection plan (the copy-on-inject CLONE itself is the
// generated adapter's one physical duty, exercised in the consumer
// end-to-end flow; what these cases pin is that the caller's header map
// is never mutated and only the sent set carries the value).

import Foundation
import VoxgigStation
import XCTest

#if canImport(Glibc)
  import Glibc
#endif

// A station over an in-memory profile, isolated from the ambient
// instance and from any station.json on disk. Secrets ride the process
// environment - the env provider is the only one this port has (station
// design 2.2).
func memStation(_ plugin: SJson? = nil, proxy: String? = nil) throws -> Station {
  var profile: [String: SJson] = [
    "secrets": .map(["providers": .list([.map(["kind": .str("env")])])])
  ]
  if let plugin = plugin {
    profile["sdk"] = plugin
  }
  var opts: [String: SJson] = [
    "config": .map([
      "station": .num(1),
      "profiles": .map(["default": .map(profile)]),
    ])
  ]
  if let proxy = proxy {
    opts["proxy"] = .str(proxy)
  }
  return try Station(.map(opts))
}

// The embedded-config shape a generated SDK carries, small.
func sdkConfig(_ name: String, _ slug: String?) -> SJson {
  var main: [String: SJson] = ["name": .str(name)]
  if let slug = slug {
    main["slug"] = .str(slug)
    main["version"] = .str("0.0.1")
    main["target"] = .str("swift")
  }
  return .map([
    "main": .map(main),
    "feature": .map(["test": .map([:])]),
    "options": .map([
      "base": .str("http://localhost:8000"),
      "auth": .map(["prefix": .str("")]),
      "entity": .map(["todo": .map([:])]),
    ]),
    "entity": .map([
      "todo": .map([
        "name": .str("todo"),
        "fields": .list([.map(["name": .str("title"), "kind": .str("String")])]),
        "op": .map([
          "list": .map([
            "points": .list([
              .map([
                "method": .str("GET"),
                "orig": .str("/api/todo"),
                "parts": .list([.str("api"), .str("todo")]),
              ])
            ])
          ])
        ]),
      ])
    ]),
  ])
}

@discardableResult
func bind(
  _ st: Station, _ client: AnyObject,
  _ featureOpts: SJson = .map([:]),
  _ residentApikey: String = "",
  _ featureNames: [String] = ["station"]
) throws -> Bound? {
  return try st.featureBinding(
    client, featureNames, sdkConfig("TestPlug", "test-plug"),
    .map([:]), featureOpts, residentApikey)
}

func hasWarn(_ st: Station, _ needle: String) -> Bool {
  for ev in st.events() {
    if let warn = ev.get("meta").get("warn").asStr, warn.contains(needle) {
      return true
    }
  }
  return false
}

final class StationTest: XCTestCase {

  override func setUp() {
    super.setUp()
    Station.reset()
    unsetenv("TEST_PLUG_APIKEY")
  }

  override func tearDown() {
    Station.reset()
    unsetenv("TEST_PLUG_APIKEY")
    super.tearDown()
  }

  func testEventsRingOverflowDropsOldestCounted() {
    let buffer = EventBuffer(2)
    buffer.emit(.map(["t": .num(1), "kind": .str("station")]))
    buffer.emit(.map(["t": .num(2), "kind": .str("station")]))
    buffer.emit(.map(["t": .num(3), "kind": .str("station")]))
    let events = buffer.events()
    XCTAssertEqual(2, events.count, "ring bounded")
    XCTAssertEqual(2, events[0].get("t").asNum, "oldest dropped")
    XCTAssertEqual(1, buffer.status().get("dropped").asNum, "drop counted")
  }

  func testEventsTapUnsubscribes() {
    let buffer = EventBuffer()
    var seen = 0
    let off = buffer.tap { _ in seen += 1 }
    buffer.emit(.map(["kind": .str("station")]))
    XCTAssertEqual(1, seen, "tap saw the event")
    off()
    buffer.emit(.map(["kind": .str("station")]))
    XCTAssertEqual(1, seen, "unsubscribed")
  }

  func testBrokerEnvResolveMissAndFloorlessScrub() throws {
    setenv("A_APIKEY", "xy", 1)
    defer { unsetenv("A_APIKEY") }

    let broker = SecretBroker(.list([.map(["kind": .str("env")])]))
    XCTAssertEqual("xy", try broker.value("a", "a.apikey"), "resolves from env")
    // Exact-value scrub, even below sekreto's four-character floor.
    XCTAssertEqual("k=[redacted];", broker.scrub("k=xy;"), "floor-less scrub")

    do {
      _ = try broker.value("b", "b.apikey")
      XCTFail("miss should throw")
    } catch let err as StationError {
      XCTAssertEqual("station_secret_no_value", err.code, "miss code")
    }
  }

  func testBrokerRefusesNonEnvProviderKinds() {
    // Env-only honesty (design 2.2/5.2): a store this port cannot answer
    // from is an ERROR, never a fall-through to a weaker store.
    let broker = SecretBroker(
      .list([
        .map(["kind": .str("hashicorp"), "addr": .str("https://v")]),
        .map(["kind": .str("env")]),
      ]))
    do {
      _ = try broker.value("a", "a.apikey")
      XCTFail("non-env provider must refuse")
    } catch let err as StationError {
      XCTAssertEqual("station_secret_error", err.code, "refusal code")
      XCTAssertTrue(err.message.contains("no swift sekreto port"), "says so")
    } catch {
      XCTFail("unexpected error type")
    }
    XCTAssertEqual(["hashicorp"], broker.unsupportedKinds(), "kinds listed")
  }

  func testBrokerRefreshDropsCacheKeepsHoisted() throws {
    setenv("A_APIKEY", "one", 1)
    defer { unsetenv("A_APIKEY") }

    let broker = SecretBroker(.null)
    XCTAssertEqual("one", try broker.value("a", "a.apikey"))
    setenv("A_APIKEY", "two", 1)
    XCTAssertEqual("one", try broker.value("a", "a.apikey"), "cached")
    broker.refresh()
    XCTAssertEqual("two", try broker.value("a", "a.apikey"), "re-resolved")

    broker.hoist("h", "hoisted")
    broker.refresh()
    XCTAssertEqual("hoisted", try broker.value("h", "h.apikey"), "override survives")
  }

  func testOpenIdempotentAmbientConflictingReopenFails() throws {
    Station.reset()
    defer { Station.reset() }

    let one = try Station.open(.map(["config": .null]))
    XCTAssertTrue(one === (try Station.open(.map(["config": .null]))), "same instance")
    XCTAssertTrue(one === Station.current(), "current() is the ambient")

    do {
      _ = try Station.open(.map(["config": .null, "profile": .str("prod")]))
      XCTFail("conflicting open must fail")
    } catch let err as StationError {
      XCTAssertEqual("station_open_conflict", err.code, "conflict code")
    }

    one.close()
    XCTAssertNil(Station.current(), "close() of the ambient resets it")
  }

  func testOptionsActivationEntryCarriesHandle() throws {
    let st = try memStation()
    let options = st.options(["base": "http://x:1"])
    let fmap = options["feature"] as? [String: Any?]
    let entry = fmap?["station"] as? [String: Any?]
    XCTAssertEqual(true, entry?["active"] as? Bool, "active")
    XCTAssertTrue(st === (entry?["station"] as? Station), "handle rides the options")
    XCTAssertEqual("http://x:1", options["base"] as? String, "caller opts kept")
    XCTAssertNotNil(entry?["calleropts"] as? [String: Any?], "calleropts marker")
  }

  func testBindingRegistersPlantsPlaceholderHoistsResident() throws {
    setenv("TEST_PLUG_APIKEY", "real-key-1", 1)
    let st = try memStation()
    let client = NSObject()

    let bound = try bind(st, client, .map(["calleropts": .map([:])]), "resident-key")
    XCTAssertEqual("test-plug", bound?.binding.slug, "slug")
    XCTAssertEqual("[station:test-plug]", bound?.placeholder, "placeholder planned")
    XCTAssertTrue(hasWarn(st, "hoisted"), "hoist warning emitted")
    XCTAssertEqual("x [redacted] y", st.redact("x resident-key y"), "hoisted value scrubbed")

    var sawConstruct = false
    for ev in st.events() where "construct" == ev.get("kind").asStr {
      sawConstruct = true
      XCTAssertEqual("test-plug", ev.get("plugin").asStr)
      XCTAssertEqual("R1", ev.get("meta").get("rung").asStr)
    }
    XCTAssertTrue(sawConstruct, "construct event emitted")

    // Same client, second arrival: inert.
    XCTAssertNil(try bind(st, client), "idempotent per client")

    // A second client of the same SDK: refused.
    do {
      _ = try bind(st, NSObject())
      XCTFail("second client must fail")
    } catch let err as StationError {
      XCTAssertEqual("station_bound_twice", err.code, "bound twice code")
    }
  }

  func testBindingWrongWrapPositionFailsLoudly() throws {
    let st = try memStation()
    do {
      _ = try bind(st, NSObject(), .map([:]), "", ["test", "retry", "station"])
      XCTFail("order guard must trip")
    } catch let err as StationError {
      XCTAssertEqual("station_wrap_order", err.code, "order code")
    }
  }

  func testBindingInertBaseEntriesAreSkippedByGuard() throws {
    // The generated makeFeature's default case absorbs an unknown
    // activation name as an inert BaseFeature (name "base") - it
    // occupies a features slot but never wraps the transport, so the
    // position guard must tolerate it wherever it sits.
    let st = try memStation()
    let bound = try bind(st, NSObject(), .map([:]), "", ["test", "base", "station"])
    XCTAssertNotNil(bound, "stray base between test and station tolerated")
  }

  func testBindingProfileBaseOnlyWithoutCallerBase() throws {
    let st = try memStation(.map(["test-plug": .map(["base": .str("http://profile:9")])]))
    let bound = try bind(st, NSObject(), .map(["calleropts": .map([:])]))
    XCTAssertEqual("http://profile:9", bound?.base, "profile base handed back")

    let st2 = try memStation(.map(["test-plug": .map(["base": .str("http://profile:9")])]))
    let bound2 = try bind(
      st2, NSObject(), .map(["calleropts": .map(["base": .str("http://caller:1")])]))
    XCTAssertNil(bound2?.base, "caller base wins")
  }

  func testTransportInjectsOnlyTheSentSet() throws {
    setenv("TEST_PLUG_APIKEY", "real-key-2", 1)
    let st = try memStation()
    let bound = try bind(st, NSObject())
    let binding = bound!.binding

    binding.opStart("ctx1")

    let headers = ["authorization": "[station:test-plug]"]
    var sent: String? = nil
    let res: [String: Any] = try binding.transport(
      "ctx1", true, "http://localhost:8000/api/todo", "GET", headers,
      { injected, _ in
        sent = injected?["authorization"]
        return ["status": 200]
      },
      { _ in (200, 12) })

    XCTAssertEqual("real-key-2", sent, "real value on the wire")
    XCTAssertEqual("[station:test-plug]", headers["authorization"],
      "caller's header map keeps the placeholder")
    XCTAssertEqual(200, res["status"] as? Int, "response returned")

    var http: SJson? = nil
    for ev in st.events() where "http" == ev.get("kind").asStr {
      http = ev
    }
    XCTAssertNotNil(http, "http event emitted")
    XCTAssertEqual(binding.corrOf("ctx1"), http?.get("corr").asStr, "correlated")
    XCTAssertEqual(200, http?.get("http").get("status").asNum, "wire status")
    XCTAssertEqual(12, http?.get("http").get("bytes").asNum, "bytes")
    XCTAssertEqual("localhost:8000", http?.get("http").get("host").asStr, "host")
    XCTAssertEqual("/api/todo", http?.get("http").get("path").asStr, "path")

    binding.opDone("ctx1", "todo", "list", "ok")
    var op: SJson? = nil
    for ev in st.events() where "op" == ev.get("kind").asStr {
      op = ev
    }
    XCTAssertEqual("ok", op?.get("op").get("outcome").asStr, "op event outcome")
    XCTAssertNotNil(op?.get("corr").asStr, "op event correlated")
    XCTAssertNil(binding.corrOf("ctx1"), "correlation closed")
  }

  func testTransportNoInjectionIntoMocks() throws {
    setenv("TEST_PLUG_APIKEY", "real-key-3", 1)
    let st = try memStation()
    let binding = (try bind(st, NSObject()))!.binding

    var sawInjected = false
    _ = try binding.transport(
      nil, false, "http://localhost:8000/api/todo", "GET",
      ["authorization": "[station:test-plug]"],
      { injected, _ in
        sawInjected = nil != injected
        return true
      },
      { _ in (200, 0) })
    XCTAssertFalse(sawInjected, "placeholder rides through untouched in mock mode")
  }

  func testTransportMissingSecretFailsTheOpWithCode() throws {
    let st = try memStation()
    let binding = (try bind(st, NSObject()))!.binding

    do {
      _ = try binding.transport(
        nil, true, "http://localhost:8000/api/todo", "GET", [:],
        { _, _ in true }, { _ in (200, 0) })
      XCTFail("missing secret must throw")
    } catch let err as StationError {
      XCTAssertEqual("station_secret_no_value", err.code, "miss code")
    }

    var recorded = false
    for ev in st.events() where "error" == ev.get("kind").asStr {
      recorded = recorded
        || "station_secret_no_value" == ev.get("err").get("code").asStr
    }
    XCTAssertTrue(recorded, "error event recorded")
  }

  func testTransportHostsPolicyDeniesOffListLiveOnly() throws {
    setenv("TEST_PLUG_APIKEY", "k", 1)
    let st = try memStation(
      .map([
        "test-plug": .map([
          "policy": .map(["hosts": .list([.str("api.good.example")])])
        ])
      ]))
    let binding = (try bind(st, NSObject()))!.binding

    do {
      _ = try binding.transport(
        nil, true, "http://evil.example/x", "GET", [:],
        { _, _ in true }, { _ in (200, 0) })
      XCTFail("off-list host must be denied")
    } catch let err as StationError {
      XCTAssertEqual("station_host_allow", err.code, "host code")
    }

    // A mock-transport call is not egress; the policy does not fire.
    let ok: Bool = try binding.transport(
      nil, false, "http://evil.example/x", "GET", [:],
      { _, _ in true }, { _ in (200, 0) })
    XCTAssertTrue(ok, "mock path unaffected")
  }

  func testTransportManualRedirectUnderHostsPolicy() throws {
    setenv("TEST_PLUG_APIKEY", "k", 1)
    let st = try memStation(
      .map([
        "test-plug": .map([
          "policy": .map(["hosts": .list([.str("api.good.example")])])
        ])
      ]))
    let binding = (try bind(st, NSObject()))!.binding

    var manual = false
    _ = try binding.transport(
      nil, true, "http://api.good.example/x", "GET", [:],
      { _, manualRedirect in
        manual = manualRedirect
        return true
      },
      { _ in (200, 0) })
    XCTAssertTrue(manual, "redirect: manual instructed under a hosts policy")
  }

  func testTransportRequireProxyFailsClosedOnOperationPath() throws {
    let st = try memStation(nil, proxy: "require")
    let binding = (try bind(st, NSObject()))!.binding

    do {
      _ = try binding.transport(
        nil, true, "http://localhost:1/x", "GET", [:],
        { _, _ in true }, { _ in (200, 0) })
      XCTFail("require must fail traffic")
    } catch let err as StationError {
      XCTAssertEqual("station_no_proxy", err.code, "no proxy code")
    }
  }

  func testEnvOnlyChainIsSaidAtConstruction() throws {
    let st = try Station(
      .map([
        "config": .map([
          "station": .num(1),
          "profiles": .map([
            "default": .map([
              "secrets": .map([
                "providers": .list([
                  .map(["kind": .str("hashicorp"), "addr": .str("https://v")])
                ])
              ])
            ])
          ]),
        ])
      ]))
    XCTAssertTrue(hasWarn(st, "no swift sekreto port"), "env-only chain said at construction")
  }

  func testCloseWarnsUnmatchedProfilePluginKeys() throws {
    let st = try memStation(.map(["typoed": .map(["base": .str("http://x")])]))
    st.close()
    XCTAssertTrue(hasWarn(st, "matched no registered plugin"), "typo'd key warned")
  }

  func testDescriptorSurface() throws {
    let st = try memStation()
    _ = try bind(st, NSObject())

    let descriptor = try st.descriptorOf("test-plug")
    XCTAssertEqual("TEST_PLUG", descriptor.get("envtoken").asStr)
    XCTAssertTrue(
      (try st.canonicalDescriptor("test-plug")).contains("\"slug\":\"test-plug\""))

    XCTAssertEqual(1, st.plugins().count, "registry queryable")
    XCTAssertEqual("solo", st.status().get("mode").asStr, "solo mode")

    do {
      _ = try st.descriptorOf("nope")
      XCTFail("unknown plugin must fail")
    } catch let err as StationError {
      XCTAssertEqual("station_no_plugin", err.code)
      XCTAssertTrue(err.message.contains("test-plug"), "candidates listed")
    }
  }
}
