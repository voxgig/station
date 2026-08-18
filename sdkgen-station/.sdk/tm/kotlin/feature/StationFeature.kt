package KOTLINPACKAGE.feature

import com.voxgig.station.Station

import KOTLINPACKAGE.core.Context
import KOTLINPACKAGE.core.FetcherFn

// Binds this SDK to a voxgig/station control surface: registration,
// wire-truth http events, and placeholder credential injection. Thin by
// design - all logic it calls lives in the station library (station
// design 2); kotlin has no station library of its own in v1, so this
// adapter reaches the JAVA library (com.voxgig:station) through ordinary
// JVM interop, exactly as the JVM targets reach sekreto's java port
// (station design 2.2, 9 item 2). Station.featureBinding resolves the
// station from the feature options or the ambient instance, verifies
// wrap position, registers, and plans the credential placement. No
// station open -> null binding, and the feature is an inert no-op
// (station design 3.1).
//
// The one piece that must live here rather than in the library is the
// typed transport wrap: the library cannot see this SDK's generated
// FetcherFn type, so the wrap is installed here and delegates every
// request to Station.transport - policy, copy-on-inject, and the http
// event all happen there (station design 3.3, 5.3).
@Suppress("UNCHECKED_CAST")
class StationFeature : BaseFeature("station", "0.0.1", true) {

  private var station: Station? = null
  private var slug: String? = null

  override fun init(ctx: Context, options: MutableMap<String, Any?>) {
    val st: Station? = Station.from(options)
    if (null == st) {
      return
    }

    // Feature position in client.features IS init order; the library's
    // wrap-position guard reads it (station design 3.3).
    val names = mutableListOf<String>()
    for (f in ctx.client!!.features) {
      names.add(f.name)
    }

    val binding: Map<String, Any?>? = st.featureBinding(
      ctx.client, names, ctx.utility!!.fetcher, ctx.config, ctx.options, options,
    )
    if (null == binding) {
      return
    }

    this.station = st
    this.slug = binding["plugin"] as? String

    val stn: Station = st
    val plug = this.slug
    val inner: FetcherFn = ctx.utility!!.fetcher
    val wrap: FetcherFn = { fctx, fullurl, fetchdef ->
      stn.transport(
        plug, fullurl, fetchdef,
        "live" == fctx.client!!.mode,
        corrOf(fctx),
        Station.Transport { url, def -> inner(fctx, url, def) },
      )
    }
    stn.markTransport(wrap)
    ctx.utility!!.fetcher = wrap
  }

  // Hook bridge (station design 3 item 3): operation semantics correlated
  // with the http events via a per-operation id on the SDK's own ctx.

  override fun prePoint(ctx: Context) {
    val st = this.station ?: return
    val state = linkedMapOf<String, Any?>()
    state["corr"] = st.nextCorr()
    state["start"] = System.currentTimeMillis()
    ctx.out["station\$"] = state
  }

  override fun preDone(ctx: Context) {
    val st = this.station ?: return
    st.opEvent(this.slug, corrOf(ctx), startOf(ctx),
      opEntity(ctx), opName(ctx), outcome(ctx))
  }

  override fun preUnexpected(ctx: Context) {
    val st = this.station ?: return
    st.opEvent(this.slug, corrOf(ctx), startOf(ctx),
      opEntity(ctx), opName(ctx), "unexpected")
  }

  private fun corrOf(ctx: Context): String? {
    val state = ctx.out["station\$"]
    if (state is Map<*, *>) {
      val corr = state["corr"]
      if (corr is String) {
        return corr
      }
    }
    return null
  }

  private fun startOf(ctx: Context): Long? {
    val state = ctx.out["station\$"]
    if (state is Map<*, *>) {
      val start = state["start"]
      if (start is Long) {
        return start
      }
    }
    return null
  }

  private fun opEntity(ctx: Context): String {
    return ctx.op.entity
  }

  private fun opName(ctx: Context): String {
    return ctx.op.name
  }

  private fun outcome(ctx: Context): String {
    val result = ctx.result ?: return "unknown"
    if (null != result.err) {
      return "err"
    }
    if (!result.ok) {
      return "err"
    }
    return "ok"
  }
}
