//! AI collector — `ai-stack status`
//!
//! OWNER: work stream S1.
//!
//! `ai-stack` (`modules/agentic-local-ai.nix`) is a shell script whose very
//! first act is:
//!
//! ```text
//! if ! groups | grep -q docker; then
//!   error "User must be in 'docker' group. ..."
//!   exit 1
//! fi
//! ```
//!
//! and this host **deliberately does not grant the docker group** — it is
//! root-equivalent, and `modules/agentic-local-ai.nix` says so in a comment.
//! So on the primary machine `ai-stack status` never reaches its status logic.
//! It writes to stderr and exits 1, which `exec::run` surfaces as an error —
//! the one shape that cannot be mistaken for a healthy subsystem. That is the
//! correct outcome and this collector preserves it rather than smoothing it
//! into an empty-but-green pane.
//!
//! Output is ANSI-coloured (`\x1b[0;32m[OK]\x1b[0m Container: RUNNING`), so
//! everything is stripped before matching.

use crate::model::{Availability, Health, Panel};
use std::time::Duration;

/// `ai-stack status` runs `docker exec ollama ollama list` on the happy path,
/// which can be slow on a cold daemon. Still well under the 10s interval.
const TIMEOUT: Duration = Duration::from_secs(6);

pub struct AiCollector {
    _priv: (),
}

impl AiCollector {
    pub fn new() -> Self {
        AiCollector { _priv: () }
    }
}

impl Default for AiCollector {
    fn default() -> Self {
        Self::new()
    }
}

/// Remove CSI escape sequences. `ai-stack` colours every status line and the
/// codes would otherwise end up inside a rendered table cell.
fn strip_ansi(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c != '\u{1b}' {
            out.push(c);
            continue;
        }
        // ESC [ ... <final byte in @..~>
        if chars.peek() == Some(&'[') {
            chars.next();
            for c2 in chars.by_ref() {
                if ('@'..='~').contains(&c2) {
                    break;
                }
            }
        } else {
            // A lone ESC, or a non-CSI sequence: drop the ESC and move on.
            chars.next();
        }
    }
    out
}

#[derive(Debug, PartialEq, Eq)]
enum Container {
    Running,
    Stopped,
    Unknown,
}

/// `[OK] Container: RUNNING` / `[WARN] Container: STOPPED`.
fn container_state(clean: &str) -> Container {
    for line in clean.lines() {
        let l = line.trim();
        if !l.contains("Container:") {
            continue;
        }
        let up = l.to_ascii_uppercase();
        if up.contains("RUNNING") {
            return Container::Running;
        }
        if up.contains("STOPPED") {
            return Container::Stopped;
        }
    }
    Container::Unknown
}

/// Rows of the `ollama list` table that `ai-stack status` appends when the
/// container is up: `NAME  ID  SIZE  MODIFIED`, whitespace-aligned.
///
/// Columns are split on runs of 2+ spaces rather than any whitespace, because
/// the MODIFIED column contains single spaces ("2 weeks ago").
fn parse_models(clean: &str) -> Vec<Vec<String>> {
    let mut rows = Vec::new();
    let mut in_table = false;
    for line in clean.lines() {
        let l = line.trim_end();
        if l.trim().is_empty() {
            continue;
        }
        let upper = l.trim().to_ascii_uppercase();
        if upper.starts_with("NAME") && upper.contains("SIZE") {
            in_table = true;
            continue;
        }
        if !in_table {
            continue;
        }
        // Bracketed status lines are never table rows.
        if l.trim_start().starts_with('[') {
            continue;
        }
        let cols: Vec<String> = l
            .split("  ")
            .map(str::trim)
            .filter(|c| !c.is_empty())
            .map(str::to_string)
            .collect();
        if cols.len() >= 2 {
            rows.push(cols);
        }
    }
    rows
}

/// Did the script bail before doing any work? Both the stderr text that
/// reaches us through `exec::run`'s error and a stdout copy are matched, since
/// the redirection is the script's choice and could change.
fn is_group_refusal(text: &str) -> bool {
    let t = strip_ansi(text).to_ascii_lowercase();
    t.contains("docker' group") || t.contains("docker group")
}

impl super::Collector for AiCollector {
    fn id(&self) -> &'static str {
        "ai"
    }

    fn title(&self) -> &'static str {
        "AI"
    }

    fn interval(&self) -> Duration {
        Duration::from_secs(10)
    }

    fn probe(&self) -> Availability {
        match crate::exec::which("ai-stack") {
            Some(_) => Availability::Present,
            None => Availability::Missing("ai-stack not installed — enable services.ollamaAgentic"),
        }
    }

    fn collect(&mut self) -> anyhow::Result<Panel> {
        let raw = match crate::exec::run("ai-stack", &["status"], TIMEOUT) {
            Ok(out) => out,
            Err(e) => {
                let msg = e.to_string();
                if is_group_refusal(&msg) {
                    // Not a fault in the AI stack — a deliberate privilege
                    // boundary on this host. Say which, so nobody spends an
                    // afternoon debugging ollama.
                    anyhow::bail!("ai-stack refuses: caller is not in the docker group");
                }
                return Err(anyhow::anyhow!(strip_ansi(&msg)));
            }
        };

        let clean = strip_ansi(&raw);

        // Exit 0 with nothing on stdout is the silent-unprivileged shape this
        // repo keeps rediscovering. It is an error, never an empty green pane.
        if clean.trim().is_empty() {
            anyhow::bail!("ai-stack status exited 0 with no output");
        }
        if is_group_refusal(&clean) {
            anyhow::bail!("ai-stack refuses: caller is not in the docker group");
        }

        let state = container_state(&clean);
        let (value, health) = match state {
            Container::Running => ("running", Health::Good),
            // Ollama is opt-in and expensive; stopped is a normal resting
            // state, not a fault.
            Container::Stopped => ("stopped", Health::Unknown),
            Container::Unknown => ("--", Health::Unknown),
        };

        let mut panel = Panel::new(health, String::new()).row("ollama container", value, health);

        let models = parse_models(&clean);
        if state == Container::Running {
            // A running container that lists no models is worth flagging:
            // `ai-stack status` prints "Could not list models" in exactly that
            // case, and an agent pointed at an empty ollama fails obscurely.
            let mh = if models.is_empty() { Health::Warn } else { Health::Good };
            panel = panel.row("models", format!("{}", models.len()), mh);
            panel.health = Health::worst([health, mh]);
        } else {
            panel = panel.plain("models", "--");
        }

        if !models.is_empty() {
            let width = models.iter().map(Vec::len).max().unwrap_or(1).min(4);
            let headers: Vec<String> = ["model", "id", "size", "modified"]
                .iter()
                .take(width)
                .map(|s| s.to_string())
                .collect();
            let rows: Vec<Vec<String>> = models
                .into_iter()
                .map(|mut r| {
                    r.truncate(width);
                    while r.len() < width {
                        r.push("--".to_string());
                    }
                    r
                })
                .collect();
            panel = panel.table(headers, rows);
        }

        let model_count = panel
            .table
            .as_ref()
            .map(|t| t.rows.len())
            .unwrap_or(0);
        panel.summary = match state {
            Container::Running => format!("ollama running · {model_count} models"),
            Container::Stopped => "ollama stopped".to_string(),
            Container::Unknown => "state unknown".to_string(),
        };

        Ok(panel)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Exactly what `ai-stack status` writes on the happy path: the `success`
    /// helper's green `[OK]`, a blank line, then `ollama list`.
    const RUNNING: &str = "\u{1b}[0;36m=== Ollama Status ===\u{1b}[0m\n\
\u{1b}[0;32m[OK]\u{1b}[0m Container: RUNNING\n\
\n\
NAME                    ID              SIZE      MODIFIED\n\
llama3.2:latest         a80c4f17acd5    2.0 GB    2 weeks ago\n\
qwen2.5-coder:7b        2b0496514337    4.7 GB    3 months ago\n";

    const STOPPED: &str = "\u{1b}[0;36m=== Ollama Status ===\u{1b}[0m\n\
\u{1b}[1;33m[WARN]\u{1b}[0m Container: STOPPED\n";

    /// Verbatim from this host, where the docker group is intentionally not
    /// granted.
    const REFUSED: &str =
        "\u{1b}[0;31m[ERROR]\u{1b}[0m User must be in 'docker' group. Run: sudo usermod -aG docker asher";

    #[test]
    fn ansi_is_stripped_without_eating_text() {
        assert_eq!(strip_ansi("\u{1b}[0;32m[OK]\u{1b}[0m up"), "[OK] up");
        assert_eq!(strip_ansi("plain"), "plain");
        assert_eq!(strip_ansi(""), "");
        // A lone ESC must not swallow the remainder of the line.
        assert_eq!(strip_ansi("a\u{1b}b"), "a");
    }

    #[test]
    fn container_state_from_real_output() {
        assert_eq!(container_state(&strip_ansi(RUNNING)), Container::Running);
        assert_eq!(container_state(&strip_ansi(STOPPED)), Container::Stopped);
        // Nothing recognisable is Unknown, never Stopped-by-assumption.
        assert_eq!(container_state(""), Container::Unknown);
        assert_eq!(container_state("some other tool's output"), Container::Unknown);
    }

    #[test]
    fn models_split_on_column_gaps_not_single_spaces() {
        let rows = parse_models(&strip_ansi(RUNNING));
        assert_eq!(rows.len(), 2);
        assert_eq!(
            rows[0],
            vec!["llama3.2:latest", "a80c4f17acd5", "2.0 GB", "2 weeks ago"]
        );
        // "3 months ago" must survive as one cell.
        assert_eq!(rows[1][3], "3 months ago");
    }

    #[test]
    fn no_model_table_yields_no_rows() {
        assert!(parse_models(&strip_ansi(STOPPED)).is_empty());
        assert!(parse_models("").is_empty());
        // The status line must never be mistaken for a table row.
        assert!(parse_models("[WARN] Could not list models").is_empty());
    }

    #[test]
    fn the_docker_group_refusal_is_recognised_on_either_stream() {
        assert!(is_group_refusal(REFUSED));
        assert!(is_group_refusal("ai-stack: [ERROR] User must be in 'docker' group."));
        assert!(!is_group_refusal("[OK] Container: RUNNING"));
        assert!(!is_group_refusal(""));
    }
}
