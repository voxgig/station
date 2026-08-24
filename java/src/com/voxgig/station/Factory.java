// The factory table (station design 6.2).
//
// A FACTORY IS A CONSTRUCTOR *PLUS* THE SDK'S STATIC CONFIG, not a bare
// function, and leaving the second half out is a hole.
//
// Station composes the ordered feature array FOR the constructor, so it
// needs the transport roles and the feature option schemas BEFORE
// construction - but the adapter builds and registers its descriptor
// DURING construction. Nothing would be known in time. The config IS
// available: the generated package emits it as a class-level constant, so
// it exists as soon as the package is linked.
//
// Station normalizes the descriptor AT PROVIDE TIME, and three things
// follow:
//
//  - the per-api descriptor cache is populated at REGISTRATION rather than
//    on first construction;
//  - check() can validate every instance's feature config WITHOUT
//    constructing anything;
//  - the adapter's registration during construction becomes a
//    RECONCILIATION - same descriptor, now bound to a live client - rather
//    than the first sighting.
//
// The table is PROCESS-GLOBAL because path 1 of design 6.2 is module
// self-registration, which happens once per process and not once per
// Station.
//
// A port of typescript/src/factory.ts, which is canonical.

package com.voxgig.station;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.ServiceLoader;
import java.util.TreeSet;

public final class Factory {

  /** The generated constructor, as station calls it. */
  @FunctionalInterface
  public interface Construct {
    Object construct(Map<String, Object> options);
  }

  /**
   * The service interface path 1 uses. A JAVA `import` IS A COMPILE-TIME
   * NAME ALIAS: it loads nothing and runs no static initializer, so the
   * Go/Python/Ruby spelling of self-registration - a module-init hook that
   * actually runs - does not exist here. Java's executable bootstrap is
   * {@link ServiceLoader}: a generated package ships a
   * `META-INF/services/com.voxgig.station.Factory$Registrar` entry naming
   * an implementation, and merely being on the classpath is then enough.
   */
  public interface Registrar {
    /** The api slug this package provides. */
    String api();

    /** Its constructor plus its embedded config. */
    Factory factory();
  }

  public final Construct construct;
  public final Object config;

  public Factory(Construct construct, Object config) {
    this.construct = construct;
    this.config = config;
  }

  /** A registered api: the factory plus its descriptor, normalized once. */
  public static final class Entry {
    public final String api;
    public final Construct construct;
    public final Object config;
    public final Map<String, Object> descriptor;
    public final List<String> warnings;

    Entry(String api, Construct construct, Object config,
        Map<String, Object> descriptor, List<String> warnings) {
      this.api = api;
      this.construct = construct;
      this.config = config;
      this.descriptor = descriptor;
      this.warnings = warnings;
    }
  }

  private static final Map<String, Entry> TABLE = new LinkedHashMap<>();
  private static boolean servicesLoaded = false;

  /**
   * Register an api's constructor/config pair.
   *
   * <p>IDEMPOTENT per api: registering the SAME pair twice is a no-op,
   * because self-registration plus an explicit provide() for one api is an
   * ordinary thing for an application to end up with. A second registration
   * with a DIFFERENT factory is station_factory_conflict - silently picking
   * one of two SDK builds is not a thing to do quietly.
   */
  public static synchronized Entry provide(Object api, Factory factory) {
    String slug = String.valueOf(api);
    Entry prior = TABLE.get(slug);
    if (null != prior) {
      if (prior.construct == factory.construct && prior.config == factory.config) {
        return prior;
      }
      throw new StationError("station_factory_conflict",
          "two different factories registered for api \"" + slug + "\"; a "
              + "process has one build of an SDK, and picking between two "
              + "silently is not a thing to do quietly");
    }

    // AT PROVIDE TIME, which is the whole point of carrying `config`.
    Descriptor.Normalized normalized =
        Descriptor.normalizeDescriptor(factory.config, null);
    Entry entry = new Entry(slug, factory.construct, factory.config,
        normalized.descriptor, normalized.warnings);
    TABLE.put(slug, entry);
    return entry;
  }

  /** The registered factory for an api, or null. */
  public static synchronized Entry factoryFor(Object api) {
    services();
    return TABLE.get(String.valueOf(api));
  }

  /** The api slugs currently registered, sorted. */
  public static synchronized List<String> provided() {
    services();
    return new ArrayList<>(new TreeSet<>(TABLE.keySet()));
  }

  /**
   * Test seam. The table is process-global by design, so a suite that
   * registers factories has to be able to put the process back. The
   * ServiceLoader sweep is re-armed too, so a suite can prove it runs.
   */
  public static synchronized void resetFactories() {
    TABLE.clear();
    servicesLoaded = false;
  }

  /**
   * Path 1, once per process: every {@link Registrar} the classpath
   * declares. A registrar that throws is not allowed to take the process
   * down - it is one SDK's packaging problem, and the api it would have
   * provided then fails station_no_factory at first use, which names the
   * remedies.
   */
  private static void services() {
    if (servicesLoaded) {
      return;
    }
    servicesLoaded = true;
    for (Registrar registrar : ServiceLoader.load(
        Registrar.class, Factory.class.getClassLoader())) {
      try {
        provide(registrar.api(), registrar.factory());
      } catch (StationError err) {
        throw err;
      } catch (RuntimeException ignored) {
        // A broken registrar is that package's problem, not the process's.
      }
    }
  }
}
