// The descriptor normalizer and canonical serializer (station design 4):
// a generated SDK's embedded config, normalized into descriptor v1 - a
// VIEW over the config, never a second model - plus the one canonical
// byte serialization every port must agree on.
//
// A port of typescript/src/descriptor.ts, which is canonical.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace Voxgig.Station
{
    public static class Descriptor
    {
        private static readonly Regex NonToken = new Regex("[^A-Z0-9]+", RegexOptions.Compiled);
        private static readonly Regex EdgeUnderscores = new Regex("^_+|_+$", RegexOptions.Compiled);

        /// <summary>A normalized descriptor plus any legacy warnings.</summary>
        public sealed class Normalized
        {
            public readonly Dictionary<string, object> Descriptor;
            public readonly List<string> Warnings;

            internal Normalized(Dictionary<string, object> descriptor, List<string> warnings)
            {
                Descriptor = descriptor;
                Warnings = warnings;
            }
        }

        /// <summary>
        /// The ONLY way to build an env-var token in station, mirroring
        /// sdkgen's packageMeta envToken exactly: 'gnarly-pets' ->
        /// 'GNARLY_PETS'. The `secretname` corpus section pins the round-trip
        /// against sekreto's EnvKey() and sdkgen's envName() - the one place
        /// three grammars meet.
        /// </summary>
        public static string EnvToken(object name)
        {
            string text = null == name ? "" : Convert.ToString(name, CultureInfo.InvariantCulture);
            return EdgeUnderscores.Replace(
                NonToken.Replace((text ?? "").ToUpperInvariant(), "_"), "");
        }

        /// <summary>
        /// The default sekreto name for a plugin (design 5.1): EnvToken(slug)
        /// lowercased, plus '.apikey'. sekreto's EnvKey() then yields exactly
        /// the env var the SDK's README documents: gnarly_pets.apikey ->
        /// GNARLY_PETS_APIKEY.
        /// </summary>
        public static string SecretnameDefault(string slug)
        {
            return EnvToken(slug).ToLowerInvariant() + ".apikey";
        }

        // Best-effort slug from a camel name, for SDKs whose embedded config
        // predates main.slug (design 4 legacy sentinels). The hyphen caveat is
        // real: 'VoxgigSolardemo' -> 'voxgigsolardemo', NOT 'voxgig-solardemo'
        // - callers surface a warning event when this path is taken.
        internal static string LegacySlug(string name)
        {
            return (null == name ? "" : name).ToLowerInvariant();
        }

        /// <summary>
        /// Normalize a generated SDK's embedded config into descriptor v1
        /// (design 4). The config is the one every SDK carries (Config.main /
        /// .feature / .options / .entity); the descriptor is a VIEW over it.
        /// Returns the descriptor plus any legacy warnings.
        /// </summary>
        public static Normalized NormalizeDescriptor(object config, object activeFeatures)
        {
            var warnings = new List<string>();
            Dictionary<string, object> main = AsMap(GetProp(config, "main"));
            Dictionary<string, object> options = AsMap(GetProp(config, "options"));

            string name = TextOr(main.GetValueOrDefault("name"), "");
            string slug = TextOr(main.GetValueOrDefault("slug"), "");
            if (0 == slug.Length)
            {
                slug = LegacySlug(name);
                warnings.Add("descriptor: legacy config has no main.slug; derived \"" + slug
                    + "\" from the camel name - hyphens in the original name are lost");
            }

            string version = null == main.GetValueOrDefault("version")
                ? "0.0.0" : Convert.ToString(main["version"], CultureInfo.InvariantCulture);
            string target = null == main.GetValueOrDefault("target")
                ? "unknown" : Convert.ToString(main["target"], CultureInfo.InvariantCulture);

            var server = new List<object>();
            Dictionary<string, object> svr = AsMap(options.GetValueOrDefault("server"));
            foreach (string key in SortedKeys(svr))
            {
                server.Add(new Dictionary<string, object>
                {
                    ["name"] = key,
                    ["value"] = Convert.ToString(svr[key], CultureInfo.InvariantCulture),
                });
            }

            bool authActive = null != options.GetValueOrDefault("auth");
            var auth = new Dictionary<string, object>
            {
                ["active"] = authActive,
                ["prefix"] = authActive
                    ? TextOr(GetProp(options["auth"], "prefix"), "") : "",
                ["secretname"] = SecretnameDefault(slug),
            };

            var entities = new Dictionary<string, object>();
            Dictionary<string, object> entdefs = AsMap(GetProp(config, "entity"));
            foreach (string ename in SortedKeys(entdefs))
            {
                Dictionary<string, object> e = AsMap(entdefs[ename]);

                var fields = new Dictionary<string, object>();
                if (e.GetValueOrDefault("fields") is IList<object> fdefs)
                {
                    foreach (object f in fdefs)
                    {
                        object fname = GetProp(f, "name");
                        if (null != f && null != fname)
                        {
                            object kind = GetProp(f, "kind");
                            if (null == kind)
                            {
                                kind = GetProp(f, "type");
                            }
                            fields[Convert.ToString(fname, CultureInfo.InvariantCulture)] =
                                new Dictionary<string, object>
                                {
                                    ["kind"] = null == kind
                                        ? "" : Convert.ToString(kind, CultureInfo.InvariantCulture),
                                };
                        }
                    }
                }

                var ops = new Dictionary<string, object>();
                Dictionary<string, object> opdefs = AsMap(e.GetValueOrDefault("op"));
                foreach (string opname in SortedKeys(opdefs))
                {
                    Dictionary<string, object> op = AsMap(opdefs[opname]);
                    var points = new List<object>();
                    if (op.GetValueOrDefault("points") is IList<object> pdefs)
                    {
                        foreach (object p in pdefs)
                        {
                            if (null == p)
                            {
                                continue;
                            }
                            var point = new Dictionary<string, object>
                            {
                                ["method"] = TextOr(GetProp(p, "method"), ""),
                            };
                            object path = GetProp(p, "orig");
                            if (null == path)
                            {
                                path = GetProp(p, "path");
                            }
                            point["path"] = null == path
                                ? "" : Convert.ToString(path, CultureInfo.InvariantCulture);

                            var pparams = new List<object>();
                            if (GetProp(p, "parts") is IList<object> parts)
                            {
                                foreach (object part in parts)
                                {
                                    if (part is string ptext && ptext.StartsWith(":"))
                                    {
                                        pparams.Add(ptext.Substring(1));
                                    }
                                }
                            }
                            point["params"] = pparams;

                            object select = GetProp(p, "select");
                            if (null != select)
                            {
                                point["select"] = select;
                            }
                            points.Add(point);
                        }
                    }
                    ops[opname] = new Dictionary<string, object> { ["points"] = points };
                }

                entities[ename] = new Dictionary<string, object>
                {
                    ["fields"] = fields,
                    ["ops"] = ops,
                };
            }

            var features = new List<object>();
            Dictionary<string, object> featdefs = AsMap(GetProp(config, "feature"));
            Dictionary<string, object> factive = AsMap(activeFeatures);
            foreach (string fname in SortedKeys(featdefs))
            {
                features.Add(new Dictionary<string, object>
                {
                    ["name"] = fname,
                    ["active"] = true.Equals(GetProp(factive.GetValueOrDefault(fname), "active")),
                });
            }

            var descriptor = new Dictionary<string, object>
            {
                ["station"] = 1,
                ["name"] = name,
                ["slug"] = slug,
                ["envtoken"] = EnvToken(slug),
                ["version"] = version,
                ["target"] = target,
                ["base"] = TextOr(options.GetValueOrDefault("base"), ""),
                ["server"] = server,
                ["auth"] = auth,
                ["entities"] = entities,
                ["features"] = features,
            };

            return new Normalized(descriptor, warnings);
        }

        /// <summary>
        /// Canonical serialization (design 4): UTF-8, object keys sorted
        /// bytewise, no insignificant whitespace, minimal JSON escaping. The
        /// proxy dedupes registrations by a hash of this, so every language
        /// must produce identical bytes - the `canonical-serialize` corpus
        /// section carries the adversarial cases.
        /// </summary>
        public static string CanonicalSerialize(object value)
        {
            var out_ = new StringBuilder();
            Serialize(value, out_);
            return out_.ToString();
        }

        private static void Serialize(object value, StringBuilder out_)
        {
            if (null == value)
            {
                out_.Append("null");
                return;
            }
            if (value is bool flag)
            {
                out_.Append(flag ? "true" : "false");
                return;
            }
            if (value is string text)
            {
                Quote(text, out_);
                return;
            }
            if (IsNumber(value))
            {
                out_.Append(NumStr(value));
                return;
            }
            if (value is IDictionary<string, object> map)
            {
                var keys = new List<string>(map.Keys);
                // Bytewise sort: compare UTF-8 byte sequences, not UTF-16
                // code units.
                keys.Sort(CompareUtf8);
                out_.Append('{');
                bool first = true;
                foreach (string key in keys)
                {
                    if (!first)
                    {
                        out_.Append(',');
                    }
                    first = false;
                    Quote(key, out_);
                    out_.Append(':');
                    Serialize(map[key], out_);
                }
                out_.Append('}');
                return;
            }
            if (value is IList<object> list)
            {
                out_.Append('[');
                for (int index = 0; index < list.Count; index++)
                {
                    if (0 < index)
                    {
                        out_.Append(',');
                    }
                    Serialize(list[index], out_);
                }
                out_.Append(']');
                return;
            }
            out_.Append("null");
        }

        internal static bool IsNumber(object value)
        {
            return value is int || value is long || value is double
                || value is float || value is short || value is byte
                || value is decimal || value is uint || value is ulong
                || value is ushort || value is sbyte;
        }

        // Integral numbers print without a decimal point or exponent, matching
        // the canonical JSON.stringify behaviour (2^53-1 stays exact).
        internal static string NumStr(object value)
        {
            double d = Convert.ToDouble(value, CultureInfo.InvariantCulture);
            if (!double.IsInfinity(d) && d == Math.Floor(d)
                && long.MinValue <= d && d <= long.MaxValue)
            {
                return ((long)d).ToString(CultureInfo.InvariantCulture);
            }
            return d.ToString("R", CultureInfo.InvariantCulture);
        }

        // Minimal JSON escaping: quote, backslash, and control characters
        // only; everything else (non-ASCII included) passes through as UTF-8.
        internal static void Quote(string text, StringBuilder out_)
        {
            out_.Append('"');
            foreach (char c in text)
            {
                switch (c)
                {
                    case '"':
                        out_.Append("\\\"");
                        break;
                    case '\\':
                        out_.Append("\\\\");
                        break;
                    case '\b':
                        out_.Append("\\b");
                        break;
                    case '\f':
                        out_.Append("\\f");
                        break;
                    case '\n':
                        out_.Append("\\n");
                        break;
                    case '\r':
                        out_.Append("\\r");
                        break;
                    case '\t':
                        out_.Append("\\t");
                        break;
                    default:
                        if (c < 0x20)
                        {
                            out_.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                        }
                        else
                        {
                            out_.Append(c);
                        }
                        break;
                }
            }
            out_.Append('"');
        }

        internal static int CompareUtf8(string a, string b)
        {
            // C# bytes are unsigned, so a UTF-8 lead byte (0x80+) already
            // sorts AFTER ASCII without any masking.
            byte[] ab = Encoding.UTF8.GetBytes(a);
            byte[] bb = Encoding.UTF8.GetBytes(b);
            int n = Math.Min(ab.Length, bb.Length);
            for (int index = 0; index < n; index++)
            {
                int c = ab[index].CompareTo(bb[index]);
                if (0 != c)
                {
                    return c;
                }
            }
            return ab.Length.CompareTo(bb.Length);
        }

        // --- small shared helpers (map-shaped data, sekreto style) ---

        public static Dictionary<string, object> AsMap(object val)
        {
            if (val is Dictionary<string, object> map)
            {
                return map;
            }
            if (val is IDictionary<string, object> imap)
            {
                return new Dictionary<string, object>(imap);
            }
            return new Dictionary<string, object>();
        }

        public static object GetProp(object val, string key)
        {
            if (val is IDictionary<string, object> map)
            {
                return map.TryGetValue(key, out object found) ? found : null;
            }
            return null;
        }

        internal static string TextOr(object val, string alt)
        {
            if (val is string text && 0 != text.Length)
            {
                return text;
            }
            return alt;
        }

        private static List<string> SortedKeys(Dictionary<string, object> map)
        {
            var keys = new List<string>(map.Keys);
            keys.Sort(StringComparer.Ordinal);
            return keys;
        }
    }
}
