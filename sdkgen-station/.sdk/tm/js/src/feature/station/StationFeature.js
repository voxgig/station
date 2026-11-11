const { BaseFeature } = require('../base/BaseFeature')


// Binds this SDK to a voxgig/station control surface: registration,
// wire-truth http events, and placeholder credential injection. Thin by
// design - all logic it calls lives in the station library (station
// design §2); featureBinding resolves the station from the feature
// options or the ambient instance, verifies wrap position, registers,
// and wraps the transport. No station open -> null binding, and the
// feature is an inert no-op (station design §3.1).
class StationFeature extends BaseFeature {
  version = '0.0.1'
  name = 'station'
  active = true

  _binding = null


  // Loaded here rather than at module load: init runs only for an active
  // feature, so an SDK that is never bound loads without station installed.
  init(ctx, options) {
    const { featureBinding } = require('@voxgig/station-js')
    this._binding = featureBinding(ctx, options)
  }


  PrePoint(ctx) {
    if (null != this._binding) {
      this._binding.PrePoint(ctx)
    }
  }

  PreDone(ctx) {
    if (null != this._binding) {
      this._binding.PreDone(ctx)
    }
  }

  PreUnexpected(ctx) {
    if (null != this._binding) {
      this._binding.PreUnexpected(ctx)
    }
  }
}


module.exports = {
  StationFeature
}
