// station.json loading and profile resolution (station design 3.3, 3.5):
// one total order, identical in every library, pinned by the `instance`
// corpus section. Instances merge as ONE flat left-to-right pass over
// base.api / base.sdk / overlay.api / overlay.sdk, EXCEPT
// secrets.providers, which replaces wholesale - chain order decides
// which store wins, so a positional merge would be actively dangerous
// (design 5.2, 11).
//
// A port of typescript/src/profile.ts, which is canonical.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text.Json;

using Voxgig.Sekreto;

namespace Voxgig.Station
{
    public static class Profile
    {
        /// <summary>
        /// The one block key carrying the timing rule: applied AFTER the
        /// merge, never before (design 3.3, 4.2).
        /// </summary>
        public static readonly List<string> MERGE_SENSITIVE = new List<string> { "active" };

        /// <summary>
        /// station.json lookup: cwd upward to the repo root, then
        /// ~/.voxgig/station.json (design 3.5). A repo root is where .git
        /// lives; with no repo the walk stops at the filesystem root.
        /// </summary>
        public static string FindConfigFile(string from)
        {
            string dir = Path.GetFullPath(string.IsNullOrEmpty(from)
                ? Directory.GetCurrentDirectory() : from);

            while (true)
            {
                string candidate = Path.Combine(dir, "station.json");
                if (File.Exists(candidate))
                {
                    return candidate;
                }
                bool atRepoRoot = Directory.Exists(Path.Combine(dir, ".git"))
                    || File.Exists(Path.Combine(dir, ".git"));
                string parent = Path.GetDirectoryName(dir);
                if (atRepoRoot || null == parent || parent == dir)
                {
                    break;
                }
                dir = parent;
            }

            string home = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                ".voxgig", "station.json");
            return File.Exists(home) ? home : null;
        }

        /// <summary>The parsed station.json, or null when none is found.</summary>
        public static Dictionary<string, object> LoadConfig(string from)
        {
            string file = FindConfigFile(from);
            if (null == file)
            {
                return null;
            }
            string text = File.ReadAllText(file);
            // A file that is not JSON is a config error, not a raw parser
            // error escaping open(): the reader found station.json and
            // could not use it, which is exactly what
            // station_config_invalid exists to say. sekreto's Json.Parse
            // never throws, so validate through the BCL parser first to
            // capture the real parser message.
            try
            {
                using (JsonDocument.Parse(text))
                {
                }
            }
            catch (JsonException err)
            {
                throw new StationError("station_config_invalid",
                    "station.json at " + file + " is not valid JSON: " + err.Message);
            }
            return Descriptor.AsMap(Json.Parse(text));
        }

        /// <summary>
        /// Profile selection: the open() option, else VOXGIG_STATION_PROFILE,
        /// else 'default' (design 3.5 - open() opts win over env vars, which
        /// win over station.json).
        /// </summary>
        public static string SelectProfile(string optProfile)
        {
            if (!string.IsNullOrEmpty(optProfile))
            {
                return optProfile;
            }
            string env = Environment.GetEnvironmentVariable("VOXGIG_STATION_PROFILE");
            if (!string.IsNullOrEmpty(env))
            {
                return env;
            }
            return "default";
        }

        // The block defaults, allocated FRESH per application so no two
        // instances ever share one `feature` map. `active` is a real JSON
        // boolean - the corpus compares the serialized value.
        private static Dictionary<string, object> BlockDefaults()
        {
            return new Dictionary<string, object>
            {
                ["active"] = true,
                ["feature"] = new Dictionary<string, object>(),
            };
        }

        /// <summary>
        /// The api half of a ref is the substring before the first `$`, and
        /// an untagged ref IS an api slug (design 3.4).
        ///
        /// LEXICAL, and that is the point: under the old free-form identity
        /// which api an instance used was itself a merged value, so a port
        /// that got the phasing wrong silently picked another api's
        /// defaults.
        /// </summary>
        public static string RefApi(string ref_)
        {
            int at = ref_.IndexOf('$');
            return -1 == at ? ref_ : ref_.Substring(0, at);
        }

        // Shallow merge, per key, left to right - each source over the one
        // before it. An overlay's `policy` REPLACES the base's entirely
        // rather than merging `hosts` into it; an allowlist that widens
        // because two precedence levels merged is the failure this rule
        // prevents.
        private static Dictionary<string, object> Shallow(
            params Dictionary<string, object>[] sources)
        {
            var out_ = new Dictionary<string, object>();
            foreach (Dictionary<string, object> src in sources)
            {
                if (null != src)
                {
                    foreach (KeyValuePair<string, object> entry in src)
                    {
                        out_[entry.Key] = entry.Value;
                    }
                }
            }
            return out_;
        }

        // Sorted union of the keys of every map argument (plain ordinal
        // order, the same order JS Array.sort gives the canonical port).
        private static List<string> MergedKeys(params Dictionary<string, object>[] maps)
        {
            var keys = new SortedSet<string>(StringComparer.Ordinal);
            foreach (Dictionary<string, object> m in maps)
            {
                if (null != m)
                {
                    foreach (string key in m.Keys)
                    {
                        keys.Add(key);
                    }
                }
            }
            return new List<string>(keys);
        }

        /// <summary>
        /// Merge the base profile ('default') with the selected overlay.
        ///
        /// Design 3.3's total order for the two block levels, lowest first:
        ///
        ///   base.api[api] + base.sdk[ref] + overlay.api[api] + overlay.sdk[ref]
        ///
        /// PROFILE SPECIFICITY OUTRANKS BLOCK SPECIFICITY, and this is ONE
        /// FLAT LEFT-TO-RIGHT MERGE. It must not be reorganized into
        /// "collapse each namespace, then put instance over api" - that lets
        /// every instance value beat every api value, so a production
        /// `api.stripe.policy` would fail to override a default profile's
        /// `sdk.stripe$test.policy`, silently keeping the wider allowlist in
        /// production.
        ///
        /// `secrets.providers` replaces wholesale, never merges (3.5, 5.2).
        /// Returns { name, providers, api, sdk } as a plain map (the corpus
        /// shape - the `instance` section pins it).
        /// </summary>
        public static Dictionary<string, object> ResolveProfile(object config, string profileName)
        {
            Dictionary<string, object> profiles =
                Descriptor.AsMap(Descriptor.GetProp(config, "profiles"));
            Dictionary<string, object> baseProfile =
                Descriptor.AsMap(profiles.GetValueOrDefault("default"));
            Dictionary<string, object> overlay = "default" == profileName
                ? new Dictionary<string, object>()
                : Descriptor.AsMap(profiles.GetValueOrDefault(profileName));

            object providers = Descriptor.GetProp(overlay.GetValueOrDefault("secrets"), "providers");
            if (null == providers)
            {
                providers = Descriptor.GetProp(baseProfile.GetValueOrDefault("secrets"), "providers");
            }
            if (null == providers)
            {
                providers = new List<object>
                {
                    new Dictionary<string, object> { ["kind"] = "env" },
                };
            }

            Dictionary<string, object> baseApi =
                Descriptor.AsMap(baseProfile.GetValueOrDefault("api"));
            Dictionary<string, object> overApi =
                Descriptor.AsMap(overlay.GetValueOrDefault("api"));
            Dictionary<string, object> baseSdk =
                Descriptor.AsMap(baseProfile.GetValueOrDefault("sdk"));
            Dictionary<string, object> overSdk =
                Descriptor.AsMap(overlay.GetValueOrDefault("sdk"));

            // The api-level defaults in effect for this profile. A REPORT,
            // not an input to the instance merge below.
            var api = new Dictionary<string, object>();
            foreach (string slug in MergedKeys(baseApi, overApi))
            {
                api[slug] = Shallow(
                    Descriptor.AsMap(baseApi.GetValueOrDefault(slug)),
                    Descriptor.AsMap(overApi.GetValueOrDefault(slug)));
            }

            // An api block declares no instance of its own (3.1), so the
            // ref set comes from the two `sdk` maps alone.
            var sdk = new Dictionary<string, object>();
            foreach (string ref_ in MergedKeys(baseSdk, overSdk))
            {
                string a = RefApi(ref_);
                Dictionary<string, object> merged = Shallow(
                    Descriptor.AsMap(baseApi.GetValueOrDefault(a)),
                    Descriptor.AsMap(baseSdk.GetValueOrDefault(ref_)),
                    Descriptor.AsMap(overApi.GetValueOrDefault(a)),
                    Descriptor.AsMap(overSdk.GetValueOrDefault(ref_)));

                // Defaults are applied ONCE, to the fully merged instance.
                // Had the overlay block carried a synthesized `active` into
                // the merge, a one-key environment override would silently
                // re-enable an integration the base declared inactive. Key
                // MEMBERSHIP, not truthiness: an explicit false or {}
                // survives.
                foreach (KeyValuePair<string, object> d in BlockDefaults())
                {
                    if (!merged.ContainsKey(d.Key))
                    {
                        merged[d.Key] = d.Value;
                    }
                }

                sdk[ref_] = merged;
            }

            Checksecrets(sdk, profileName);

            return new Dictionary<string, object>
            {
                ["name"] = profileName,
                ["providers"] = providers,
                ["api"] = api,
                ["sdk"] = sdk,
            };
        }

        // A configured secret name sekreto would reject is caught at
        // profile load, not first request (14 station_secret_name) - and
        // then the DERIVED names are checked for uniqueness, because
        // envtoken is lossy: it collapses any run of non-alphanumerics to
        // `_`, so `stripe$test` and an untagged instance of a `stripe-test`
        // api both derive `stripe_test.apikey` and would silently share one
        // credential.
        //
        // Two instances that EXPLICITLY name one secret are not a collision
        // - that is the shared-key case the api-level `secret` exists for.
        private static void Checksecrets(Dictionary<string, object> sdk, string profileName)
        {
            var refs = new List<string>(sdk.Keys);
            refs.Sort(StringComparer.Ordinal);

            foreach (string ref_ in refs)
            {
                object name = Descriptor.GetProp(sdk[ref_], "secret");
                if (null != name && !Names.ValidName(name))
                {
                    throw new StationError("station_secret_name",
                        "profile \"" + profileName + "\" sdk \"" + ref_
                        + "\": secret name rejected by sekreto: \"" + name + "\"");
                }
            }

            var seen = new Dictionary<string, (string Ref, bool Derived)>();
            foreach (string ref_ in refs)
            {
                object written = Descriptor.GetProp(sdk[ref_], "secret");
                bool derived = null == written || "".Equals(written);
                string name = derived
                    ? Descriptor.SecretnameDefault(ref_)
                    : Convert.ToString(written, CultureInfo.InvariantCulture);

                bool haveprior = seen.TryGetValue(name, out (string Ref, bool Derived) prior);
                if (haveprior && (derived || prior.Derived))
                {
                    throw new StationError("station_secret_collision",
                        "profile \"" + profileName + "\": instances \"" + prior.Ref
                        + "\" and \"" + ref_ + "\" both resolve to secret name \"" + name
                        + "\", so they would share one credential; name it explicitly "
                        + "on each, or at the api level to share it deliberately (5.1)");
                }
                if (!haveprior)
                {
                    seen[name] = (ref_, derived);
                }
            }
        }
    }
}
