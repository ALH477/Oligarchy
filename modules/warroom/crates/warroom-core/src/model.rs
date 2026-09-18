//! The shared contract: what a collector produces and how stale it is.

use serde::Serialize;
use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Health {
    Good,
    Warn,
    Bad,
    #[default]
    Unknown,
}

impl Health {
    /// Text that must accompany every health dot. Color alone is not a signal.
    pub fn label(self) -> &'static str {
        match self {
            Health::Good => "OK",
            Health::Warn => "WARN",
            Health::Bad => "FAIL",
            Health::Unknown => "--",
        }
    }

    /// Worst of a set, for rolling a pane up into a SITREP card.
    pub fn worst<I: IntoIterator<Item = Health>>(it: I) -> Health {
        it.into_iter().fold(Health::Good, |acc, h| match (acc, h) {
            (Health::Bad, _) | (_, Health::Bad) => Health::Bad,
            (Health::Warn, _) | (_, Health::Warn) => Health::Warn,
            (Health::Unknown, _) | (_, Health::Unknown) => Health::Unknown,
            _ => Health::Good,
        })
    }
}

/// How much a pane's data can be trusted right now.
///
/// The widget layer MUST render these differently. A dashboard showing a stale
/// green dot is worse than no dashboard.
#[derive(Debug, Clone)]
pub enum Freshness {
    /// Updated within the collector's interval.
    Fresh,
    /// Last successful collection was this long ago.
    Stale(Duration),
    /// The last collection attempt returned an error.
    Failed(String),
    /// The backing binary or file is not present at all.
    Unavailable(&'static str),
}

impl Freshness {
    pub fn is_usable(&self) -> bool {
        matches!(self, Freshness::Fresh | Freshness::Stale(_))
    }
}

/// Whether a collector can run on this host at all.
#[derive(Debug, Clone)]
pub enum Availability {
    Present,
    /// Human-readable reason, e.g. "dsp-ctl not installed — enable custom.dsp".
    Missing(&'static str),
}

#[derive(Debug, Clone, Serialize)]
pub struct Row {
    pub label: String,
    pub value: String,
    pub health: Health,
}

impl Row {
    pub fn new(label: impl Into<String>, value: impl Into<String>, health: Health) -> Self {
        Row { label: label.into(), value: value.into(), health }
    }

    /// A row that carries no judgement — plain informational value.
    pub fn plain(label: impl Into<String>, value: impl Into<String>) -> Self {
        Row::new(label, value, Health::Unknown)
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct Table {
    pub headers: Vec<String>,
    pub rows: Vec<Vec<String>>,
}

/// One subsystem's state. `ui::widgets::panel()` renders any of these with no
/// new UI code, which is what makes adding a subsystem a one-file change.
#[derive(Debug, Clone, Serialize)]
pub struct Panel {
    pub health: Health,
    /// Exactly one line, for the SITREP rollup card.
    pub summary: String,
    pub rows: Vec<Row>,
    /// Optional tabular payload (peer lists, port lists, ...).
    pub table: Option<Table>,
}

impl Panel {
    pub fn new(health: Health, summary: impl Into<String>) -> Self {
        Panel { health, summary: summary.into(), rows: Vec::new(), table: None }
    }

    pub fn row(mut self, label: impl Into<String>, value: impl Into<String>, health: Health) -> Self {
        self.rows.push(Row::new(label, value, health));
        self
    }

    pub fn plain(mut self, label: impl Into<String>, value: impl Into<String>) -> Self {
        self.rows.push(Row::plain(label, value));
        self
    }

    pub fn table(mut self, headers: Vec<String>, rows: Vec<Vec<String>>) -> Self {
        self.table = Some(Table { headers, rows });
        self
    }
}

/// A pane as the UI holds it: the last good payload plus how stale it is.
#[derive(Debug, Clone)]
pub struct PanelState {
    pub id: &'static str,
    pub title: &'static str,
    pub panel: Option<Panel>,
    pub freshness: Freshness,
    pub last_ok: Option<Instant>,
}

impl PanelState {
    pub fn new(id: &'static str, title: &'static str) -> Self {
        PanelState { id, title, panel: None, freshness: Freshness::Stale(Duration::ZERO), last_ok: None }
    }

    pub fn health(&self) -> Health {
        match (&self.freshness, &self.panel) {
            (Freshness::Unavailable(_), _) => Health::Unknown,
            (Freshness::Failed(_), _) => Health::Bad,
            (_, Some(p)) => p.health,
            (_, None) => Health::Unknown,
        }
    }

    pub fn summary(&self) -> String {
        match &self.freshness {
            Freshness::Unavailable(why) => (*why).to_string(),
            Freshness::Failed(err) => err.clone(),
            _ => self.panel.as_ref().map(|p| p.summary.clone()).unwrap_or_else(|| "NO CONTACT".into()),
        }
    }
}

/// Messages collector threads send to the UI thread.
#[derive(Debug)]
pub enum CollectorMsg {
    Update { id: &'static str, panel: Panel, at: Instant },
    Failed { id: &'static str, err: String, at: Instant },
    Unavailable { id: &'static str, why: &'static str },
}

/// The `warroom status --json` payload. Stable enough for a waybar module or a
/// future /run/oligarchy-warroom/status.json cache to consume.
#[derive(Debug, Clone, Serialize)]
pub struct Snapshot {
    pub ts: String,
    pub host: String,
    pub panels: Vec<SnapshotPanel>,
}

#[derive(Debug, Clone, Serialize)]
pub struct SnapshotPanel {
    pub id: String,
    pub title: String,
    pub state: &'static str,
    pub health: Health,
    pub summary: String,
    pub rows: Vec<Row>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub table: Option<Table>,
}
