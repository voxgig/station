// station.json loading and profile resolution (station design 3.5): one
// total order, identical in every library, pinned by the `profile` corpus
// section. The overlay deep-merges per plugin, EXCEPT secrets.providers,
// which replaces wholesale - chain order decides which store wins, so a
// positional merge would be actively dangerous (design 5.2, 11).
//
// A port of typescript/src/profile.ts, which is canonical.

using System;
using System.Collections.Generic;
using System.IO;

using Voxgig.Sekreto;

namespace Voxgig.Station
{
    public static class Profile
    {
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

        /// <summary>
        /// Merge the base profile ('default') with the selected overlay:
        /// deep-merge per plugin, EXCEPT secrets.providers which replaces
        /// wholesale. Returns { name, providers, plugin }; a configured
        /// secret name sekreto would reject fails here (station_secret_name),
        /// at profile load rather than first request (design 14).
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

            var plugin = new Dictionary<string, object>();
            foreach (Dictionary<string, object> src in new[]
            {
                Descriptor.AsMap(baseProfile.GetValueOrDefault("plugin")),
                Descriptor.AsMap(overlay.GetValueOrDefault("plugin")),
            })
            {
                foreach (KeyValuePair<string, object> entry in src)
                {
                    var merged = new Dictionary<string, object>(
                        Descriptor.AsMap(plugin.GetValueOrDefault(entry.Key)));
                    foreach (KeyValuePair<string, object> kv in Descriptor.AsMap(entry.Value))
                    {
                        merged[kv.Key] = kv.Value;
                    }
                    plugin[entry.Key] = merged;
                }
            }

            foreach (KeyValuePair<string, object> entry in plugin)
            {
                object name = Descriptor.GetProp(entry.Value, "secret");
                if (null != name && !Names.ValidName(name))
                {
                    throw new StationError("station_secret_name",
                        "profile \"" + profileName + "\" plugin \"" + entry.Key
                        + "\": secret name rejected by sekreto: \"" + name + "\"");
                }
            }

            return new Dictionary<string, object>
            {
                ["name"] = profileName,
                ["providers"] = providers,
                ["plugin"] = plugin,
            };
        }
    }
}
