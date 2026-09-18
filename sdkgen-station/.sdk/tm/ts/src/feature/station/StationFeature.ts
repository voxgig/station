
import type { Context, FeatureOptions } from '../../types'

import { BaseFeature } from '../base/BaseFeature'

import { featureBinding } from '@voxgig/station'


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
