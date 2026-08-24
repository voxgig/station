// RUN: make test
// RUN-SOME: ./test/bin/Debug/net8.0/stationtest secretname
//
// The station conformance suite: the pure-contract half of the design's
// (13) corpus, from spec/station.json, through voxgig/omni - the same
// file every port runs. Sections that need live SDK machinery (inject,
// order, event correlation) live in the consumer end-to-end suites
// against real generated SDKs; the corpus carries what a port can prove
// with no SDK present. The focused unit cases below cover the station
// mechanics the corpus cannot reach without an SDK: the event ring, the
// broker's miss-vs-error and floor-less scrub, the binding guards, and
// the transport middleware's copy-on-inject.
//
// No third-party test framework: a failing omni check throws OmniError,
// so `make test` stays dependency-free (the sekreto/omni pattern).

using System;
using System.Collections.Generic;
using System.IO;

using Voxgig.Omni;
using Voxgig.Sekreto;
using Voxgig.Station;

internal static class Program
{
    private static string only;
    private static int passcount;
    private static int failcount;

    // Find the shared spec directory by walking up from the working dir.
    private static string SpecFile(string name)
    {
        var dir = new DirectoryInfo(Directory.GetCurrentDirectory());

        for (int step = 0; step < 8 && null != dir; step++)
        {
            string cand = Path.Combine(dir.FullName, "spec", name);
            if (File.Exists(cand))
            {
                return cand;
            }
            dir = dir.Parent;
        }

        throw new OmniError("station: spec not found: " + name);
    }

    // --- corpus subjects ---

    private static readonly Subject SECRETNAME = args =>
    {
        string slug = Convert.ToString(Descriptor.GetProp(args[0], "slug"));
        string secretname = Descriptor.SecretnameDefault(slug);
        return new Dictionary<string, object>
        {
            ["envtoken"] = Descriptor.EnvToken(slug),
            ["secretname"] = secretname,
            ["envkey"] = Names.EnvKey(secretname),
        };
    };

    private static readonly Subject PLACEHOLDER = args =>
        SecretBroker.PlaceholderFor(Convert.ToString(args[0]));

    private static readonly Subject DESCRIPTOR = args =>
        Voxgig.Station.Descriptor.NormalizeDescriptor(
            Descriptor.GetProp(args[0], "config"),
            Descriptor.GetProp(args[0], "feature")).Descriptor;

    private static readonly Subject DESCWARN = args =>
        Voxgig.Station.Descriptor.NormalizeDescriptor(
            Descriptor.GetProp(args[0], "config"),
            Descriptor.GetProp(args[0], "feature")).Warnings.Count;

    // Spec nulls arrive as omni's NULLMARK sentinel; restore them so the
    // serializer sees what the spec means.
    private static object Denull(object val)
    {
        if (Runner.NULLMARK.Equals(val))
        {
            return null;
        }
        if (val is IList<object> list)
        {
            var out_ = new List<object>();
            foreach (object entry in list)
            {
                out_.Add(Denull(entry));
            }
            return out_;
        }
        if (val is IDictionary<string, object> map)
        {
            var out_ = new Dictionary<string, object>();
            foreach (KeyValuePair<string, object> entry in map)
            {
                out_[entry.Key] = Denull(entry.Value);
            }
            return out_;
        }
        return val;
    }

    private static readonly Subject CANONICAL = args =>
        Descriptor.CanonicalSerialize(Denull(args[0]));

    private static readonly Subject INSTANCE = args =>
        Profile.ResolveProfile(
            Descriptor.GetProp(args[0], "config"),
            Convert.ToString(Descriptor.GetProp(args[0], "profile")));

    private static readonly Subject ERRORS = args => StationError.IsKnownCode(args[0]);

    // --- harness ---

    private static void TestCase(string name, Action body)
    {
        if (null != only && name != only)
        {
            return;
        }

        try
        {
            body();
            passcount++;
            Console.WriteLine("ok   - " + name);
        }
        catch (Exception err)
        {
            failcount++;
            Console.WriteLine("FAIL - " + name);
            Console.WriteLine(err.Message);
        }
    }

    private static void Check(bool cond, string what)
    {
        if (!cond)
        {
            throw new InvalidOperationException("station: check failed: " + what);
        }
    }

    private static Dictionary<string, object> Map(params object[] pairs)
    {
        var out_ = new Dictionary<string, object>();
        for (int index = 0; index + 1 < pairs.Length; index += 2)
        {
            out_[Convert.ToString(pairs[index])] = pairs[index + 1];
        }
        return out_;
    }

    private static List<object> Vals(params object[] items)
    {
        return new List<object>(items);
    }

    // A station over a memory provider chain, isolated from the ambient
    // instance and from any station.json on disk.
    private static Station MemoryStation(Dictionary<string, object> values,
        Dictionary<string, object> plugin)
    {
        var profile = Map(
            "secrets", Map("providers", Vals(Map("kind", "memory", "values", values))));
        if (null != plugin)
        {
            profile["sdk"] = plugin;
        }
        var config = Map("station", 1, "profiles", Map("default", profile));
        return new Station(Map("config", config));
    }

    // The embedded-config shape a generated SDK carries, small.
    private static Dictionary<string, object> SdkConfig(string name, string slug)
    {
        var main = Map("name", name);
        if (null != slug)
        {
            main["slug"] = slug;
            main["version"] = "0.0.1";
            main["target"] = "csharp";
        }
        return Map(
            "main", main,
            "feature", Map("test", Map()),
            "options", Map(
                "base", "http://localhost:8000",
                "auth", Map("prefix", ""),
                "entity", Map("todo", Map())),
            "entity", Map("todo", Map(
                "name", "todo",
                "fields", Vals(Map("name", "title", "kind", "String")),
                "op", Map("list", Map("points", Vals(Map(
                    "method", "GET",
                    "orig", "/api/todo",
                    "parts", Vals("api", "todo"))))))));
    }

    private static Dictionary<string, object> Bind(Station st, object client,
        Dictionary<string, object> options)
    {
        var fopts = Descriptor.AsMap(Descriptor.GetProp(
            options.GetValueOrDefault("feature"), "station"));
        return st.FeatureBinding(client, new List<string> { "station" }, null,
            SdkConfig("TestPlug", "test-plug"), options, fopts);
    }

    private static int Main(string[] args)
    {
        if (0 < args.Length)
        {
            only = args[0];
        }

        RunPack R = Runner.MakeRunner(SpecFile("station.json")).Run("station");

        // The shared corpus (design 13).
        TestCase("secretname", () => R.RunSet(R.Set("secretname"), SECRETNAME));
        TestCase("placeholder", () => R.RunSet(R.Set("placeholder"), PLACEHOLDER));
        TestCase("descriptor", () => R.RunSet(R.Set("descriptor"), DESCRIPTOR));
        TestCase("descriptorwarnings", () => R.RunSet(R.Set("descriptorwarnings"), DESCWARN));
        TestCase("canonical", () => R.RunSet(R.Set("canonical"), CANONICAL));
        // The 3.3 merge, and the whole of this port's profile contract.
        // The `profile` section is NOT run: it pins the pre-Stage-1
        // `plugin` grammar, which this port no longer speaks. It stays in
        // the corpus for the ports that have not crossed yet - see
        // spec/README.md.
        TestCase("instance", () => R.RunSet(R.Set("instance"), INSTANCE));
        TestCase("errors", () => R.RunSet(R.Set("errors"), ERRORS));

        // Focused unit cases: the mechanics the corpus cannot reach.

        TestCase("events: ring overflow drops oldest, counted", () =>
        {
            var buffer = new EventBuffer(2);
            buffer.Emit(Map("t", 1L, "kind", "station"));
            buffer.Emit(Map("t", 2L, "kind", "station"));
            buffer.Emit(Map("t", 3L, "kind", "station"));
            var events = buffer.Events();
            Check(2 == events.Count, "ring bounded");
            Check(2L.Equals(events[0]["t"]), "oldest dropped");
            Check(1L.Equals(buffer.Status()["dropped"]), "drop counted");
        });

        TestCase("events: a throwing tap never fails the emitter", () =>
        {
            var buffer = new EventBuffer();
            var seen = new List<object>();
            buffer.Tap(ev => throw new InvalidOperationException("tap boom"));
            Action off = buffer.Tap(ev => seen.Add(ev));
            buffer.Emit(Map("kind", "station"));
            Check(1 == seen.Count, "tap saw the event");
            off();
            buffer.Emit(Map("kind", "station"));
            Check(1 == seen.Count, "unsubscribed");
        });

        TestCase("broker: miss is station_secret_no_value, scrub has no floor", () =>
        {
            var broker = new SecretBroker(Vals(
                Map("kind", "memory", "values", Map("A_APIKEY", "xy"))));
            Check("xy" == broker.Value("a", "a.apikey"), "resolves");
            // Exact-value scrub, even below sekreto's four-character floor.
            Check("k=[redacted];" == broker.Scrub("k=xy;"), "floor-less scrub");
            try
            {
                broker.Value("b", "b.apikey");
                Check(false, "miss should throw");
            }
            catch (StationError err)
            {
                Check("station_secret_no_value" == err.Code, "miss code");
            }
        });

        TestCase("open: idempotent ambient, conflicting reopen fails", () =>
        {
            Station.Reset();
            try
            {
                Station one = Station.Open(Map("config", null));
                Check(ReferenceEquals(one, Station.Open(Map("config", null))),
                    "same instance");
                Check(ReferenceEquals(one, Station.Current()), "Current() is the ambient");
                try
                {
                    Station.Open(Map("config", null, "profile", "prod"));
                    Check(false, "conflicting open must fail");
                }
                catch (StationError err)
                {
                    Check("station_open_conflict" == err.Code, "conflict code");
                }
                one.Close();
                Check(null == Station.Current(), "Close() of the ambient resets it");
            }
            finally
            {
                Station.Reset();
            }
        });

        TestCase("options: activation entry carries the handle", () =>
        {
            Station st = MemoryStation(Map(), null);
            var options = st.Options(Map("base", "http://x:1"));
            var entry = Descriptor.AsMap(Descriptor.GetProp(options["feature"], "station"));
            Check(true.Equals(entry["active"]), "active");
            Check(ReferenceEquals(st, entry["station"]), "handle rides the options");
            Check("http://x:1".Equals(options["base"]), "caller opts kept");
        });

        TestCase("binding: registers, plants placeholder, hoists a resident key", () =>
        {
            Station st = MemoryStation(Map("TEST_PLUG_APIKEY", "real-key-1"), null);
            var client = new object();
            var options = st.Options(Map());
            options["apikey"] = "resident-key";
            var binding = Bind(st, client, options);
            Check("test-plug".Equals(binding["plugin"]), "slug");
            Check("R1".Equals(binding["rung"]), "rung");
            Check("[station:test-plug]".Equals(options["apikey"]), "placeholder planted");
            bool warned = false;
            foreach (var ev in st.Events())
            {
                object meta = ev.GetValueOrDefault("meta");
                warned = warned || (null != meta && Convert.ToString(
                    Descriptor.GetProp(meta, "warn")).Contains("hoisted"));
            }
            Check(warned, "hoist warning emitted");
            Check("x [redacted] y" == st.Redact("x resident-key y"),
                "hoisted value scrubbed");
            // Same client, second arrival: inert.
            Check(null == Bind(st, client, options), "idempotent per client");
            // A second client of the same SDK: refused.
            try
            {
                Bind(st, new object(), st.Options(Map()));
                Check(false, "second client must fail");
            }
            catch (StationError err)
            {
                Check("station_bound_twice" == err.Code, "bound twice code");
            }
        });

        TestCase("binding: wrong wrap position fails loudly", () =>
        {
            Station st = MemoryStation(Map(), null);
            try
            {
                st.FeatureBinding(new object(),
                    new List<string> { "test", "retry", "station" },
                    null, SdkConfig("TestPlug", "test-plug"), Map("feature", Map()), Map());
                Check(false, "order guard must trip");
            }
            catch (StationError err)
            {
                Check("station_wrap_order" == err.Code, "order code");
            }
        });

        TestCase("binding: inert base entries are skipped by the guard", () =>
        {
            // The generated MakeFeature's default case absorbs an unknown
            // activation name as an inert BaseFeature (Name "base") - it
            // occupies a Features slot but never wraps the transport, so the
            // position guard must tolerate it wherever it sits (csharp seam:
            // expected position comes from the wrapping list, not raw
            // adjacency).
            Station st = MemoryStation(Map(), null);
            var binding = st.FeatureBinding(new object(),
                new List<string> { "test", "base", "station" },
                null, SdkConfig("TestPlug", "test-plug"), Map("feature", Map()), Map());
            Check(null != binding, "stray base between test and station tolerated");
        });

        TestCase("transport: copy-on-inject swaps only the sent copy", () =>
        {
            Station st = MemoryStation(Map("TEST_PLUG_APIKEY", "real-key-2"), null);
            var options = st.Options(Map());
            Bind(st, new object(), options);

            var headers = Map("authorization", "[station:test-plug]");
            var fetchdef = Map("method", "GET", "headers", headers);
            var sent = new List<object>();
            object res = st.Transport("test-plug", "http://localhost:8000/api/todo",
                fetchdef, true, "c1", (url, def) =>
                {
                    sent.Add(Descriptor.GetProp(def["headers"], "authorization"));
                    return Map("status", 200, "headers", Map("content-length", "12"));
                });
            Check("real-key-2".Equals(sent[0]), "real value on the wire");
            Check("[station:test-plug]".Equals(headers["authorization"]),
                "caller's fetchdef keeps the placeholder");
            Check(res is Dictionary<string, object>, "response returned");

            Dictionary<string, object> http = null;
            foreach (var ev in st.Events())
            {
                if ("http".Equals(ev.GetValueOrDefault("kind")))
                {
                    http = ev;
                }
            }
            Check(null != http, "http event emitted");
            Check("c1".Equals(http["corr"]), "correlated");
            var hm = Descriptor.AsMap(http["http"]);
            Check(200.Equals(hm["status"]), "wire status");
            Check(12L.Equals(hm["bytes"]), "bytes from content-length");
        });

        TestCase("transport: no injection into mock transports", () =>
        {
            Station st = MemoryStation(Map("TEST_PLUG_APIKEY", "real-key-3"), null);
            Bind(st, new object(), st.Options(Map()));
            var sent = new List<object>();
            st.Transport("test-plug", "http://localhost:8000/api/todo",
                Map("headers", Map("authorization", "[station:test-plug]")),
                false, null, (url, def) =>
                {
                    sent.Add(Descriptor.GetProp(def["headers"], "authorization"));
                    return Map("status", 200);
                });
            Check("[station:test-plug]".Equals(sent[0]),
                "placeholder rides through untouched in mock mode");
        });

        TestCase("transport: a missing secret fails the op with the code", () =>
        {
            Station st = MemoryStation(Map(), null);
            Bind(st, new object(), st.Options(Map()));
            try
            {
                st.Transport("test-plug", "http://localhost:8000/api/todo",
                    Map("headers", Map()), true, null, (url, def) => Map("status", 200));
                Check(false, "missing secret must throw");
            }
            catch (StationError err)
            {
                Check("station_secret_no_value" == err.Code, "miss code");
            }
            bool recorded = false;
            foreach (var ev in st.Events())
            {
                recorded = recorded || ("error".Equals(ev.GetValueOrDefault("kind"))
                    && "station_secret_no_value".Equals(
                        Descriptor.GetProp(ev.GetValueOrDefault("err"), "code")));
            }
            Check(recorded, "error event recorded");
        });

        TestCase("transport: hosts policy denies off-list egress, live only", () =>
        {
            Station st = MemoryStation(Map("TEST_PLUG_APIKEY", "k"), Map(
                "test-plug", Map("policy", Map("hosts", Vals("api.good.example")))));
            Bind(st, new object(), st.Options(Map()));
            try
            {
                st.Transport("test-plug", "http://evil.example/x",
                    Map("headers", Map()), true, null, (url, def) => Map("status", 200));
                Check(false, "off-list host must be denied");
            }
            catch (StationError err)
            {
                Check("station_host_allow" == err.Code, "host code");
            }
            // A mock-transport call is not egress; the policy does not fire.
            object res = st.Transport("test-plug", "http://evil.example/x",
                Map("headers", Map()), false, null, (url, def) => Map("status", 200));
            Check(res is Dictionary<string, object>, "mock path unaffected");
        });

        TestCase("transport: manual redirects ride the sent copy under a hosts policy", () =>
        {
            Station st = MemoryStation(Map("TEST_PLUG_APIKEY", "k"), Map(
                "test-plug", Map("policy", Map("hosts", Vals("api.good.example")))));
            Bind(st, new object(), st.Options(Map()));
            var fetchdef = Map("headers", Map());
            var sent = new List<object>();
            st.Transport("test-plug", "http://api.good.example/x",
                fetchdef, true, null, (url, def) =>
                {
                    sent.Add(def.GetValueOrDefault("redirect"));
                    return Map("status", 200);
                });
            Check("manual".Equals(sent[0]), "redirect: manual on the sent copy");
            Check(!fetchdef.ContainsKey("redirect"), "caller's fetchdef untouched");
        });

        TestCase("transport: require-proxy fails closed on the operation path", () =>
        {
            var st = new Station(Map("config", null, "proxy", "require"));
            try
            {
                st.Transport("any", "http://localhost:1/x", Map(), true, null,
                    (url, def) => Map("status", 200));
                Check(false, "require must fail traffic");
            }
            catch (StationError err)
            {
                Check("station_no_proxy" == err.Code, "no proxy code");
            }
        });

        Console.WriteLine("\n" + passcount + " passed, " + failcount + " failed");

        return 0 == failcount ? 0 : 1;
    }
}
