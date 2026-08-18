// Binds this SDK to a voxgig/station control surface: registration,
// wire-truth http events, and placeholder credential injection. Thin by
// design - all logic it calls lives in the station library (station
// design 2); Station.FeatureBinding resolves the station from the
// feature options or the ambient instance, verifies wrap position,
// registers, and plans the credential placement. No station open -> null
// binding, and the feature is an inert no-op (station design 3.1).
//
// The one piece that must live here rather than in the library is the
// typed transport wrap: the library cannot see this SDK's generated
// FetcherFunc type, so the wrap is installed here and delegates every
// request to Station.Transport - policy, copy-on-inject, and the http
// event all happen there (station design 3.3, 5.3). The per-operation
// correlation id rides ctx.Meta (this SDK's Context has no dynamic
// property bag), planted by PrePoint and read back by the wrap and the
// op-event hooks.

using Voxgig.Station;

namespace ProjectNameSdk.Feature;

public class StationFeature : BaseFeature
{
    private Station? _station;
    private string _slug = "";

    public StationFeature()
    {
        Version = "0.0.1";
        Name = "station";
        Active = true;
    }

    public override void Init(Context ctx, Dictionary<string, object?> options)
    {
        var st = Station.From(options);
        if (st == null)
        {
            return;
        }

        // Feature position in client.Features IS init order; the library's
        // wrap-position guard reads it (station design 3.3), skipping the
        // inert BaseFeature slots MakeFeature's default case leaves behind.
        var names = new List<string>();
        foreach (var f in ctx.Client!.Features)
        {
            names.Add(f.GetName());
        }

        var binding = st.FeatureBinding(ctx.Client, names, ctx.Utility!.Fetcher,
            ctx.Config, ctx.Options, options);
        if (binding == null)
        {
            return;
        }

        _station = st;
        _slug = binding["plugin"] as string ?? "";

        var stn = st;
        var plug = _slug;
        var inner = ctx.Utility.Fetcher;
        FetcherFunc wrap = (fctx, fullurl, fetchdef) => stn.Transport(
            plug, fullurl, fetchdef,
            fctx.Client!.Mode == "live",
            CorrOf(fctx),
            (url, def) => inner(fctx, url, def));
        stn.MarkTransport(wrap);
        ctx.Utility.Fetcher = wrap;
    }

    // Hook bridge (station design 3 item 3): operation semantics correlated
    // with the http events via a per-operation id on the SDK's own ctx.

    public override void PrePoint(Context ctx)
    {
        if (_station == null)
        {
            return;
        }
        ctx.Meta["station$"] = new Dictionary<string, object?>
        {
            ["corr"] = _station.NextCorr(),
            ["start"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
        };
    }

    public override void PreDone(Context ctx)
    {
        if (_station == null)
        {
            return;
        }
        _station.OpEvent(_slug, CorrOf(ctx), StartOf(ctx),
            OpEntity(ctx), OpName(ctx), Outcome(ctx));
    }

    public override void PreUnexpected(Context ctx)
    {
        if (_station == null)
        {
            return;
        }
        _station.OpEvent(_slug, CorrOf(ctx), StartOf(ctx),
            OpEntity(ctx), OpName(ctx), "unexpected");
    }

    private static string? CorrOf(Context ctx)
    {
        if (ctx.Meta.TryGetValue("station$", out var state) &&
            state is Dictionary<string, object?> sm &&
            sm.TryGetValue("corr", out var corr) && corr is string ctext)
        {
            return ctext;
        }
        return null;
    }

    private static long? StartOf(Context ctx)
    {
        if (ctx.Meta.TryGetValue("station$", out var state) &&
            state is Dictionary<string, object?> sm &&
            sm.TryGetValue("start", out var start) && start is long stext)
        {
            return stext;
        }
        return null;
    }

    private static string OpEntity(Context ctx)
    {
        if (ctx.Op != null)
        {
            return ctx.Op.Entity;
        }
        return ctx.Entity?.GetName() ?? "";
    }

    private static string OpName(Context ctx)
    {
        return ctx.Op?.Name ?? "";
    }

    private static string Outcome(Context ctx)
    {
        var result = ctx.Result;
        if (result == null)
        {
            return "unknown";
        }
        if (result.Err != null)
        {
            return "err";
        }
        if (!result.Ok)
        {
            return "err";
        }
        return "ok";
    }
}
