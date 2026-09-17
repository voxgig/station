// The secret broker (station design 5): sekreto resolves, station places.
// The broker holds resolved values privately - they never enter options,
// events, or captures; the SDK sees only the placeholder.
//
// A port of typescript/src/secrets.ts, which is canonical.

package com.voxgig.station;

import com.voxgig.sekreto.Sekreto;
import com.voxgig.sekreto.Sekreto.SekretoError;
import com.voxgig.sekreto.plugins.Plugins;

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

  /**
   * Design 7.2: keyed by INSTANCE. Two live instances of one api MUST have
   * distinct placeholders or the injection seam cannot tell which
   * credential a header wants. For an untagged instance this is the api
   * slug, so the single-instance case is unchanged to the byte.
   */
  public static String placeholderFor(String name) {
    return "[station:" + name + "]";
  }

  /**
   * Providers arrive in sekreto's own declarative ProviderSpec form,
   * passed through untouched (design 5.2) - station neither extends nor
   * validates it, so every provider sekreto gains is available the day it
   * lands.
   */
  public SecretBroker(Object providerSpecs) {
    // One Options, not makechain + chainnames + the three-argument
    // constructor: sekreto folded the named-chain pair into the
    // constructor when its provider kinds moved onto voxgig/plugin
    // (sekreto 43eb579). The store name a chain entry answers to is now
    // carried in the spec itself, so the names no longer travel beside
    // the chain. Caching stays on - it is the default, which is what the
    // old `true` asked for.
    //
    // Plugins.ALL, because a control surface does not get to choose the
    // chain: the profile does, at run time, and station must honour any
    // kind a station.json names. sekreto's split put everything except
    // dotenv/env/file/memory behind a plugin definition the caller passes
    // in, so without this a profile naming `hashicorp` - or `minivault` -
    // fails at open() with "unknown provider kind". Same call as the go
    // port's plugins.All(), for the same reason.
    this.sekreto = new Sekreto(new Sekreto.Options()
        .plugins(Plugins.ALL)
        .providers(providerSpecs));
  }

  public synchronized void hoist(String instance, String value) {
    overrides.put(instance, value);
    held.add(value);
  }

  /**
   * Resolve the value for a plugin's secret name. Misses and store errors
   * keep sekreto's distinction (design 5.2): a miss is
   * station_secret_no_value, a store that could not answer is
   * station_secret_error with sekreto's message intact - and never a
   * retry against a weaker store (sekreto owns the chain).
   *
   * <p>OVERRIDES ARE KEYED BY INSTANCE; THE RESOLUTION CACHE IS KEYED BY
   * SECRET NAME (design 5.3). A hoisted credential belongs to the one
   * instance it was resident in, but a resolved VALUE belongs to the name
   * it was resolved for - so several instances sharing one api-level
   * `secret` cost one lookup rather than one each, and every client an
   * auto-tagged create() produces shares the declared instance's entry
   * instead of re-resolving per request. Keying the cache by instance
   * instead is the defect this replaces: at 26 instances over 20 apis it
   * turns one store round-trip into 26.
   */
  public synchronized String value(String instance, String name) {
    String override = overrides.get(instance);
    if (null != override) {
      return override;
    }

    String cached = cache.get(name);
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
            "no store had \"" + name + "\" for plugin \"" + instance + "\"");
      }
      throw new StationError("station_secret_error", message);
    }

    cache.put(name, value);
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
