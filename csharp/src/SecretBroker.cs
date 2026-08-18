// The secret broker (station design 5): sekreto resolves, station places.
// The broker holds resolved values privately - they never enter options,
// events, or captures; the SDK sees only the placeholder.
//
// A port of typescript/src/secrets.ts, which is canonical.

using System.Collections.Generic;

using Voxgig.Sekreto;

namespace Voxgig.Station
{
    public class SecretBroker
    {
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
        /// Providers arrive in sekreto's own declarative ProviderSpec form,
        /// passed through untouched (design 5.2) - station neither extends
        /// nor validates it, so every provider sekreto gains is available the
        /// day it lands.
        /// </summary>
        public SecretBroker(object providerSpecs)
        {
            List<IProvider> chain = Providers.MakeChain(providerSpecs);
            List<string> names = Providers.ChainNames(providerSpecs);
            sekreto = new Sekreto.Sekreto(chain, names, true);
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
        /// length. sekreto's own Redact() runs too, covering values resolved
        /// by the underlying instance that station never held.
        /// </summary>
        public string Scrub(string text)
        {
            lock (gate)
            {
                string out_ = sekreto.Redact(text ?? "");
                foreach (string value in held)
                {
                    if (0 != value.Length)
                    {
                        out_ = out_.Replace(value, "[redacted]");
                    }
                }
                return out_;
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
