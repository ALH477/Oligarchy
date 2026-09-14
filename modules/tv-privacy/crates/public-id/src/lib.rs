//! Deterministic public-ID derivation for the Oligarchy theater face.
//!
//! RFC 5869: Extract once from `host_secret`, then Expand from that PRK.
//! Never re-extract from session secret S.

use hkdf::Hkdf;
use sha2::Sha256;

const SALT: &[u8] = b"oligarchy.tv-privacy.v1";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PublicIds {
    pub edid_serial_u32: u32,
    pub cec_osd: [u8; 8],
    pub ts_sid: u16,
    pub ts_tsid: u16,
    pub ts_onid: u16,
    pub pid_perm_key: [u8; 32],
    pub lan_suffix: [u8; 3],
    pub session_secret: [u8; 32],
}

fn session_info(policy: &str, date_bucket: &str, connector: &str, session_n: u64) -> Vec<u8> {
    let mut info = Vec::new();
    info.extend_from_slice(policy.as_bytes());
    info.push(0);
    info.extend_from_slice(date_bucket.as_bytes());
    info.push(0);
    info.extend_from_slice(connector.as_bytes());
    info.push(0);
    info.extend_from_slice(&session_n.to_le_bytes());
    info
}

fn labeled_info(
    label: &str,
    policy: &str,
    date_bucket: &str,
    connector: &str,
    session_n: u64,
) -> Vec<u8> {
    let mut info = Vec::from(label.as_bytes());
    info.push(0);
    info.extend_from_slice(&session_info(policy, date_bucket, connector, session_n));
    info
}

fn expand(hk: &Hkdf<Sha256>, info: &[u8], out: &mut [u8]) {
    hk.expand(info, out)
        .expect("HKDF-Expand L fits SHA-256 hash length");
}

/// Derive public identifiers from a 32-byte `host_secret` (IKM).
///
/// `seed` is the host secret, not session secret S. PRK is extracted once.
pub fn derive_public_ids(
    seed: &[u8; 32],
    policy: &str,
    date_bucket: &str,
    connector: &str,
    session_n: u64,
) -> PublicIds {
    let hk = Hkdf::<Sha256>::new(Some(SALT), seed);

    let mut session_secret = [0u8; 32];
    expand(
        &hk,
        &session_info(policy, date_bucket, connector, session_n),
        &mut session_secret,
    );

    let mut edid_bytes = [0u8; 4];
    expand(
        &hk,
        &labeled_info("edid-serial", policy, date_bucket, connector, session_n),
        &mut edid_bytes,
    );

    let mut cec_osd = [0u8; 8];
    expand(
        &hk,
        &labeled_info("cec-osd", policy, date_bucket, connector, session_n),
        &mut cec_osd,
    );

    let mut ts_sid_bytes = [0u8; 2];
    expand(
        &hk,
        &labeled_info("ts-sid", policy, date_bucket, connector, session_n),
        &mut ts_sid_bytes,
    );
    let ts_sid = 1 + (u16::from_be_bytes(ts_sid_bytes) % 0xFFFE);

    let mut ts_tsid_bytes = [0u8; 2];
    expand(
        &hk,
        &labeled_info("ts-tsid", policy, date_bucket, connector, session_n),
        &mut ts_tsid_bytes,
    );
    let ts_tsid = 1 + (u16::from_be_bytes(ts_tsid_bytes) % 0xFFFE);

    let mut ts_onid_byte = [0u8; 1];
    expand(
        &hk,
        &labeled_info("ts-onid", policy, date_bucket, connector, session_n),
        &mut ts_onid_byte,
    );
    let ts_onid = 0xFF00 | u16::from(ts_onid_byte[0]);

    let mut pid_perm_key = [0u8; 32];
    expand(
        &hk,
        &labeled_info("pid-perm", policy, date_bucket, connector, session_n),
        &mut pid_perm_key,
    );

    let mut lan_suffix = [0u8; 3];
    expand(
        &hk,
        &labeled_info("lan-suffix", policy, date_bucket, connector, session_n),
        &mut lan_suffix,
    );

    PublicIds {
        edid_serial_u32: u32::from_be_bytes(edid_bytes),
        cec_osd,
        ts_sid,
        ts_tsid,
        ts_onid,
        pid_perm_key,
        lan_suffix,
        session_secret,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn golden_generic_zero_seed() {
        let s = [0u8; 32];
        let ids = derive_public_ids(&s, "generic", "static", "HDMI-A-1", 0);
        assert_eq!(ids.ts_sid, 0xF5CA);
    }

    #[test]
    fn ephemeral_session_unlinks() {
        let s = [0u8; 32];
        let a = derive_public_ids(&s, "ephemeral", "static", "HDMI-A-1", 0);
        let b = derive_public_ids(&s, "ephemeral", "static", "HDMI-A-1", 1);
        assert_ne!(a.ts_sid, b.ts_sid);
        assert_ne!(a.session_secret, b.session_secret);
    }
}
