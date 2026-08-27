//! Upstream binary caches.
//!
//! Stage 1's only source of bytes. Upstreams are tried in configured order and
//! the first one that answers wins; a 404 from one is not fatal, a transport
//! error from one is not fatal, and running out of upstreams is a 404 to Nix
//! (which then moves to the next substituter in *its* list — we are never the
//! last line of defence).

use anyhow::{Context, Result};
use bytes::Bytes;
use futures_util::Stream;
use std::time::Duration;

pub struct Upstream {
    client: reqwest::Client,
    bases: Vec<String>,
}

/// A NAR body that has started arriving, plus where it came from.
pub struct Body {
    pub source: String,
    pub stream: std::pin::Pin<Box<dyn Stream<Item = reqwest::Result<Bytes>> + Send>>,
}

impl Upstream {
    pub fn new(bases: Vec<String>, timeout: Duration) -> Result<Self> {
        let client = reqwest::Client::builder()
            // Applies to the whole request for narinfo (small) but we override
            // per-request for NAR bodies, which are legitimately long.
            .connect_timeout(timeout)
            .user_agent(concat!("oligarchy-p2pd/", env!("CARGO_PKG_VERSION")))
            .build()
            .context("building the upstream HTTP client")?;
        Ok(Self { client, bases })
    }

    /// First configured upstream, for a body fetch whose narinfo came from
    /// local disk and therefore names no origin.
    pub fn first_base(&self) -> Option<String> {
        self.bases.first().cloned()
    }

    /// Fetch a small text file (a narinfo, or nix-cache-info) from the first
    /// upstream that has it. `Ok(None)` means every upstream returned 404.
    pub async fn get_text(&self, rel: &str, timeout: Duration) -> Result<Option<(String, String)>> {
        let mut last_err = None;
        for base in &self.bases {
            let url = format!("{base}/{rel}");
            match self.client.get(&url).timeout(timeout).send().await {
                Ok(r) if r.status().is_success() => match r.text().await {
                    Ok(t) => return Ok(Some((base.clone(), t))),
                    Err(e) => last_err = Some(anyhow::Error::new(e).context(url)),
                },
                Ok(r) if r.status() == reqwest::StatusCode::NOT_FOUND => continue,
                Ok(r) => {
                    last_err = Some(anyhow::anyhow!("{url}: HTTP {}", r.status()));
                }
                Err(e) => last_err = Some(anyhow::Error::new(e).context(url)),
            }
        }
        match last_err {
            // Every upstream said 404. That is an answer, not a failure.
            None => Ok(None),
            Some(e) => Err(e),
        }
    }

    /// Begin streaming a NAR body. `rel` is the narinfo's `URL` field, which
    /// may be relative or absolute (Nix resolves it with `parseURLRelative`, so
    /// a cache is entitled to emit either and we must accept both).
    pub async fn get_stream(&self, base: &str, rel: &str) -> Result<Option<Body>> {
        let url = if rel.starts_with("http://") || rel.starts_with("https://") {
            rel.to_string()
        } else {
            format!("{base}/{rel}")
        };
        let r = self
            .client
            .get(&url)
            // Deliberately no overall timeout: a multi-gigabyte NAR over a slow
            // link is not an error. The byte cap in `verify` is what bounds
            // this, not the clock.
            .send()
            .await
            .with_context(|| format!("GET {url}"))?;
        if r.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(None);
        }
        if !r.status().is_success() {
            anyhow::bail!("{url}: HTTP {}", r.status());
        }
        Ok(Some(Body {
            source: url,
            stream: Box::pin(r.bytes_stream()),
        }))
    }
}
