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
using System.Linq;

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

    private static readonly Subject SUBSTITUTE = args =>
    {
        SecretBroker.Substituted sent = SecretBroker.Substitute(
            Convert.ToString(Descriptor.GetProp(args[0], "url")),
            Descriptor.AsMap(Descriptor.GetProp(args[0], "headers")),
            Convert.ToString(Descriptor.GetProp(args[0], "placeholder")),
            Convert.ToString(Descriptor.GetProp(args[0], "value")));
        return new Dictionary<string, object>
        {
            ["url"] = sent.Url,
            ["headers"] = sent.Headers,
        };
    };

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

    // A `ref` asks for the options that named instance is constructed with.
    private static readonly Subject INSTANCE = args =>
    {
        Dictionary<string, object> profile = Profile.ResolveProfile(
            Descriptor.GetProp(args[0], "config"),
            Convert.ToString(Descriptor.GetProp(args[0], "profile")));
        if (!(Descriptor.GetProp(args[0], "ref") is string ref_))
        {
            return profile;
        }
        return Profile.InstanceOptions(
            Profile.BlockOf(profile, ref_), Denull(Descriptor.GetProp(args[0], "opts")));
    };

    private static readonly Subject INSTANCEREF = args =>
        Station.InstanceRef(Convert.ToString(Descriptor.GetProp(args[0], "api")),
            Descriptor.GetProp(args[0], "opts"));

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

    private static string EventText(Station st)
    {
        return string.Join("\n", st.Events().ConvertAll(ev => Descriptor.CanonicalSerialize(ev)));
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
        TestCase("substitute", () => R.RunSet(R.Set("substitute"), SUBSTITUTE));
        TestCase("descriptor", () => R.RunSet(R.Set("descriptor"), DESCRIPTOR));
        TestCase("descriptorwarnings", () => R.RunSet(R.Set("descriptorwarnings"), DESCWARN));
        TestCase("canonical", () => R.RunSet(R.Set("canonical"), CANONICAL));
        // The 3.3 merge, and the whole of this port's profile contract.
        TestCase("instance", () => R.RunSet(R.Set("instance"), INSTANCE));
        TestCase("instanceref", () => R.RunSet(R.Set("instanceref"), INSTANCEREF));
        TestCase("errors", () => R.RunSet(R.Set("errors"), ERRORS));

        // Focused unit cases: the mechanics the corpus cannot reach.

        // This port runs no `config` section yet, so the raw-text cases it
        // carries are pinned here.
        TestCase("config: an unpaired surrogate escape is refused", () =>
        {
            foreach (string literal in new[] {
                "\"joplin$a\\ud800\"", "\"x\\uDC00y\"", "\"\\ud83d\\ud83d\"",
                "\"\\ude00\\ud83d\"" })
            {
                try
                {
                    Profile.ParseConfig("{\"station\": 1, \"profiles\": {" + literal + ": {}}}");
                    Check(false, "refused: " + literal);
                }
                catch (StationError err)
                {
                    Check("station_config_invalid" == err.Code, "code");
                    Check("station_config_invalid: station.json has an unpaired surrogate "
                        + "escape in " + literal == err.Message, err.Message);
                }
            }
            var config = Profile.ParseConfig("{\"pair\": \"\\ud83d\\ude00\", "
                + "\"text\": \"\\\\ud800\"}");
            Check("\U0001F600" == (string)config["pair"], "an escaped pair is one character");
            Check("\\ud800" == (string)config["text"], "an escaped backslash is no escape");

            string dir = Path.Combine(Path.GetTempPath(), "station-surrogate-" + Guid.NewGuid());
            Directory.CreateDirectory(Path.Combine(dir, ".git"));
            string file = Path.Combine(dir, "station.json");
            File.WriteAllText(file, "{\"station\": 1, \"profiles\": {\"x\\ud800\": {}}}");
            try
            {
                Profile.LoadConfig(dir);
                Check(false, "LoadConfig refuses it");
            }
            catch (StationError err)
            {
                Check("station_config_invalid: station.json at " + file
                    + " has an unpaired surrogate escape in \"x\\ud800\"" == err.Message,
                    err.Message);
            }
            finally
            {
                Directory.Delete(dir, true);
            }
        });

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

        TestCase("broker: every form is matched against the original text", () =>
        {
            foreach (string[] held in new[] { new[] { "%", "secret!" }, new[] { "secret!", "%" } })
            {
                var broker = new SecretBroker(Vals());
                broker.Hoist("a", held[0]);
                broker.Hoist("b", held[1]);
                string got = broker.Scrub("token=secret%21");
                Check("token=[redacted]" == got, string.Join(" ", held) + ": " + got);
            }
            var overlap = new SecretBroker(Vals());
            overlap.Hoist("a", "ab!");
            overlap.Hoist("b", "!c");
            string spans = overlap.Scrub("x=ab%21c&y=!c");
            Check("x=[redacted]&y=[redacted]" == spans, "one span: " + spans);
        });

        TestCase("broker: sekreto's own redact cannot hide an encoded form", () =>
        {
            var broker = new SecretBroker(Vals(
                Map("kind", "memory", "values", Map("SCRUB_APIKEY", "abcd"))));
            Check("abcd" == broker.Value("scrub", "scrub.apikey"), "resolves");
            broker.Hoist("other", "abcd!x");
            string got = broker.Scrub("k=abcd%21x");
            Check("k=[redacted]" == got, "sekreto runs second: " + got);
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

        TestCase("options: the activation entry keeps no caller key", () =>
        {
            Station st = MemoryStation(Map(), null);
            var options = st.Options(Map("apikey", "exposure-key-101"));
            Check("exposure-key-101".Equals(options["apikey"]), "the SDK still gets its key");
            var entry = Descriptor.AsMap(Descriptor.GetProp(options["feature"], "station"));
            var calleropts = Descriptor.AsMap(entry["calleropts"]);
            Check(!calleropts.ContainsKey("apikey"), "the entry keeps no key");
            Check(!System.Text.Json.JsonSerializer.Serialize(calleropts).Contains("exposure-key-101"),
                "the entry serialises without the key");
        });

        TestCase("options: a named instance is constructed with its block's options", () =>
        {
            Station st = MemoryStation(Map("TEST_PLUG_EU_APIKEY", "eu-key"), Map(
                "test-plug", Map("options", Map("prefix", "/default")),
                "test-plug$eu", Map("base", "http://eu.example:1",
                    "options", Map("prefix", "/eu", "suffix", ".json"))));
            var options = st.Options("test-plug$eu", Map("suffix", ".xml"));
            Check("/eu".Equals(options.GetValueOrDefault("prefix")),
                "the block's options reach the SDK");
            Check(".xml".Equals(options.GetValueOrDefault("suffix")),
                "the caller's options win, key by key");
            Check("http://eu.example:1".Equals(options.GetValueOrDefault("base")),
                "the block's base");

            var binding = Bind(st, new object(), options);
            Check("test-plug$eu".Equals(binding["plugin"]),
                "registered under the named ref: " + binding["plugin"]);
            Check("test_plug_eu.apikey".Equals(binding["secretname"]),
                "the instance's own secret name: " + binding["secretname"]);
            Check("[station:test-plug$eu]".Equals(options["apikey"]),
                "the instance's placeholder");

            var sent = new List<object>();
            st.Transport("test-plug$eu", "http://eu.example:1/api/todo",
                Map("headers", Map("authorization", "[station:test-plug$eu]")), true, null,
                (url, def) =>
                {
                    sent.Add(Descriptor.GetProp(def["headers"], "authorization"));
                    return Map("status", 200);
                });
            Check("eu-key".Equals(sent[0]), "the instance's credential on the wire");

            var plain = Bind(st, new object(), st.Options(Map()));
            Check("test-plug".Equals(plain["plugin"]), "the default instance keeps its slug");
        });

        TestCase("options: the list form keeps its order, with station in its pinned place", () =>
        {
            Station st = MemoryStation(Map(), Map(
                "test-plug", Map(), "test-plug$eu", Map("options", Map("prefix", "/eu"))));
            var retry = Map("name", "retry", "active", true);
            var test = Map("name", "test", "active", true);
            Func<object, string> names = feature => string.Join(",",
                ((List<object>)feature).Select(f => Descriptor.GetProp(f, "name")));

            var bare = st.Options(Map("feature", new List<object> { retry }))["feature"];
            Check("station,retry" == names(bare), "station first without test: " + names(bare));
            Check(true.Equals(Descriptor.GetProp(((List<object>)bare)[0], "active")),
                "station is active");

            var tested = st.Options(Map("feature", new List<object> { test, retry }))["feature"];
            Check("test,station,retry" == names(tested), "station right after test: " + names(tested));

            var moved = st.Options(Map("feature", new List<object> {
                retry, Map("name", "station", "instance", "test-plug$eu"), test }));
            Check("retry,test,station" == names(moved["feature"]),
                "the caller's entry moves: " + names(moved["feature"]));
            Check("test-plug$eu".Equals(
                Descriptor.GetProp(((List<object>)moved["feature"])[2], "instance")), "and is kept");
            Check("/eu".Equals(moved.GetValueOrDefault("prefix")),
                "the instance is read from the list");
        });

        TestCase("options: a top-level instance or full-ref as names the instance", () =>
        {
            Station st = MemoryStation(Map(), Map(
                "test-plug$eu", Map("options", Map("prefix", "/eu"))));
            foreach (string key in new[] { "instance", "as" })
            {
                var options = st.Options(Map(key, "test-plug$eu"));
                Check("/eu".Equals(options.GetValueOrDefault("prefix")), "named by " + key);
                Check(!options.ContainsKey("instance") && !options.ContainsKey("as"),
                    key + " is not an SDK option");
                var entry = Descriptor.AsMap(Descriptor.GetProp(options["feature"], "station"));
                Check("test-plug$eu".Equals(entry.GetValueOrDefault(key)),
                    key + " rides the station entry");
            }

            var lead = st.Options("test-plug$eu", Map("instance", "test-plug$us"));
            Check("/eu".Equals(lead.GetValueOrDefault("prefix")),
                "the leading name outranks a top-level instance");

            var tagged = st.Options(Map("as", "eu"));
            Check(!tagged.ContainsKey("prefix"), "a bare tag waits for the SDK's api");
            Check("test-plug$eu".Equals(Bind(st, new object(), tagged)["plugin"]),
                "and resolves against it at binding");

            try
            {
                Bind(st, new object(), st.Options("other$eu", Map()));
                Check(false, "a ref naming another api must fail");
            }
            catch (StationError err)
            {
                Check("station_instance_api" == err.Code, "instance api code");
            }
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

        TestCase("transport: a query-placed credential reaches the wire encoded, and nothing else", () =>
        {
            Station st = MemoryStation(Map("TEST_PLUG_APIKEY", "tok!en 1"), null);
            Bind(st, new object(), st.Options(Map()));

            string url = "http://localhost:8000/api/todo?fields=id%2Ctitle&token="
                + "%5Bstation%3Atest-plug%5D";
            var fetchdef = Map("url", url, "method", "GET", "headers", Map());
            var sent = new List<object>();
            st.Transport("test-plug", url, fetchdef, true, null, (wireurl, def) =>
            {
                sent.Add(wireurl);
                sent.Add(def["url"]);
                return Map("status", 200);
            });

            string wire = "http://localhost:8000/api/todo?fields=id%2Ctitle&token=tok%21en%201";
            Check(wire.Equals(sent[0]), "the value reaches the wire encoded");
            Check(wire.Equals(sent[1]), "the sent fetchdef url agrees");
            Check(url.Equals(fetchdef["url"]), "caller's fetchdef keeps the placeholder");
            string events = EventText(st);
            Check(!events.Contains("tok%21en%201") && !events.Contains("tok!en 1"),
                "events carry no value");
        });

        TestCase("transport: a transport error quoting the placed URL is scrubbed", () =>
        {
            Station st = MemoryStation(Map("TEST_PLUG_APIKEY", "tok!en 1"), null);
            Bind(st, new object(), st.Options(Map()));

            string url = "http://localhost:8000/api/todo?token=%5Bstation%3Atest-plug%5D";
            Exception caught = null;
            try
            {
                st.Transport("test-plug", url, Map("url", url, "headers", Map()), true, null,
                    (wireurl, def) => throw new InvalidOperationException("failed: GET " + wireurl));
            }
            catch (Exception err)
            {
                caught = err;
            }
            Check(null != caught, "the transport error surfaces");
            Check(!caught.Message.Contains("tok%21en%201"), "scrubbed: " + caught.Message);
            Check(caught.Message.Contains("[redacted]"), "scrub marker: " + caught.Message);
            Check(!EventText(st).Contains("tok%21en%201"), "events carry no value");
        });

        TestCase("transport: a transport error's inner exception chain is scrubbed", () =>
        {
            Station st = MemoryStation(Map("TEST_PLUG_APIKEY", "tok!en 1"), null);
            Bind(st, new object(), st.Options(Map()));

            string url = "http://localhost:8000/api/todo?token=%5Bstation%3Atest-plug%5D";
            Exception caught = null;
            try
            {
                st.Transport("test-plug", url, Map("url", url, "headers", Map()), true, null,
                    (wireurl, def) => throw new InvalidOperationException("fetch failed",
                        new UriFormatException("bad url: " + wireurl)));
            }
            catch (Exception err)
            {
                caught = err;
            }
            Check(null != caught, "the transport error surfaces");
            Check("fetch failed" == caught.Message, "the message reads as it did: " + caught.Message);
            Check(null == caught.InnerException, "an inner exception quoting the URL is dropped");
            Check(!caught.ToString().Contains("tok%21en%201"), "scrubbed: " + caught);
        });

        TestCase("transport: an error quoting only the fetchdef url is scrubbed", () =>
        {
            Station st = MemoryStation(Map("TEST_PLUG_APIKEY", "tok!en 1"), null);
            Bind(st, new object(), st.Options(Map()));

            string defurl = "http://localhost:8000/api/todo?token=%5Bstation%3Atest-plug%5D";
            Exception caught = null;
            try
            {
                st.Transport("test-plug", "http://localhost:8000/api/todo",
                    Map("url", defurl, "headers", Map()), true, null,
                    (wireurl, def) => throw new InvalidOperationException("failed: GET " + def["url"]));
            }
            catch (Exception err)
            {
                caught = err;
            }
            Check(null != caught, "the transport error surfaces");
            Check(!caught.Message.Contains("tok%21en%201"), "scrubbed: " + caught.Message);
            Check(caught.Message.Contains("[redacted]"), "scrub marker: " + caught.Message);
        });

        TestCase("hooks: one failed operation emits one op event", () =>
        {
            Station st = MemoryStation(Map("TEST_PLUG_APIKEY", "real-key-3"), null);
            Bind(st, new object(), st.Options(Map()));

            // PreDone sees the error result; the pipeline then throws it.
            string corr = st.NextCorr();
            long start = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            st.OpEvent("test-plug", corr, start, "note", "load", "err");
            st.OpEvent("test-plug", corr, start, "note", "load", "unexpected");
            st.OpEvent("test-plug", corr, start, "note", "load", "unexpected");

            var outcomes = new List<string>();
            foreach (var ev in st.Events())
            {
                if ("op".Equals(ev["kind"]))
                {
                    outcomes.Add((string)((IDictionary<string, object>)ev["op"])["outcome"]);
                }
            }
            Check("err" == string.Join(",", outcomes), "one op event: " + string.Join(",", outcomes));

            st.OpEvent("test-plug", null, null, "note", "load", "unexpected");
            int count = 0;
            foreach (var ev in st.Events())
            {
                count += "op".Equals(ev["kind"]) ? 1 : 0;
            }
            Check(1 == count, "an operation station never opened emits nothing");
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

        TestCase("transport: the http event's path keeps the request's escapes", () =>
        {
            Station st = MemoryStation(Map(), null);
            Bind(st, new object(), st.Options(Map()));
            string[][] cases =
            {
                new[] { "https://h/vault/projects%2Flaunch%20plan.md", "h",
                    "/vault/projects%2Flaunch%20plan.md" },
                new[] { "https://h", "h", "/" },
                new[] { "/vault/projects%2Flaunch%20plan.md?x=1", "",
                    "/vault/projects%2Flaunch%20plan.md?x=1" },
            };
            var want = new List<string>();
            foreach (var c in cases)
            {
                st.Transport("test-plug", c[0], Map("method", "GET"), false, null,
                    (url, def) => Map("status", 200));
                want.Add(c[1] + " " + c[2]);
            }
            var got = new List<string>();
            foreach (var ev in st.Events())
            {
                if ("http".Equals(ev.GetValueOrDefault("kind")))
                {
                    var hm = Descriptor.AsMap(ev["http"]);
                    got.Add(hm["host"] + " " + hm["path"]);
                }
            }
            string gotText = string.Join(" | ", got);
            string wantText = string.Join(" | ", want);
            Check(wantText == gotText, "host and path of each request\n  got:  "
                + gotText + "\n  want: " + wantText);
        });

        TestCase("transport: the http event's host reads as URL.host does", () =>
        {
            Station st = MemoryStation(Map(), null);
            Bind(st, new object(), st.Options(Map()));
            string[][] cases =
            {
                new[] { "https://h:443/x", "h", "/x" },
                new[] { "http://h:80/x", "h", "/x" },
                new[] { "https://h:8443/x", "h:8443", "/x" },
                new[] { "https://u:p@h/x", "h", "/x" },
                new[] { "http://[::1]:8080/x", "[::1]:8080", "/x" },
                new[] { "http://[::1]/x", "[::1]", "/x" },
                new[] { "https://H/x", "h", "/x" },
                new[] { "https://h:/x", "h", "/x" },
                new[] { "https://h:0443/x", "h", "/x" },
                new[] { "https://h:08443/x", "h:8443", "/x" },
            };
            var want = new List<string>();
            foreach (var c in cases)
            {
                st.Transport("test-plug", c[0], Map("method", "GET"), false, null,
                    (url, def) => Map("status", 200));
                want.Add(c[1] + " " + c[2]);
            }
            var got = new List<string>();
            foreach (var ev in st.Events())
            {
                if ("http".Equals(ev.GetValueOrDefault("kind")))
                {
                    var hm = Descriptor.AsMap(ev["http"]);
                    got.Add(hm["host"] + " " + hm["path"]);
                }
            }
            string gotText = string.Join(" | ", got);
            string wantText = string.Join(" | ", want);
            Check(wantText == gotText, "host and path of each request\n  got:  "
                + gotText + "\n  want: " + wantText);
        });

        TestCase("transport: an http event keeps no userinfo of a URL reported whole", () =>
        {
            Station st = MemoryStation(Map(), null);
            Bind(st, new object(), st.Options(Map()));
            foreach (string url in new[] { "https://u:s3cret@h x/y", "https://u:p@h:99999/x", "https://u:p@ss@h/x" })
            {
                st.Transport("test-plug", url, Map("method", "GET"), false, null,
                    (u, def) => Map("status", 200));
            }
            foreach (var ev in st.Events())
            {
                if ("http".Equals(ev.GetValueOrDefault("kind")))
                {
                    var hm = Descriptor.AsMap(ev["http"]);
                    string shown = hm["host"] + " " + hm["path"];
                    Check(!shown.Contains("s3cret") && !shown.Contains("u:p@"), shown);
                }
            }
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

        // An IPv6 host keeps its brackets, and neither a port nor the
        // userinfo, a raw `@` in its password among it, reaches the host.
        TestCase("transport: policy mode block refuses with its own code", () =>
        {
            foreach (var policy in new[] { Map("mode", "block"),
                Map("mode", "block", "hosts", Vals("api.good.example")) })
            {
                Station st = MemoryStation(Map("TEST_PLUG_APIKEY", "k"), Map(
                    "test-plug", Map("policy", policy)));
                Bind(st, new object(), st.Options(Map()));
                bool called = false;
                string code = null;
                string message = "";
                try
                {
                    st.Transport("test-plug", "http://api.good.example/x", Map("headers", Map()),
                        true, null, (url, def) =>
                        {
                            called = true;
                            return Map("status", 200);
                        });
                }
                catch (StationError err)
                {
                    code = err.Code;
                    message = err.Message;
                }
                Check(!called, "the transport is not called");
                Check("station_blocked" == code, "code: " + code);
                Check(message.Contains("mode \"block\""), message);
                var codes = new List<object>();
                foreach (var ev in st.Events())
                {
                    if ("error".Equals(ev["kind"]))
                    {
                        codes.Add(Descriptor.GetProp(ev["err"], "code"));
                    }
                }
                Check(1 == codes.Count && "station_blocked".Equals(codes[0]),
                    "one error event: " + string.Join(",", codes));
            }
        });

        TestCase("transport: policy modes that need a proxy fail station_no_proxy", () =>
        {
            foreach (string mode in new[] { "record", "replay", "mock" })
            {
                Station st = MemoryStation(Map("TEST_PLUG_APIKEY", "k"), Map(
                    "test-plug", Map("policy", Map("mode", mode))));
                Bind(st, new object(), st.Options(Map()));
                string code = null;
                try
                {
                    st.Transport("test-plug", "http://api.good.example/x", Map("headers", Map()),
                        true, null, (url, def) => Map("status", 200));
                }
                catch (StationError err)
                {
                    code = err.Code;
                }
                Check("station_no_proxy" == code, mode + ": " + code);
            }
        });

        TestCase("transport: policy mode live or absent passes, and only live is gated", () =>
        {
            var cases = new (Dictionary<string, object> Policy, bool Live)[]
            {
                (Map("mode", "live"), true),
                (Map("hosts", Vals("api.good.example")), true),
                (Map("mode", "block"), false),
            };
            foreach (var c in cases)
            {
                Station st = MemoryStation(Map("TEST_PLUG_APIKEY", "k"), Map(
                    "test-plug", Map("policy", c.Policy)));
                Bind(st, new object(), st.Options(Map()));
                object res = st.Transport("test-plug", "http://api.good.example/x",
                    Map("headers", Map()), c.Live, null, (url, def) => Map("status", 200));
                Check(res is Dictionary<string, object>, "passes");
            }
        });

        TestCase("transport: the hosts policy compares the hostname URL.hostname reads", () =>
        {
            var cases = new (string Host, string Url, bool Allowed)[]
            {
                ("[::1]", "http://[::1]:8080/x", true),
                ("[::1]", "http://[::2]:8080/x", false),
                ("api.test", "https://api.test:443/x", true),
                ("api.test", "https://evil.test:443/x", false),
                ("api.test", "https://u:p@ss@api.test/x", true),
                ("api.test", "https://api.test:x@evil.test/x", false),
                ("api.test", "https://API.TEST/x", true),
                ("api.test", "https://EVIL.TEST/x", false),
            };
            foreach (var c in cases)
            {
                Station st = MemoryStation(Map("TEST_PLUG_APIKEY", "k"), Map(
                    "test-plug", Map("policy", Map("hosts", Vals(c.Host)))));
                Bind(st, new object(), st.Options(Map()));
                string code = null;
                try
                {
                    st.Transport("test-plug", c.Url, Map("headers", Map()), true, null,
                        (url, def) => Map("status", 200));
                }
                catch (StationError err)
                {
                    code = err.Code;
                }
                Check((c.Allowed ? null : "station_host_allow") == code,
                    c.Host + " against " + c.Url + ": " + code);
            }
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
