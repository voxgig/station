// The secret broker (station design 5): sekreto resolves, station places.
// The broker holds resolved values privately - they never enter options,
// events, or captures; the SDK sees only the placeholder.
//
// A port of typescript/src/secrets.ts, which is canonical.

package com.voxgig.station;

import com.voxgig.sekreto.Provider;
import com.voxgig.sekreto.Providers;
import com.voxgig.sekreto.Sekreto;
import com.voxgig.sekreto.Sekreto.SekretoError;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

public class SecretBroker {

  private final Sekreto sekreto;

  // Values hoisted by adopt-style binding from a resident options apikey
  // (design 3.1).
  private final Map<String, String> overrides = new LinkedHashMap<>();
  private final Map<String, String> cache = new LinkedHashMap<>();

  // Every value this broker ever held, for the exact-value scrub.
  private final List<String> held = new ArrayList<>();

  public static String placeholderFor(String slug) {
    return "[station:" + slug + "]";
  }

  /**
   * Providers arrive in sekreto's own declarative ProviderSpec form,
   * passed through untouched (design 5.2) - station neither extends nor
   * validates it, so every provider sekreto gains is available the day it
   * lands.
   */
  public SecretBroker(Object providerSpecs) {
    List<Provider> chain = Providers.makechain(providerSpecs);
    List<String> names = Providers.chainnames(providerSpecs);
    this.sekreto = new Sekreto(chain, names, true);
  }

  public synchronized void hoist(String slug, String value) {
    overrides.put(slug, value);
    held.add(value);
  }

  /**
   * Resolve the value for a plugin's secret name. Misses and store errors
   * keep sekreto's distinction (design 5.2): a miss is
   * station_secret_no_value, a store that could not answer is
   * station_secret_error with sekreto's message intact - and never a
   * retry against a weaker store (sekreto owns the chain).
   */
  public synchronized String value(String slug, String name) {
    String override = overrides.get(slug);
    if (null != override) {
      return override;
    }

    String cached = cache.get(slug);
    if (null != cached) {
      return cached;
    }

    String value;
    try {
      value = sekreto.get(name);
    } catch (SekretoError err) {
      String message = null == err.getMessage() ? "" : err.getMessage();
      if (message.contains("unknown secret")) {
        throw new StationError("station_secret_no_value",
            "no store had \"" + name + "\" for plugin \"" + slug + "\"");
      }
      throw new StationError("station_secret_error", message);
    }

    cache.put(slug, value);
    held.add(value);
    return value;
  }

  /**
   * Exact-value scrub, deliberately WITHOUT sekreto's four-character
   * readability floor (design 7 as revised): on boundaries where the
   * promise is absolute, every held value is scrubbed whatever its
   * length. sekreto's own redact() runs too, covering values resolved by
   * the underlying instance that station never held.
   */
  public synchronized String scrub(String text) {
    String out = sekreto.redact(null == text ? "" : text);
    for (String value : held) {
      if (!value.isEmpty()) {
        out = out.replace(value, "[redacted]");
      }
    }
    return out;
  }

  /**
   * Drop caches so the next resolve asks the stores again (rotation
   * support rides on sekreto's refresh, design 5.3).
   */
  public synchronized void refresh() {
    cache.clear();
    sekreto.refresh();
  }
}
