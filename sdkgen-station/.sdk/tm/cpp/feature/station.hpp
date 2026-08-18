// ProjectName SDK — station feature: binds this SDK to a voxgig/station
// control surface (registration, wire-truth http events, placeholder
// credential injection). Thin by design - all logic it calls lives in
// the station library (station design 2); vstation::feature_binding
// resolves the ambient station, verifies wrap position, registers, and
// wraps the transport. No station open -> null binding, and the feature
// is an inert no-op (station design 3.1).
//
// The station library rides VENDORED beside this file, at
// feature/station/voxgig_station.hpp - the C++ SDK is header-only and
// registry-less, so there is no manifest to declare a dependency in
// (the SDK's own struct library is vendored the same way, at
// utility/voxgigstruct/). Its canonical source is the voxgig/station
// repo's cpp/ port; the copy here is refreshed by the sdkgen-station
// package, so never edit it in a generated project (add is overwrite).
//
// Binding is the inverted form only (station design 3.1):
//
//   auto st = vstation::Station::open();
//   ProjectNameSDK sdk(st->options());
//
// The C++ target wires no options.extend seam, so connect()/adopt() do
// not exist here; regeneration with this feature is the only retrofit,
// and the feature binds to the AMBIENT station (a C++ options Value
// cannot carry an instance handle).

#ifndef SDK_FEATURE_STATION_HPP
#define SDK_FEATURE_STATION_HPP

#include <memory>
#include <string>

#include "../core/types.hpp"
#include "base.hpp"
#include "station/voxgig_station.hpp"

namespace sdk {

class StationFeature : public BaseFeature {
public:
  std::shared_ptr<vstation::FeatureBinding> binding;

  StationFeature() : BaseFeature("station", "0.0.1", true) {}

  void init(CtxPtr ctx, const Value& options_) override {
    binding = vstation::feature_binding(ctx, options_);
  }

  // Hook bridge (station design 3 item 3): operation semantics
  // correlated with the HTTP events via the per-op id on the SDK's own
  // ctx.
  void prePoint(CtxPtr ctx) override {
    if (binding) binding->PrePoint(ctx);
  }

  void preDone(CtxPtr ctx) override {
    if (binding) binding->PreDone(ctx);
  }

  void preUnexpected(CtxPtr ctx) override {
    if (binding) binding->PreUnexpected(ctx);
  }
};

} // namespace sdk

#endif // SDK_FEATURE_STATION_HPP
