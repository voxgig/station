// swift-tools-version:5.9
//
// voxgig/station - one control surface for outbound integrations (Swift).
//
// The library target has no dependencies at all (station design §10: no
// Swift sekreto port exists yet, so secrets are env-only and even that
// one edge is absent - see Sources/VoxgigStation/Secrets.swift). Only the
// test target depends on voxgig/omni, the shared conformance runner - a
// sibling checkout, not a published package, linked at vendor/omni by
// `make vendor` (the rust port's scheme) so this manifest can name a
// fixed path that works on any machine.
import Foundation
import PackageDescription

// omni is declared ONLY when the link is actually there, so a checkout
// with no omni beside it still builds the library: `swift build` does not
// build test targets, and with the dependency absent from the manifest
// there is nothing to resolve. That is omni register 4.13 - nothing this
// package ships may name omni - and it is the same proof the go and rust
// ports carry as `make build-clean`. Without the guard, resolution fails
// before a single file compiles, on a dependency only the tests use.
// (voxgig/struct's swift port sets this shape.)
//
// The identity is pinned with `name:` rather than left to be derived from
// the path's last component. Both work here, but naming it means the
// `.product(package:)` below cannot drift if the link is ever moved or
// renamed - and it matches how voxgig/struct declares the same runner.
let omniLink = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .appendingPathComponent("vendor/omni").path

let omniPath: String? =
  FileManager.default.fileExists(atPath: omniLink + "/Package.swift") ? omniLink : nil

let package = Package(
  name: "VoxgigStation",
  products: [
    .library(name: "VoxgigStation", targets: ["VoxgigStation"])
  ],
  dependencies: nil == omniPath
    ? []
    : [.package(name: "VoxgigOmni", path: omniPath!)],
  targets: [
    .target(name: "VoxgigStation", path: "Sources/VoxgigStation"),
    .testTarget(
      name: "VoxgigStationTests",
      dependencies: nil == omniPath
        ? ["VoxgigStation"]
        : ["VoxgigStation", .product(name: "Omni", package: "VoxgigOmni")],
      path: "Tests/VoxgigStationTests"),
  ]
)
