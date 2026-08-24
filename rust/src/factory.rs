//! The factory table (design §6.2).
//!
//! A FACTORY IS A CONSTRUCTOR *PLUS* THE SDK'S STATIC CONFIG, not a bare
//! function. Station composes the ordered feature array FOR the
//! constructor, so it needs the transport roles and the feature option
//! schemas BEFORE construction - but the adapter builds and registers its
//! descriptor DURING construction. Nothing would be known in time.
//!
//! The config is available, though: the generated package emits it as a
//! module-level constant, so it exists as soon as the crate is linked and
//! long before any instance is built. Station normalizes the descriptor
//! AT PROVIDE TIME, and three things follow:
//!
//!  - the per-api descriptor cache is populated at REGISTRATION rather
//!    than on first construction;
//!  - `check()` can validate every instance's feature config WITHOUT
//!    constructing anything;
//!  - the adapter's registration during construction becomes a
//!    RECONCILIATION - same descriptor, now bound to a live client -
//!    rather than the first sighting.
//!
//! PROCESS-GLOBAL, PER THREAD. The table is process-global in the
//! canonical library because path 1 of §6.2 is module self-registration,
//! which happens once per process. Rust HAS NO MODULE-INIT HOOK - there
//! is no `func init()` and no import side effect - so path 1 does not
//! exist here (see loader.rs), and everything in it is `Rc<dyn Any>`:
//! neither Send nor Sync, like the whole generated-SDK world this library
//! lives in. So the table is thread-local, exactly as the ambient station
//! is, and `provide` is called once per thread that opens a station.
//! README.md states this.
//!
//! A port of typescript/src/factory.ts, which is canonical.

use std::any::Any;
use std::cell::RefCell;
use std::collections::BTreeMap;
use std::rc::Rc;

use voxgig_sekreto::Json;

use crate::descriptor::normalize_descriptor;
use crate::error::StationError;

/// The generated constructor, as station calls it: station-built options
/// in, a client out.
///
/// The client is `Rc<dyn Any>` because a station library cannot name the
/// generated crate's type - the same opaque identity `BindSpec.client`
/// already crosses the binding seam with. A caller downcasts:
/// `sdk.downcast::<TaskpadSDK>()`.
pub type ConstructFn = Rc<dyn Fn(&Json) -> Rc<dyn Any>>;

/// What a generated package (or an application) hands station: how to
/// construct the SDK, and the SDK's own embedded config.
#[derive(Clone)]
pub struct Factory {
    pub construct: ConstructFn,
    pub config: Json,
}

/// One registered api: the factory, plus the descriptor normalized at
/// provide time.
#[derive(Clone)]
pub struct FactoryEntry {
    pub api: String,
    pub construct: ConstructFn,
    pub config: Json,
    pub descriptor: Json,
    pub warnings: Vec<String>,
}

thread_local! {
    static TABLE: RefCell<BTreeMap<String, Rc<FactoryEntry>>> =
        const { RefCell::new(BTreeMap::new()) };
}

/// Register an api's construct/config pair.
///
/// Idempotent per api: registering the SAME pair twice is a no-op,
/// because an explicit `provide` reached twice - a library helper and an
/// application line - is an ordinary thing to end up with. A second
/// registration with a DIFFERENT factory is `station_factory_conflict`:
/// a process has one build of an SDK, and picking between two silently is
/// not a thing to do quietly.
///
/// "The same pair" is IDENTITY for the constructor (`Rc::ptr_eq` - a Rust
/// closure is not comparable any other way, and a generated package's
/// registrar hands out clones of one `Rc`) and VALUE for the config,
/// which is plain data.
pub fn provide(api: &str, factory: Factory) -> Result<Rc<FactoryEntry>, StationError> {
    let slug = api.to_string();

    let prior = TABLE.with(|table| table.borrow().get(&slug).cloned());
    if let Some(prior) = prior {
        if Rc::ptr_eq(&prior.construct, &factory.construct) && prior.config == factory.config {
            return Ok(prior);
        }
        return Err(StationError::new(
            "station_factory_conflict",
            format!(
                "two different factories registered for api \"{}\"; a process \
                 has one build of an SDK, and picking between two silently is \
                 not a thing to do quietly",
                slug
            ),
        ));
    }

    // AT PROVIDE TIME, which is the whole point of carrying `config`. NO
    // per-instance features: the shared value holds only api-stable
    // metadata (§7.4).
    let (descriptor, warnings) = normalize_descriptor(&factory.config, &Json::Null);
    let entry = Rc::new(FactoryEntry {
        api: slug.clone(),
        construct: factory.construct,
        config: factory.config,
        descriptor,
        warnings,
    });
    TABLE.with(|table| table.borrow_mut().insert(slug, entry.clone()));
    Ok(entry)
}

/// A registered api's entry, or None.
pub fn factory_for(api: &str) -> Option<Rc<FactoryEntry>> {
    TABLE.with(|table| table.borrow().get(api).cloned())
}

/// The registered api slugs, sorted.
pub fn provided() -> Vec<String> {
    TABLE.with(|table| table.borrow().keys().cloned().collect())
}

/// Clear the table. TEST SEAM ONLY: the table is process-global (per
/// thread) by design, so a suite that registers factories has to be able
/// to put the process back.
pub fn reset_factories() {
    TABLE.with(|table| table.borrow_mut().clear());
}
