//! The control socket: how an unprivileged user installs a *signed* plugin
//! without anyone being added to `nix.settings.trusted-users`.
//!
//! THE PROBLEM. The registry lives at `${stateDir}` and is `0750
//! oligarchy:oligarchy`, so an unprivileged user cannot write it. The obvious
//! ways to fix that are both wrong:
//!
//!   - make the registry group-writable — then any member can register a path
//!     without it passing `authorize()` or a signature check at all;
//!   - add the user to `nix.settings.trusted-users` — per the Nix manual that
//!     is equivalent to giving that user root, which defeats the entire model.
//!
//! So instead the user *asks* a privileged process that already knows the
//! policy, and that process does the verification. The user may ask for
//! anything; only signed, policy-authorised things get registered.
//!
//! THE ENFORCEMENT IS STRUCTURAL, NOT A CHECK. Note what `Request::Install`
//! does not have: an `allow_unsigned` field. It is not that the server ignores
//! the flag, or validates it away — there is no way to encode the request. The
//! development escape hatch exists only on the direct-write path, which
//! already requires write access to the registry. A check can be forgotten in
//! a refactor; an absent field cannot.
//!
//! WHO MAY ASK. The socket is `0660` and group-owned by `--control-group`
//! (the module's `custom.plugins.installGroup`). Membership of that group
//! conveys exactly one power: "may ask the daemon to install a signed plugin".
//! It is deliberately not the group the runtime itself runs as, so an installer
//! does not also gain read access to every plugin's state directory.

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};

use crate::registry::Entry;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::time::Duration;

pub const SOCKET_NAME: &str = "control.sock";

/// How long a client gets to send its line and read the reply. An install can
/// legitimately take a while (it may substitute from a cache), so the read
/// timeout on the *client* side is generous; the server's is about not letting
/// a stalled peer hold a worker thread forever.
const SERVER_IO_TIMEOUT: Duration = Duration::from_secs(30);
const CLIENT_IO_TIMEOUT: Duration = Duration::from_secs(600);

/// One request, one line of JSON.
///
/// Deliberately not the same wire format as `tiers::microvm`'s length-prefixed
/// postcard frames. That one is a guest ABI on a vsock, where framing cost is
/// paid per audio block; this one is a control plane a shell script and a
/// future FX Bazaar UI both have to be able to speak. The divergence is the
/// point, not an oversight.
///
/// Every variant here is something an unprivileged member of the install group
/// is allowed to ask for. Verbs that are *not* here are not reachable over the
/// socket at all: `purge` (destroys another user's presets), `reconcile` and
/// `daemon` (the supervisor's own business), and `shim`.
#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "verb", rename_all = "kebab-case", deny_unknown_fields)]
pub enum Request {
    Install { source: String },
    Remove { id: String },
    Enable { id: String, no_start: bool },
    Disable { id: String },
    List,
}

/// A successful reply.
///
/// `list` returns the registry rather than a rendered table on purpose. The
/// socket is meant to be the FX Bazaar UI's API as much as the CLI's, and a UI
/// cannot consume 28-column ASCII — so the daemon returns decisions and data,
/// and the client owns formatting. Messages stay messages: "installed X" plus
/// the sandbox explanation is prose, and having it come back identical to a
/// local install is the point.
#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum Reply {
    Text { text: String },
    Entries { entries: Vec<Entry> },
}

impl Reply {
    pub fn text(s: impl Into<String>) -> Self {
        Reply::Text { text: s.into() }
    }
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "kebab-case")]
pub enum Response {
    Ok { reply: Reply },
    Err { message: String },
}

pub fn socket_path(runtime_dir: &Path) -> PathBuf {
    runtime_dir.join(SOCKET_NAME)
}

// ── client ────────────────────────────────────────────────────────────────

/// Send one request and return the server's reply, or its error as ours.
pub fn request(runtime_dir: &Path, req: &Request) -> Result<Reply> {
    let path = socket_path(runtime_dir);
    let mut sock = UnixStream::connect(&path).with_context(|| {
        format!(
            "cannot reach the plugin supervisor at {}. Either \
             oligarchy-plugind.service is not running, or this account is not \
             in the install group (see custom.plugins.installers).",
            path.display()
        )
    })?;
    sock.set_read_timeout(Some(CLIENT_IO_TIMEOUT))?;
    sock.set_write_timeout(Some(CLIENT_IO_TIMEOUT))?;

    let mut line = serde_json::to_string(req)?;
    line.push('\n');
    sock.write_all(line.as_bytes())?;
    sock.flush()?;
    // Half-close so the server sees EOF even if it reads to the end.
    sock.shutdown(std::net::Shutdown::Write).ok();

    let mut reply = String::new();
    BufReader::new(&sock)
        .read_line(&mut reply)
        .context("reading reply from the plugin supervisor")?;
    match serde_json::from_str::<Response>(reply.trim()) {
        Ok(Response::Ok { reply }) => Ok(reply),
        Ok(Response::Err { message }) => bail!("{message}"),
        Err(e) => bail!("unparseable reply from the plugin supervisor: {e}"),
    }
}

// ── server ────────────────────────────────────────────────────────────────

/// Bind the socket, and hand it the right group if one was named.
///
/// Bound before the unit signals readiness, so `systemctl start` returning
/// means the socket is there.
pub fn bind(runtime_dir: &Path, control_group: Option<&str>) -> Result<UnixListener> {
    std::fs::create_dir_all(runtime_dir)
        .with_context(|| format!("creating {}", runtime_dir.display()))?;
    let path = socket_path(runtime_dir);
    // A stale socket from a killed daemon would make bind fail with EADDRINUSE.
    let _ = std::fs::remove_file(&path);

    let listener =
        UnixListener::bind(&path).with_context(|| format!("binding {}", path.display()))?;

    match control_group {
        Some(name) => {
            let group = nix::unistd::Group::from_name(name)
                .with_context(|| format!("looking up group {name}"))?
                .with_context(|| format!("no such group: {name}"))?;
            nix::unistd::chown(&path, None, Some(group.gid))
                .with_context(|| format!("chgrp {name} {}", path.display()))?;
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o660))?;
            tracing::info!(
                socket = %path.display(),
                group = name,
                "control socket open to group members"
            );
        }
        None => {
            // No group named: root only. This is the correct default — the
            // socket is a privileged service, and handing it out is opt-in.
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
            tracing::info!(socket = %path.display(), "control socket open to root only");
        }
    }
    Ok(listener)
}

/// The peer's uid, for the audit line. Never used to *authorise* anything —
/// the socket's mode does that — only to record who asked.
fn peer_uid(sock: &UnixStream) -> Option<u32> {
    nix::sys::socket::getsockopt(sock, nix::sys::socket::sockopt::PeerCredentials)
        .ok()
        .map(|c| c.uid())
}

/// Accept loop. Never returns; a failure to serve one client is logged and the
/// listener keeps going, because a client that hangs up mid-request must not
/// take the supervisor with it.
pub fn serve<F>(listener: UnixListener, handle: F) -> !
where
    F: Fn(Request) -> Result<Reply> + Send + Sync + 'static,
{
    let handle = std::sync::Arc::new(handle);
    loop {
        let (sock, _) = match listener.accept() {
            Ok(v) => v,
            Err(e) => {
                tracing::error!(error = %e, "accept failed");
                std::thread::sleep(Duration::from_millis(200));
                continue;
            }
        };
        let handle = handle.clone();
        // A thread per connection rather than serving inline: an install can
        // block for as long as a substitution takes, and one slow client must
        // not queue every other one behind it.
        std::thread::Builder::new()
            .name("oligarchy-control".into())
            .spawn(move || {
                if let Err(e) = serve_one(sock, handle.as_ref()) {
                    tracing::warn!(error = %e, "control connection failed");
                }
            })
            .ok();
    }
}

fn serve_one<F>(sock: UnixStream, handle: &F) -> Result<()>
where
    F: Fn(Request) -> Result<Reply>,
{
    sock.set_read_timeout(Some(SERVER_IO_TIMEOUT))?;
    sock.set_write_timeout(Some(SERVER_IO_TIMEOUT))?;
    let uid = peer_uid(&sock);

    // Bounded. `read_line` on an attacker-controlled stream is unbounded
    // allocation in a root process: a peer that never sends a newline would
    // grow this String until the supervisor is OOM-killed. 64 KiB is far more
    // than any flake ref needs.
    const MAX_REQUEST: u64 = 64 * 1024;
    let mut line = String::new();
    BufReader::new((&sock).take(MAX_REQUEST)).read_line(&mut line)?;

    let reply = match serde_json::from_str::<Request>(line.trim()) {
        Ok(req) => {
            // Audit before acting: what was asked, by whom. If the daemon dies
            // mid-install this line is what says why it was trying.
            tracing::info!(uid = ?uid, request = ?req, "control request");
            match handle(req) {
                Ok(reply) => Response::Ok { reply },
                Err(e) => {
                    tracing::warn!(uid = ?uid, error = %e, "control request refused");
                    // `{e:#}` so the anyhow context chain reaches the user;
                    // "host policy refused plugin X: tier native is not
                    // enabled" is useful, "refused" alone is not.
                    Response::Err {
                        message: format!("{e:#}"),
                    }
                }
            }
        }
        Err(e) => Response::Err {
            message: format!("malformed request: {e}"),
        },
    };

    let mut out = serde_json::to_string(&reply)?;
    out.push('\n');
    (&sock).write_all(out.as_bytes())?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn install_cannot_ask_for_unsigned() {
        // THE structural guarantee of stage 2. `deny_unknown_fields` turns an
        // attempt to smuggle the flag into a parse error rather than a
        // silently ignored field, so a client cannot even fail open.
        let smuggled = r#"{"verb":"install","source":"/nix/store/x","allow_unsigned":true}"#;
        assert!(serde_json::from_str::<Request>(smuggled).is_err());
        // ...while the honest form parses.
        let honest = r#"{"verb":"install","source":"/nix/store/x"}"#;
        assert!(matches!(
            serde_json::from_str::<Request>(honest),
            Ok(Request::Install { .. })
        ));
    }

    #[test]
    fn destructive_and_supervisor_verbs_are_not_on_the_wire() {
        for line in [
            r#"{"verb":"purge","id":"x"}"#,
            r#"{"verb":"reconcile"}"#,
            r#"{"verb":"daemon"}"#,
            r#"{"verb":"shim","id":"x"}"#,
        ] {
            assert!(
                serde_json::from_str::<Request>(line).is_err(),
                "{line} should not be expressible"
            );
        }
    }

    #[test]
    fn responses_round_trip() {
        for r in [
            Response::Ok {
                reply: Reply::text("installed x\n"),
            },
            Response::Ok {
                reply: Reply::Entries { entries: vec![] },
            },
            Response::Err {
                message: "no".into(),
            },
        ] {
            let wire = serde_json::to_string(&r).unwrap();
            assert!(
                serde_json::from_str::<Response>(&wire).is_ok(),
                "did not round-trip: {wire}"
            );
        }
    }
}
