// swift-tools-version:5.9
//
// voxgig/station - one control surface for outbound integrations (Swift).
//
// The library target has no dependencies at all (station design 10: no
// Swift sekreto port exists yet, so secrets are env-only and even that
// one edge is absent - see Sources/VoxgigStation/Secrets.swift). Only the
// test target depends on voxgig/omni, the shared conformance runner - a
// sibling checkout, not a published package, linked under vendor/ by
// `make vendor` (the rust port's scheme) so this manifest can name a
// fixed path that works on any machine.
import PackageDescription

let package = Package(
  name: "VoxgigStation",
  products: [
    .library(name: "VoxgigStation", targets: ["VoxgigStation"])
  ],
  dependencies: [
    .package(path: "vendor/omni")
  ],
  targets: [
    .target(name: "VoxgigStation", path: "Sources/VoxgigStation"),
    .testTarget(
      name: "VoxgigStationTests",
      dependencies: ["VoxgigStation", "Omni"],
      path: "Tests/VoxgigStationTests"),
  ]
)
