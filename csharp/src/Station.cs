// The station library core, solo mode (station design D1): fully
// functional in-process with no other component running. The proxy (D2)
// is a deferred amplifier - `require` therefore fails on the operation
// path (design 2.1/14), and `auto` degrades to solo with one warning
// event.
//
// A port of typescript/src/Station.ts + adapter.ts, which are canonical.
// C# is an inverted-binding target (design 3.1): the app constructs the
// SDK through its existing generated constructor and hands it
// station-built options - `new SolardemoSDK(st.Options())` - so this
// library has no Connect(SDK)/Adopt(SDK) sugar. The generated station
// feature reads the handle from its feature options and delegates to
// FeatureBinding() during construction, exactly as the ts/js adapters
// delegate to their library's featureBinding. The typed transport wrap
// itself is installed by the generated adapter (the library cannot see a
// generated FetcherFunc type); everything the wrap DOES lives here.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Threading;

namespace Voxgig.Station
{
    public class Station
    {
        /// <summary>The inner transport a station wrap delegates to.</summary>
        public delegate object TransportFunc(string fullurl, Dictionary<string, object> fetchdef);

        private static Station ambient = null;
        private static string ambientOpts = null;
        private static readonly object AmbientGate = new object();

        private static long corrSeq = 0;

        // Station wraps installed on any client's transport slot,
        // process-wide: the C# spelling of the ts `__station__` marker (a
        // delegate cannot carry a property). ConditionalWeakTable is a weak
        // identity set, so dead clients do not pin their wraps.
        private static readonly ConditionalWeakTable<object, object> Marked =
            new ConditionalWeakTable<object, object>();

        private sealed class PluginEntry
        {
            public string Slug;
            public Dictionary<string, object> Descriptor;
            public string Rung;
            public object Client;
            public List<string> Warnings;
        }

        private readonly Dictionary<string, object> opts;
        private readonly Dictionary<string, object> profile;
        private readonly SecretBroker broker;
        private readonly EventBuffer buffer;
        private readonly Dictionary<string, PluginEntry> registry =
            new Dictionary<string, PluginEntry>();
        private readonly Dictionary<string, string> secretOverride =
            new Dictionary<string, string>();
        private readonly bool requireProxy;
        private bool closed = false;
        private readonly object gate = new object();

        /// <summary>
        /// Ambient instance (design 10.2): Open() is the idempotent
        /// process-wide singleton; a second Open() with conflicting options
        /// is an error; `new Station(opts)` stays isolated for tests and
        /// multi-tenant hosts. Open() is non-blocking - solo involves no
        /// network, and the deferred proxy probe must never change that.
        /// </summary>
        public static Station Open()
        {
            return Open(null);
        }

        public static Station Open(Dictionary<string, object> opts)
        {
            string key = Descriptor.CanonicalSerialize(
                null == opts ? new Dictionary<string, object>() : opts);
            lock (AmbientGate)
            {
                if (null != ambient)
                {
                    if (key != ambientOpts)
                    {
                        throw new StationError("station_open_conflict",
                            "Station.Open() was already called with different options");
                    }
                    return ambient;
                }
                ambient = new Station(opts);
                ambientOpts = key;
                return ambient;
            }
        }

        /// <summary>
        /// The ambient instance, or null - never creates one. The generated
        /// station feature binds through this when no explicit handle rides
        /// its options (design 3.1: binding is never implicit; only Open()
        /// creates the ambient instance).
        /// </summary>
        public static Station Current()
        {
            lock (AmbientGate)
            {
                return ambient;
            }
        }

        /// <summary>Test seam: drop the ambient instance.</summary>
        public static void Reset()
        {
            lock (AmbientGate)
            {
                ambient = null;
                ambientOpts = null;
            }
        }

        /// <summary>
        /// Resolve the station a feature activation binds to: an explicit
        /// handle in the feature options (st.Options() passes one), else the
        /// ambient instance. No station open -> null: an activated feature
        /// with no opened station is an inert no-op that emits nothing and
        /// fails nothing (design 3.1).
        /// </summary>
        public static Station From(object fopts)
        {
            if (Descriptor.GetProp(fopts, "station") is Station handle)
            {
                return handle;
            }
            return Current();
        }

        public Station() : this(null)
        {
        }

        public Station(Dictionary<string, object> opts)
        {
            this.opts = null == opts ? new Dictionary<string, object>() : opts;

            object config = this.opts.ContainsKey("config")
                ? this.opts["config"]
                : Profile.LoadConfig(Text(this.opts.GetValueOrDefault("folder")));

            profile = Profile.ResolveProfile(config,
                Profile.SelectProfile(Text(this.opts.GetValueOrDefault("profile"))));
            broker = new SecretBroker(profile["providers"]);
            buffer = new EventBuffer();

            object proxy = this.opts.GetValueOrDefault("proxy");
            if (null == proxy)
            {
                proxy = "auto";
            }
            requireProxy = "require".Equals(proxy);

            if ("auto".Equals(proxy))
            {
                // The probe is deferred with the proxy itself; absence
                // degrades to solo with a single warning event naming the
                // cause (design 14).
                Warn(null, "proxy absent (not found); running solo");
            }
        }

        // --- inverted binding (design 3.1) ---

        /// <summary>
        /// Build the plain options map a generated constructor already
        /// accepts: the caller's options plus the station activation entry
        /// carrying this handle. The generated station feature performs
        /// registration and credential placement during construction; the
        /// profile's per-plugin base is applied at binding time, when the
        /// slug is known.
        /// </summary>
        public Dictionary<string, object> Options()
        {
            return Options(null);
        }

        public Dictionary<string, object> Options(Dictionary<string, object> extra)
        {
            Dictionary<string, object> calleropts =
                null == extra ? new Dictionary<string, object>() : extra;
            var out_ = new Dictionary<string, object>(calleropts);

            var fmap = new Dictionary<string, object>(
                Descriptor.AsMap(out_.GetValueOrDefault("feature")));
            var entry = new Dictionary<string, object>(
                Descriptor.AsMap(fmap.GetValueOrDefault("station")));
            entry["active"] = true;
            entry["station"] = this;
            entry["calleropts"] = calleropts;
            fmap["station"] = entry;
            out_["feature"] = fmap;

            return out_;
        }

        // --- the binding seam (design 3, called by the generated adapter) ---

        /// <summary>
        /// The station side of the plugin contract (design 3), in ONE place -
        /// the C# spelling of the ts library's featureBinding(). The
        /// generated StationFeature calls it from Init() with the pieces the
        /// library cannot reach through generated types: the client handle,
        /// the feature names in add order, the current transport slot value,
        /// the embedded config, the resolved options, and its own feature
        /// options.
        ///
        /// Registration at init, wrap position verified, credential
        /// placeholder planted (a resident credential is hoisted), returns
        /// the binding - or null when this client is already bound (same
        /// construction, second arrival must no-op; a genuinely second client
        /// of the same SDK class still fails the slug check, design 10.2).
        /// </summary>
        public Dictionary<string, object> FeatureBinding(object client,
            IList<string> featureNames, object currentTransport,
            Dictionary<string, object> config, Dictionary<string, object> options,
            Dictionary<string, object> fopts)
        {
            lock (gate)
            {
                if (null != BoundEntry(client))
                {
                    return null;
                }

                // Position guard (design 3.3): the wrap must sit immediately
                // outside the base transport - inside retry/cache/ratelimit -
                // or its http events stop being wire truth. Position in
                // client.Features IS init order, so verify it and fail
                // loudly. One C#-specific adjustment: the generated
                // MakeFeature's default case absorbs an unknown activation
                // name as an inert BaseFeature (Name "base") instead of
                // throwing, so a stray "base" entry can sit anywhere in the
                // list without wrapping anything - expected position is
                // computed from the list with those inert slots skipped, not
                // from raw adjacency.
                var names = new List<string>();
                foreach (string name in featureNames)
                {
                    if ("base" != name)
                    {
                        names.Add(name);
                    }
                }
                int self = names.IndexOf("station");
                int testAt = names.IndexOf("test");
                int expected = 0 > testAt ? 0 : testAt + 1;
                if (self != expected)
                {
                    throw new StationError("station_wrap_order",
                        "station must init immediately after the base transport; "
                        + "feature order is [" + string.Join(", ", featureNames) + "]");
                }

                Descriptor.Normalized normalized = Descriptor.NormalizeDescriptor(
                    config, null == options ? null : options.GetValueOrDefault("feature"));
                Dictionary<string, object> descriptor = normalized.Descriptor;
                string slug = (string)descriptor["slug"];

                if (registry.ContainsKey(slug))
                {
                    throw new StationError("station_bound_twice",
                        "plugin \"" + slug + "\" is already registered; binding one "
                        + "client twice is an error (design 10.2)");
                }

                Dictionary<string, object> profilePlugin = Descriptor.AsMap(
                    Descriptor.GetProp(profile["sdk"], slug));

                // Secret name precedence: the feature option (in-code, design
                // 9 config.options.secret) beats the profile, which beats the
                // descriptor default.
                Dictionary<string, object> auth = Descriptor.AsMap(descriptor["auth"]);
                string foptSecret = Text(Descriptor.GetProp(fopts, "secret"));
                string secretname = FirstNonEmpty(foptSecret,
                    Text(profilePlugin.GetValueOrDefault("secret")));
                if (null == secretname)
                {
                    secretname = (string)auth["secretname"];
                }
                if (!string.IsNullOrEmpty(foptSecret))
                {
                    secretOverride[slug] = foptSecret;
                }

                bool authActive = true.Equals(auth["active"]);
                string rung = authActive ? "R1" : "none";

                var binding = new Dictionary<string, object>();
                binding["plugin"] = slug;
                if (authActive)
                {
                    binding["placeholder"] = SecretBroker.PlaceholderFor(slug);
                    binding["secretname"] = secretname;
                }
                binding["rung"] = rung;

                registry[slug] = new PluginEntry
                {
                    Slug = slug,
                    Descriptor = descriptor,
                    Rung = rung,
                    Client = client,
                    Warnings = normalized.Warnings,
                };

                foreach (string warning in normalized.Warnings)
                {
                    Warn(slug, warning);
                }
                var ev = Event("construct", slug, null);
                ev["meta"] = new Dictionary<string, object>
                {
                    ["name"] = descriptor["name"],
                    ["version"] = descriptor["version"],
                    ["rung"] = rung,
                };
                Emit(ev);

                // Base URL precedence (design 3.5): caller opts (7) beat the
                // profile (4), which beats the SDK's config default (1)
                // already in options.base. calleropts is what st.Options()
                // was handed, so an explicit caller base wins.
                object calleropts = Descriptor.GetProp(fopts, "calleropts");
                if (calleropts is IDictionary<string, object> co && null != options
                    && null == (co.TryGetValue("base", out object cb) ? cb : null)
                    && null != profilePlugin.GetValueOrDefault("base"))
                {
                    options["base"] = profilePlugin["base"];
                }

                if ("none" != rung && null != options)
                {
                    string placeholder = SecretBroker.PlaceholderFor(slug);

                    // A real credential already resident in the options is
                    // hoisted into the broker and replaced by the placeholder
                    // before construction completes (design 3.1 adopt) -
                    // Options() and Prepare() output become placeholder-safe
                    // from here on.
                    object resident = options.GetValueOrDefault("apikey");
                    if (resident is string rtext && 0 != rtext.Length
                        && placeholder != rtext)
                    {
                        broker.Hoist(slug, rtext);
                        Warn(slug, "a resident credential was hoisted into the broker "
                            + "and replaced by the placeholder; prefer configuring the "
                            + "secret name and letting sekreto resolve it");
                    }
                    options["apikey"] = placeholder;
                }

                // Double-wrap guard: a station wrap already on the transport
                // slot means another Station instance bound this client (the
                // same instance no-ops above).
                if (IsStationTransport(currentTransport))
                {
                    throw new StationError("station_bound_twice",
                        "plugin \"" + slug + "\" already carries a station wrap");
                }

                return binding;
            }
        }

        /// <summary>Record a transport wrap so the double-wrap guard can spot it.</summary>
        public void MarkTransport(object wrap)
        {
            if (null != wrap)
            {
                Marked.TryAdd(wrap, wrap);
            }
        }

        /// <summary>Is this transport slot value a station wrap (any instance's)?</summary>
        public bool IsStationTransport(object transport)
        {
            return null != transport && Marked.TryGetValue(transport, out object _);
        }

        /// <summary>A fresh per-operation correlation id (design 3 item 3).</summary>
        public string NextCorr()
        {
            return "c" + Interlocked.Increment(ref corrSeq)
                .ToString(CultureInfo.InvariantCulture);
        }

        private PluginEntry BoundEntry(object client)
        {
            foreach (PluginEntry entry in registry.Values)
            {
                if (ReferenceEquals(entry.Client, client))
                {
                    return entry;
                }
            }
            return null;
        }

        // --- the transport middleware (design 3.3, 5.3) ---

        /// <summary>
        /// The station middleware body, called by the generated wrap on every
        /// request: policy, injection with copy-on-inject, and the http
        /// event. `live` is whether the base transport is the real one (mock
        /// modes ride through untouched, so real credentials never enter
        /// in-memory mock stores, design 3.3); `corr` is the per-operation id
        /// the hook bridge planted, null on the Direct()/Graphql() path.
        /// </summary>
        public object Transport(string slug, string fullurl,
            Dictionary<string, object> fetchdef, bool live, string corr,
            TransportFunc inner)
        {
            // Fail-closed means traffic (design 2.1): with the proxy
            // deferred, `require` can never attach, so every operation fails
            // here - the operation path, never the constructor.
            if (requireProxy)
            {
                var noproxy = new StationError("station_no_proxy",
                    "proxy: \"require\" is set and no proxy is attached");
                EmitErr(slug, corr, noproxy);
                throw noproxy;
            }

            PluginEntry entry;
            lock (gate)
            {
                entry = registry.GetValueOrDefault(slug);
            }
            string placeholder = SecretBroker.PlaceholderFor(slug);
            Dictionary<string, object> profilePlugin = Descriptor.AsMap(
                Descriptor.GetProp(profile["sdk"], slug));

            // Egress policy (design 16), solo half: the hosts allowlist is
            // enforced at the seam every request crosses. When a policy is
            // present, redirects come back manual - a 3xx is a response like
            // any other, so a Location off the allowlist cannot pull an
            // automatic credentialed follow-up to an unapproved host (design
            // 8.2's rule, applied at the library seam).
            object hosts = Descriptor.GetProp(profilePlugin.GetValueOrDefault("policy"), "hosts");
            if (hosts is IList<object> allowed && live)
            {
                string hostname = "";
                try
                {
                    var uri = new Uri(fullurl);
                    hostname = uri.Host ?? "";
                }
                catch (UriFormatException)
                {
                    // Unparseable url: hostname stays '', which no allowlist
                    // holds.
                }
                if (!allowed.Contains(hostname))
                {
                    var denied = new StationError("station_host_allow",
                        "egress to \"" + hostname + "\" denied by the hosts policy of "
                        + "plugin \"" + slug + "\"");
                    EmitErr(slug, corr, denied);
                    throw denied;
                }
            }

            Dictionary<string, object> senddef = fetchdef;
            if (hosts is IList<object> && live)
            {
                senddef = new Dictionary<string, object>(senddef);
                senddef["redirect"] = "manual";
            }

            // Injection: at the last boundary, below every recording feature,
            // and never into mock transports (design 3.3). Copy-on-inject:
            // the object graph reachable from ctx/spec/ctrl keeps the
            // placeholder, ever (design 5.3).
            if (live && null != entry && "R1" == entry.Rung)
            {
                string secretname;
                lock (gate)
                {
                    secretname = FirstNonEmpty(secretOverride.GetValueOrDefault(slug),
                        Text(profilePlugin.GetValueOrDefault("secret")));
                }
                if (null == secretname)
                {
                    secretname = (string)Descriptor.GetProp(
                        entry.Descriptor["auth"], "secretname");
                }

                string value;
                try
                {
                    value = broker.Value(slug, secretname);
                }
                catch (StationError err)
                {
                    EmitErr(slug, corr, err);
                    throw;
                }

                senddef = new Dictionary<string, object>(senddef);
                var headers = new Dictionary<string, object>(
                    Descriptor.AsMap(senddef.GetValueOrDefault("headers")));
                foreach (string header in new List<string>(headers.Keys))
                {
                    if (headers[header] is string htext && htext.Contains(placeholder))
                    {
                        headers[header] = htext.Replace(placeholder, value);
                    }
                }
                senddef["headers"] = headers;
            }

            long started = Now();

            object res;
            try
            {
                res = inner(fullurl, senddef);
            }
            catch (Exception err)
            {
                EmitHttp(slug, corr, fullurl, senddef, 0, started, 0);
                EmitErr(slug, corr, err);
                throw;
            }

            int status = 0;
            long bytes = 0;
            if (res is IDictionary<string, object> resmap)
            {
                object s = resmap.TryGetValue("status", out object sraw) ? sraw : null;
                if (Descriptor.IsNumber(s))
                {
                    status = Convert.ToInt32(s, CultureInfo.InvariantCulture);
                }
                object cl = Descriptor.GetProp(
                    resmap.TryGetValue("headers", out object hraw) ? hraw : null,
                    "content-length");
                if (null != cl && !long.TryParse(
                    Convert.ToString(cl, CultureInfo.InvariantCulture).Trim(), out bytes))
                {
                    bytes = 0;
                }
            }
            EmitHttp(slug, corr, fullurl, senddef, status, started, bytes);

            return res;
        }

        /// <summary>Op events from the hook bridge (design 3 item 3).</summary>
        public void OpEvent(string slug, string corr, long? start,
            string entity, string opname, string outcome)
        {
            var ev = Event("op", slug, corr);
            ev["op"] = new Dictionary<string, object>
            {
                ["entity"] = entity ?? "",
                ["op"] = opname ?? "",
                ["outcome"] = outcome,
                ["durationMs"] = null == start ? 0L : Now() - start.Value,
            };
            Emit(ev);
        }

        private void EmitHttp(string slug, string corr, string fullurl,
            Dictionary<string, object> fetchdef, int status, long started, long bytes)
        {
            string host = "";
            string path = "";
            try
            {
                var uri = new Uri(fullurl);
                host = uri.IsDefaultPort
                    ? (uri.Host ?? "")
                    : uri.Host + ":" + uri.Port.ToString(CultureInfo.InvariantCulture);
                path = uri.AbsolutePath ?? "";
            }
            catch (UriFormatException)
            {
                path = fullurl;
            }

            object method = null == fetchdef ? null : fetchdef.GetValueOrDefault("method");

            var ev = Event("http", slug, corr);
            ev["t"] = started;
            ev["http"] = new Dictionary<string, object>
            {
                ["method"] = method is string mtext && 0 != mtext.Length ? mtext : "GET",
                ["host"] = host,
                ["path"] = path,
                ["status"] = status,
                ["durationMs"] = Now() - started,
                ["bytes"] = bytes,
            };
            Emit(ev);
        }

        private void EmitErr(string slug, string corr, Exception err)
        {
            var errmap = new Dictionary<string, object>();
            if (err is StationError serr)
            {
                errmap["code"] = serr.Code;
            }
            // The scrub keeps an upstream echo of a credential out of the
            // event stream (design 7 as revised: exact-value, no length
            // floor).
            errmap["message"] = Redact(err.Message ?? err.ToString());

            var ev = Event("error", slug, corr);
            ev["err"] = errmap;
            Emit(ev);
        }

        // --- the query/observe surface (design 3.2, 6) ---

        public List<Dictionary<string, object>> Plugins()
        {
            lock (gate)
            {
                var out_ = new List<Dictionary<string, object>>();
                foreach (PluginEntry entry in registry.Values)
                {
                    out_.Add(new Dictionary<string, object>
                    {
                        ["slug"] = entry.Slug,
                        ["descriptor"] = entry.Descriptor,
                        ["rung"] = entry.Rung,
                        ["warnings"] = new List<string>(entry.Warnings),
                    });
                }
                return out_;
            }
        }

        public Dictionary<string, object> DescriptorOf(string slug)
        {
            lock (gate)
            {
                PluginEntry entry = registry.GetValueOrDefault(slug);
                if (null == entry)
                {
                    throw new StationError("station_no_plugin", "unknown plugin \"" + slug
                        + "\"; known: [" + string.Join(", ", registry.Keys) + "]");
                }
                return entry.Descriptor;
            }
        }

        public string CanonicalDescriptor(string slug)
        {
            return Descriptor.CanonicalSerialize(DescriptorOf(slug));
        }

        public List<Dictionary<string, object>> Events()
        {
            return buffer.Events();
        }

        public Action Tap(Action<Dictionary<string, object>> tap)
        {
            return buffer.Tap(tap);
        }

        public Dictionary<string, object> Status()
        {
            lock (gate)
            {
                var plugins = new List<Dictionary<string, object>>();
                foreach (PluginEntry entry in registry.Values)
                {
                    plugins.Add(new Dictionary<string, object>
                    {
                        ["slug"] = entry.Slug,
                        ["rung"] = entry.Rung,
                    });
                }

                return new Dictionary<string, object>
                {
                    ["mode"] = "solo",
                    ["profile"] = profile["name"],
                    ["plugins"] = plugins,
                    ["events"] = buffer.Status(),
                };
            }
        }

        public string Redact(string text)
        {
            return broker.Scrub(text);
        }

        public void RefreshSecrets()
        {
            broker.Refresh();
        }

        /// <summary>
        /// Close(): flush (solo: nothing in flight), then warn on profile
        /// plugin keys that matched no registered plugin - a typo'd key
        /// silently configuring nothing is the worst outcome for a
        /// secrets-and-policy file (design 11).
        /// </summary>
        public void Close()
        {
            lock (gate)
            {
                if (closed)
                {
                    return;
                }
                foreach (string slug in Descriptor.AsMap(profile["sdk"]).Keys)
                {
                    if (!registry.ContainsKey(slug))
                    {
                        Warn(null, "profile plugin key \"" + slug
                            + "\" matched no registered plugin");
                    }
                }
                closed = true;
            }
            lock (AmbientGate)
            {
                if (ReferenceEquals(ambient, this))
                {
                    ambient = null;
                    ambientOpts = null;
                }
            }
        }

        // --- internals ---

        private static Dictionary<string, object> Event(string kind, string plugin, string corr)
        {
            var out_ = new Dictionary<string, object>
            {
                ["t"] = Now(),
                ["kind"] = kind,
            };
            if (null != plugin)
            {
                out_["plugin"] = plugin;
            }
            if (null != corr)
            {
                out_["corr"] = corr;
            }
            return out_;
        }

        private void Warn(string plugin, string message)
        {
            var ev = Event("station", plugin, null);
            ev["meta"] = new Dictionary<string, object> { ["warn"] = message };
            Emit(ev);
        }

        private void Emit(Dictionary<string, object> ev)
        {
            buffer.Emit(ev);
        }

        private static long Now()
        {
            return DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        }

        private static string Text(object val)
        {
            return val is string text ? text : null;
        }

        private static string FirstNonEmpty(params string[] vals)
        {
            foreach (string val in vals)
            {
                if (!string.IsNullOrEmpty(val))
                {
                    return val;
                }
            }
            return null;
        }
    }
}
