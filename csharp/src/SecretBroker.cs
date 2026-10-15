// The secret broker (station design 5): sekreto resolves, station places.
// The broker holds resolved values privately - they never enter options,
// events, or captures; the SDK sees only the placeholder.
//
// A port of typescript/src/secrets.ts, which is canonical.

using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

using Voxgig.Sekreto;
using Voxgig.Sekreto.Plugins;

namespace Voxgig.Station
{
    public class SecretBroker
    {
        /// <summary>A substituted URL plus its header copy.</summary>
        public sealed class Substituted
        {
            public readonly string Url;
            public readonly Dictionary<string, object> Headers;

            internal Substituted(string url, Dictionary<string, object> headers)
            {
                Url = url;
                Headers = headers;
            }
        }

        private readonly Sekreto.Sekreto sekreto;

        // Values hoisted by adopt-style binding from a resident options
        // apikey (design 3.1).
        private readonly Dictionary<string, string> overrides =
            new Dictionary<string, string>();
        private readonly Dictionary<string, string> cache =
            new Dictionary<string, string>();

        // Every value this broker ever held, for the exact-value scrub.
        private readonly List<string> held = new List<string>();

        private readonly object gate = new object();

        public static string PlaceholderFor(string slug)
        {
            return "[station:" + slug + "]";
        }

        /// <summary>
        /// Every UTF-8 byte outside RFC 3986's unreserved set becomes upper-case %XX.
        /// </summary>
        public static string EncodeQueryValue(string value)
        {
            var out_ = new StringBuilder();
            foreach (byte b in Encoding.UTF8.GetBytes(value ?? ""))
            {
                if (IsUnreserved(b))
                {
                    out_.Append((char)b);
                }
                else
                {
                    out_.Append('%').Append(b.ToString("X2", CultureInfo.InvariantCulture));
                }
            }
            return out_.ToString();
        }

        /// <summary>
        /// The placeholder becomes the value in header values and in the URL
        /// query, where an SDK percent-encodes it (any hex case) and the value
        /// is encoded in turn. The path and fragment are never touched; the
        /// headers are a copy.
        /// </summary>
        public static Substituted Substitute(string url, IDictionary<string, object> headers,
            string placeholder, string value)
        {
            var out_ = null == headers
                ? new Dictionary<string, object>()
                : new Dictionary<string, object>(headers);
            if (string.IsNullOrEmpty(placeholder))
            {
                return new Substituted(url, out_);
            }

            foreach (string name in new List<string>(out_.Keys))
            {
                if (out_[name] is string text && text.Contains(placeholder))
                {
                    out_[name] = text.Replace(placeholder, value);
                }
            }

            int q = url.IndexOf('?');
            int hash = url.IndexOf('#');
            if (0 > q || (0 <= hash && hash < q))
            {
                return new Substituted(url, out_);
            }
            int end = 0 > hash ? url.Length : hash;
            string encoded = EncodeQueryValue(value);
            var query = new StringBuilder();
            for (int i = q + 1; i < end;)
            {
                int n = MatchAt(url, i, end, placeholder);
                if (0 < n)
                {
                    query.Append(encoded);
                    i += n;
                }
                else
                {
                    query.Append(url[i]);
                    i++;
                }
            }
            return new Substituted(
                url.Substring(0, q + 1) + query.ToString() + url.Substring(end), out_);
        }

        // Every form of every value is matched against the original text and
        // the union of the matches redacted, so no replacement can hide
        // another form.
        private static string RedactValues(string text, List<string> values)
        {
            var forms = new List<string>();
            foreach (string value in values)
            {
                if (0 != value.Length)
                {
                    forms.Add(value);
                    forms.Add(EncodeQueryValue(value));
                }
            }
            var out_ = new StringBuilder();
            for (int i = 0; i < text.Length;)
            {
                int stop = Reach(text, i, forms);
                if (stop == i)
                {
                    out_.Append(text[i]);
                    i++;
                    continue;
                }
                for (int j = i + 1; j < stop; j++)
                {
                    int end = Reach(text, j, forms);
                    if (end > stop)
                    {
                        stop = end;
                    }
                }
                out_.Append("[redacted]");
                i = stop;
            }
            return out_.ToString();
        }

        private static int Reach(string text, int at, List<string> forms)
        {
            int end = at;
            foreach (string form in forms)
            {
                if (at + form.Length > end && at + form.Length <= text.Length
                    && 0 == string.CompareOrdinal(text, at, form, 0, form.Length))
                {
                    end = at + form.Length;
                }
            }
            return end;
        }

        private static int MatchAt(string text, int at, int end, string placeholder)
        {
            int i = at;
            foreach (char ch in placeholder)
            {
                if (i < end && text[i] == ch)
                {
                    i++;
                    continue;
                }
                if (i + 3 <= end && '%' == text[i])
                {
                    int hi = HexValue(text[i + 1]);
                    int lo = HexValue(text[i + 2]);
                    if (0 <= hi && 0 <= lo && hi * 16 + lo == ch)
                    {
                        i += 3;
                        continue;
                    }
                }
                return -1;
            }
            return i - at;
        }

        private static int HexValue(char c)
        {
            if ('0' <= c && c <= '9')
            {
                return c - '0';
            }
            if ('A' <= c && c <= 'F')
            {
                return c - 'A' + 10;
            }
            if ('a' <= c && c <= 'f')
            {
                return c - 'a' + 10;
            }
            return -1;
        }

        private static bool IsUnreserved(byte b)
        {
            return ('A' <= b && b <= 'Z') || ('a' <= b && b <= 'z') || ('0' <= b && b <= '9')
                || '-' == b || '.' == b || '_' == b || '~' == b;
        }

        /// <summary>
        /// Providers arrive in sekreto's own declarative ProviderSpec form,
        /// passed through untouched (design 5.2) - station neither extends
        /// nor validates it, so every provider sekreto gains is available the
        /// day it lands.
        /// </summary>
        public SecretBroker(object providerSpecs)
        {
            // One SekretoOptions, not MakeChain + ChainNames + the
            // three-argument constructor: sekreto folded the named-chain
            // pair into the constructor when its provider kinds moved onto
            // voxgig/plugin (sekreto 43eb579). The store name a chain entry
            // answers to is carried in the spec itself now, so the names no
            // longer travel beside the chain. Caching stays on - it is the
            // default, which is what the old `true` asked for.
            //
            // SekretoPlugins.All(), because a control surface does not get
            // to choose the chain: the profile does, at run time, and
            // station must honour any kind a station.json names. sekreto's
            // split put everything except dotenv/env/file/memory behind a
            // plugin definition the caller passes in, so without this a
            // profile naming `hashicorp` - or `minivault` - fails at Open()
            // with "unknown provider kind". Same call as the go port's
            // plugins.All(), for the same reason.
            List<object> specs = new List<object>();
            if (providerSpecs is IEnumerable given && !(providerSpecs is string))
            {
                foreach (object spec in given)
                {
                    specs.Add(spec);
                }
            }
            else if (null != providerSpecs)
            {
                specs.Add(providerSpecs);
            }

            sekreto = new Sekreto.Sekreto(new SekretoOptions
            {
                Plugins = SekretoPlugins.All(),
                Providers = specs,
            });
        }

        public void Hoist(string slug, string value)
        {
            lock (gate)
            {
                overrides[slug] = value;
                held.Add(value);
            }
        }

        /// <summary>
        /// Resolve the value for a plugin's secret name. Misses and store
        /// errors keep sekreto's distinction (design 5.2): a miss is
        /// station_secret_no_value, a store that could not answer is
        /// station_secret_error with sekreto's message intact - and never a
        /// retry against a weaker store (sekreto owns the chain).
        /// </summary>
        public string Value(string slug, string name)
        {
            lock (gate)
            {
                if (overrides.TryGetValue(slug, out string over))
                {
                    return over;
                }

                if (cache.TryGetValue(slug, out string cached))
                {
                    return cached;
                }

                string value;
                try
                {
                    value = sekreto.Get(name);
                }
                catch (SekretoError err)
                {
                    string message = err.Message ?? "";
                    if (message.Contains("unknown secret"))
                    {
                        throw new StationError("station_secret_no_value",
                            "no store had \"" + name + "\" for plugin \"" + slug + "\"");
                    }
                    throw new StationError("station_secret_error", message);
                }

                cache[slug] = value;
                held.Add(value);
                return value;
            }
        }

        /// <summary>
        /// Exact-value scrub, deliberately WITHOUT sekreto's four-character
        /// readability floor (design 7 as revised): on boundaries where the
        /// promise is absolute, every held value is scrubbed whatever its
        /// length. sekreto's own Redact() runs after, covering values resolved
        /// by the underlying instance that station never held; run first, its
        /// raw-value replacement could split an encoded form.
        /// </summary>
        public string Scrub(string text)
        {
            lock (gate)
            {
                return sekreto.Redact(RedactValues(text ?? "", held));
            }
        }

        /// <summary>
        /// Drop caches so the next resolve asks the stores again (rotation
        /// support rides on sekreto's Refresh, design 5.3).
        /// </summary>
        public void Refresh()
        {
            lock (gate)
            {
                cache.Clear();
                sekreto.Refresh();
            }
        }
    }
}
