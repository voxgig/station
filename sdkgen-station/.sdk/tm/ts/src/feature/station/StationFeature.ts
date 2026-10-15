
import type { Context, FeatureOptions } from '../../types'

import { BaseFeature } from '../base/BaseFeature'

import type { featureBinding } from '@voxgig/station'


class StationFeature extends BaseFeature {
  version = '0.0.1'
  name = 'station'
  active = true

  _binding: ReturnType<typeof featureBinding> = null


  // Loaded here rather than at module load: init runs only for an active
  // feature, so an SDK that is never bound loads without station installed.
  init(ctx: Context, options: FeatureOptions): void | Promise<any> {
    const station: { featureBinding: typeof featureBinding } = require('@voxgig/station')
    this._binding = station.featureBinding(ctx, options)
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
