package JAVAPACKAGE.feature;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import com.voxgig.station.Station;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.core.Feature;
import JAVAPACKAGE.core.Result;
import JAVAPACKAGE.core.Utility;

// Binds this SDK to a voxgig/station control surface: registration,
// wire-truth http events, and placeholder credential injection. Thin by
// design - all logic it calls lives in the station library (station
// design 2); Station.featureBinding resolves the station from the
// feature options or the ambient instance, verifies wrap position,
// registers, and plans the credential placement. No station open -> null
// binding, and the feature is an inert no-op (station design 3.1).
//
// The one piece that must live here rather than in the library is the
// typed transport wrap: the library cannot see this SDK's generated
// FetcherFn type, so the wrap is installed here and delegates every
// request to Station.transport - policy, copy-on-inject, and the http
// event all happen there (station design 3.3, 5.3).
@SuppressWarnings({"unchecked"})
public class StationFeature extends BaseFeature {

  private Station station;
  private String slug;

  public StationFeature() {
    super("station", "0.0.1", true);
  }

  @Override
  public void init(Context ctx, Map<String, Object> options) {
    Station st = Station.from(options);
    if (null == st) {
      return;
    }

    // Feature position in client.features IS init order; the library's
    // wrap-position guard reads it (station design 3.3).
    List<String> names = new ArrayList<>();
    for (Feature f : ctx.client.features) {
      names.add(f.getName());
    }

    Map<String, Object> binding = st.featureBinding(ctx.client, names,
        ctx.utility.fetcher, ctx.config, ctx.options, options);
    if (null == binding) {
      return;
    }

    this.station = st;
    this.slug = (String) binding.get("plugin");

    final Station stn = st;
    final String plug = this.slug;
    final Utility.FetcherFn inner = ctx.utility.fetcher;
    Utility.FetcherFn wrap = (fctx, fullurl, fetchdef) -> stn.transport(
        plug, fullurl, fetchdef,
        "live".equals(fctx.client.mode),
        corrOf(fctx),
        (url, def) -> inner.fetch(fctx, url, def));
    stn.markTransport(wrap);
    ctx.utility.fetcher = wrap;
  }

  // Hook bridge (station design 3 item 3): operation semantics correlated
  // with the http events via a per-operation id on the SDK's own ctx.

  @Override
  public void prePoint(Context ctx) {
    if (null == this.station) {
      return;
    }
    Map<String, Object> state = new LinkedHashMap<>();
    state.put("corr", this.station.nextCorr());
    state.put("start", System.currentTimeMillis());
    ctx.out.put("station$", state);
  }

  @Override
  public void preDone(Context ctx) {
    if (null == this.station) {
      return;
    }
    this.station.opEvent(this.slug, corrOf(ctx), startOf(ctx),
        opEntity(ctx), opName(ctx), outcome(ctx));
  }

  @Override
  public void preUnexpected(Context ctx) {
    if (null == this.station) {
      return;
    }
    this.station.opEvent(this.slug, corrOf(ctx), startOf(ctx),
        opEntity(ctx), opName(ctx), "unexpected");
  }

  private static String corrOf(Context ctx) {
    Object state = ctx.out.get("station$");
    if (state instanceof Map) {
      Object corr = ((Map<String, Object>) state).get("corr");
      if (corr instanceof String) {
        return (String) corr;
      }
    }
    return null;
  }

  private static Long startOf(Context ctx) {
    Object state = ctx.out.get("station$");
    if (state instanceof Map) {
      Object start = ((Map<String, Object>) state).get("start");
      if (start instanceof Long) {
        return (Long) start;
      }
    }
    return null;
  }

  private static String opEntity(Context ctx) {
    if (null != ctx.op) {
      return ctx.op.entity;
    }
    return null == ctx.entity ? "" : ctx.entity.getName();
  }

  private static String opName(Context ctx) {
    return null == ctx.op ? "" : ctx.op.name;
  }

  private static String outcome(Context ctx) {
    Result result = ctx.result;
    if (null == result) {
      return "unknown";
    }
    if (null != result.err) {
      return "err";
    }
    if (!result.ok) {
      return "err";
    }
    return "ok";
  }
}
