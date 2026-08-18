
import type { Context, FeatureOptions } from '../../types'

import { BaseFeature } from '../base/BaseFeature'

import { featureBinding } from '@voxgig/station'


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

  _binding: ReturnType<typeof featureBinding> = null


  init(ctx: Context, options: FeatureOptions): void | Promise<any> {
    this._binding = featureBinding(ctx, options)
  }


  PrePoint(this: any, ctx: any) {
    if (null != this._binding) {
      this._binding.PrePoint(ctx)
    }
  }

  PreDone(this: any, ctx: any) {
    if (null != this._binding) {
      this._binding.PreDone(ctx)
    }
  }

  PreUnexpected(this: any, ctx: any) {
    if (null != this._binding) {
      this._binding.PreUnexpected(ctx)
    }
  }
}


export {
  StationFeature
}
