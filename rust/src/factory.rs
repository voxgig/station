
use std::any::Any;
use std::cell::RefCell;
use std::collections::BTreeMap;
use std::rc::Rc;

use voxgig_sekreto::voxgig_plugin::value::Value as Json;

use crate::descriptor::normalize_descriptor;
use crate::error::StationError;

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

pub fn provide(api: &str, factory: Factory) -> Result<Rc<FactoryEntry>, StationError> {
    let slug = api.to_string();

    let prior = TABLE.with(|table| table.borrow().get(&slug).cloned());
    if let Some(prior) = prior {
        if Rc::ptr_eq(&prior.construct, &factory.construct) && prior.config.same(&factory.config) {
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

pub fn reset_factories() {
    TABLE.with(|table| table.borrow_mut().clear());
}
