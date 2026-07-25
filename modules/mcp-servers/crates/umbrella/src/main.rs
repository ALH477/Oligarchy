//! oligarchy-mcp — the umbrella binary.
//!
//! A thin exec-spawn multiplexer. `.mcp.json` invokes it with one argument
//! — the aspect to spawn. The umbrella replaces itself (via `execvp`) with
//! the corresponding `oligarchy-<aspect>-mcp` binary. It does NOT route and
//! holds NO capabilities itself: by design, the umbrella cannot grant new
//! powers — only the spawned aspect crate enforces its own allowlist.
//!
//! Single front door in `PATH` (`.mcp.json` entries all reference
//! `oligarchy-mcp <aspect>`), true process separation (one process per
//! aspect, exactly one allowlist in scope per invocation), minimum code
//! surface for the routing layer.
//!
//! See `docs/mcp-servers-roadmap.md` §5.

use std::os::unix::process::CommandExt;

const ASPECT: &str = "umbrella";

/// Append one TSV audit line to the umbrella's own audit log. Mirrors
/// `oligarchy_mcp_core::audit::log` semantics: never panics, swallows IO
/// errors (auditing must never break a read-only query).
fn audit_log(tool: &str, detail: &str) {
    let base = std::env::var("OLIGARCHY_MCP_STATE_DIR").map(std::path::PathBuf::from).unwrap_or_else(|_| {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
        std::path::PathBuf::from(home).join(".local/state/oligarchy-mcp")
    });
    let path = base.join(ASPECT).join("audit.log");
    if std::fs::create_dir_all(path.parent().unwrap_or(&base)).is_err() {
        return;
    }
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    let uid = std::process::Command::new("id").arg("-u").output().ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|| "?".into());
    let line = format!("{now}\t{ASPECT}\t{tool}\t{detail}\texec\t{uid}\n");
    let _ = std::fs::OpenOptions::new().create(true).append(true).open(&path)
        .and_then(|mut f| std::io::Write::write_all(&mut f, line.as_bytes()));
}

/// Run `oligarchy-<aspect>-mcp` with the remaining args. Replaces this
/// process — if exec succeeds, main never returns.
fn run() -> ! {
    let args: Vec<String> = std::env::args().collect();
    // No args → default aspect = "system". This keeps the legacy Blipply
    // `command = "oligarchy-mcp"` spawn (with no args) working unchanged.
    // The new .mcp.json always passes an explicit aspect.
    let aspect = args.get(1).map(|s| s.as_str()).unwrap_or("system");
    if args.len() > 2 || !is_known_aspect(aspect) {
        eprintln!(
            "usage: {0} [aspect]\n\
             \n  aspects: system, net, dcf, dsp, ai, secrets, vm, ports-sec\n\
             \n  The umbrella replaces itself (execvp) with \
             `oligarchy-<aspect>-mcp`. No aspect defaults to `system`.\n\
             \n  In `.mcp.json`, register one entry per aspect, e.g.:\n  \
             {{\"mcpServers\": {{\"oligarchy-system\": {{\"command\": \
             \"{0}\", \"args\": [\"system\"]}}}}}}",
            args.get(0).map(|s| s.as_str()).unwrap_or("oligarchy-mcp")
        );
        std::process::exit(2);
    }
    let bin = format!("oligarchy-{aspect}-mcp");
    // The umbrella logs the routing decision; the spawned aspect opens its
    // own audit log on exec.
    audit_log("exec", aspect);

    let err = std::process::Command::new(&bin).exec();
    // exec only returns on failure.
    eprintln!(
        "oligarchy-mcp: exec failed for {bin}: {err}\n\
         \n  ensure the aspect server is installed as `/run/current-system/bin/{bin}`"
    );
    std::process::exit(127);
}

fn is_known_aspect(a: &str) -> bool {
    matches!(
        a,
        "system" | "net" | "dcf" | "dsp" | "ai" | "secrets" | "vm" | "ports-sec"
    )
}

fn main() {
    run();
}