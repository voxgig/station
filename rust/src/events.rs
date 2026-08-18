//! The solo event surface (design §6): a bounded ring buffer plus a live
//! tap with serialized callbacks. Events never fail an operation; overflow
//! drops oldest and the drop count is visible in status().
//!
//! A port of typescript/src/events.ts (and the StationEvent shape of
//! typescript/src/types.ts), which is canonical. Single-threaded by
//! design: the whole generated-SDK world is Rc/RefCell (neither Send nor
//! Sync), so the buffer is interior-mutable, not synchronized.

use std::cell::RefCell;
use std::collections::VecDeque;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::rc::Rc;

use voxgig_sekreto::Json;

use crate::jsonx::{jobj, jtext};

/// StationEvent v1 (design §6). Unknown fields are ignored by consumers;
/// the shape evolves additively.
#[derive(Clone, Debug, Default)]
pub struct StationEvent {
    pub t: i64,
    /// construct | op | http | error | feature | station
    pub kind: String,
    pub plugin: Option<String>,
    pub corr: Option<String>,
    pub op: Option<OpEvent>,
    pub http: Option<HttpEvent>,
    pub err: Option<ErrEvent>,
    pub meta: Option<Json>,
}

#[derive(Clone, Debug, Default)]
pub struct OpEvent {
    pub entity: String,
    pub op: String,
    pub outcome: String,
    pub duration_ms: i64,
}

#[derive(Clone, Debug, Default)]
pub struct HttpEvent {
    pub method: String,
    pub host: String,
    pub path: String,
    pub status: i64,
    pub duration_ms: i64,
    pub bytes: i64,
}

#[derive(Clone, Debug, Default)]
pub struct ErrEvent {
    pub code: Option<String>,
    pub message: String,
}

impl StationEvent {
    /// The event as a Json value (the wire/corpus shape).
    pub fn to_json(&self) -> Json {
        let mut out = vec![("t", Json::Num(self.t as f64)), ("kind", jtext(self.kind.clone()))];
        if let Some(plugin) = &self.plugin {
            out.push(("plugin", jtext(plugin.clone())));
        }
        if let Some(corr) = &self.corr {
            out.push(("corr", jtext(corr.clone())));
        }
        if let Some(op) = &self.op {
            out.push((
                "op",
                jobj(vec![
                    ("entity", jtext(op.entity.clone())),
                    ("op", jtext(op.op.clone())),
                    ("outcome", jtext(op.outcome.clone())),
                    ("durationMs", Json::Num(op.duration_ms as f64)),
                ]),
            ));
        }
        if let Some(http) = &self.http {
            out.push((
                "http",
                jobj(vec![
                    ("method", jtext(http.method.clone())),
                    ("host", jtext(http.host.clone())),
                    ("path", jtext(http.path.clone())),
                    ("status", Json::Num(http.status as f64)),
                    ("durationMs", Json::Num(http.duration_ms as f64)),
                    ("bytes", Json::Num(http.bytes as f64)),
                ]),
            ));
        }
        if let Some(err) = &self.err {
            let mut emap = vec![("message", jtext(err.message.clone()))];
            if let Some(code) = &err.code {
                emap.push(("code", jtext(code.clone())));
            }
            out.push(("err", jobj(emap)));
        }
        if let Some(meta) = &self.meta {
            out.push(("meta", meta.clone()));
        }
        jobj(out)
    }
}

pub type TapFn = Rc<dyn Fn(&StationEvent)>;

pub struct EventBuffer {
    ring: RefCell<VecDeque<StationEvent>>,
    max: usize,
    drops: RefCell<i64>,
    taps: RefCell<Vec<(usize, TapFn)>>,
    tapseq: RefCell<usize>,
}

impl EventBuffer {
    pub fn new(max: Option<usize>) -> EventBuffer {
        EventBuffer {
            ring: RefCell::new(VecDeque::new()),
            max: max.unwrap_or(1000),
            drops: RefCell::new(0),
            taps: RefCell::new(Vec::new()),
            tapseq: RefCell::new(0),
        }
    }

    pub fn emit(&self, ev: StationEvent) {
        {
            let mut ring = self.ring.borrow_mut();
            ring.push_back(ev.clone());
            if ring.len() > self.max {
                ring.pop_front();
                *self.drops.borrow_mut() += 1;
            }
        }
        // Serialized, and a panicking tap must not fail the operation that
        // emitted the event.
        let taps: Vec<TapFn> = self.taps.borrow().iter().map(|(_, f)| f.clone()).collect();
        for tap in taps {
            let _ = catch_unwind(AssertUnwindSafe(|| tap(&ev)));
        }
    }

    pub fn events(&self) -> Vec<StationEvent> {
        self.ring.borrow().iter().cloned().collect()
    }

    /// Subscribe. Returns the tap id for untap().
    pub fn tap(&self, tap: TapFn) -> usize {
        let mut seq = self.tapseq.borrow_mut();
        *seq += 1;
        let id = *seq;
        self.taps.borrow_mut().push((id, tap));
        id
    }

    pub fn untap(&self, id: usize) {
        self.taps.borrow_mut().retain(|(tid, _)| *tid != id);
    }

    pub fn status(&self) -> (usize, i64) {
        (self.ring.borrow().len(), *self.drops.borrow())
    }
}
