//! `tls_cert_check` — for certbot-managed certs under `/var/lib/acme/`,
//! parses each cert with `x509-parser`, reports `not_after` / issuer / SAN.
//!
//! When the `allow-loopback-socket` feature is enabled (gated by it via the
//! optional `x509-parser` dep), the cert actually parses. With the feature
//! off, the directory is still enumerated and the rows are reported as
//! "(Phase 3: parse PEM via x509-parser)" to keep the audit visible.

pub fn report() -> anyhow::Result<String> {
    let acme = std::path::Path::new("/var/lib/acme");
    if !acme.is_dir() {
        return Ok(format!("[absent] /var/lib/acme not present on this host"));
    }
    let mut out = String::from("── TLS cert check (/var/lib/acme) ──────────────────\n");

    #[cfg(feature = "allow-loopback-socket")]
    {
        let entries = cert_entries(acme);
        for entry in entries {
            out.push_str(&entry);
        }
    }

    #[cfg(not(feature = "allow-loopback-socket"))]
    {
        if let Ok(entries) = std::fs::read_dir(acme) {
            let mut names: Vec<_> = entries
                .flatten()
                .filter_map(|e| {
                    e.path().file_name().and_then(|n| n.to_str()).map(String::from)
                })
                .collect();
            names.sort();
            for name in names {
                out.push_str(&format!("  {} (parse requires allow-loopback-socket feature)\n", name));
            }
        }
    }

    Ok(out)
}

// `x509-parser` 0.16 pulls `time` 0.3; we render the not_after ASN1Time using
// the Display impl from x509_parser::time::ASN1Time rather than computing a
// Duration ourselves (saves us a `time::Duration ⇒ seconds_f64` shim).
#[cfg(feature = "allow-loopback-socket")]
fn cert_entries(acme: &std::path::Path) -> Vec<String> {
    use x509_parser::parse_x509_certificate;
    use x509_parser::pem::parse_x509_pem;

    let mut out = Vec::new();
    let Ok(entries) = std::fs::read_dir(acme) else {
        return out;
    };
    for e in entries.flatten() {
        let path = e.path();
        let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        // Look for fullchain.pem under each cert dir
        let chain = path.join("fullchain.pem");
        if !chain.is_file() {
            // Not a certbot dir; just list the name.
            out.push(format!("  {} (no fullchain.pem)\n", name));
            continue;
        }
        let Ok(text) = std::fs::read(&chain) else {
            out.push(format!("  {} (unreadable fullchain.pem)\n", name));
            continue;
        };
        match parse_x509_pem(&text) {
            Ok((_rem, pem)) => match parse_x509_certificate(&pem.contents) {
                Ok((_rem2, cert)) => {
                    let subject = cert.subject().to_string();
                    let issuer = cert.issuer().to_string();
                    let not_after = cert.validity().not_after;
                    out.push(format!(
                        "  {} subject={} issuer={} not_after={}\n",
                        name, subject, issuer, not_after
                    ));
                }
                Err(err) => out.push(format!("  {} (parse err: {err})\n", name)),
            },
            Err(err) => {
                out.push(format!("  {} (pem parse err: {err})\n", name));
            }
        }
    }
    out
}