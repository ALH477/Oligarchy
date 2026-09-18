use std::path::{Path, PathBuf};

use serde_json::{json, Value};

use crate::config::{Config, UsbRole, USB_META_MIB, WIPE_PHRASE};
use crate::error::{Error, Result};
use crate::store::Store;
use crate::util::{require_tool, run, run_unchecked};

pub fn lsblk_json() -> Result<Value> {
    require_tool("lsblk")?;
    let out = run(
        &[
            "lsblk",
            "-J",
            "-b",
            "-o",
            "NAME,PATH,LABEL,SIZE,FSTYPE,MOUNTPOINT,TRAN,MODEL,SERIAL,TYPE,PARTLABEL,UUID",
        ],
        None,
    )?;
    Ok(serde_json::from_slice(&out.stdout)?)
}

fn walk_nodes(node: &Value, out: &mut Vec<Value>) {
    out.push(node.clone());
    if let Some(children) = node.get("children").and_then(|v| v.as_array()) {
        for c in children {
            walk_nodes(c, out);
        }
    }
}

pub fn all_nodes() -> Result<Vec<Value>> {
    let tree = lsblk_json()?;
    let mut nodes = Vec::new();
    if let Some(devs) = tree.get("blockdevices").and_then(|v| v.as_array()) {
        for d in devs {
            walk_nodes(d, &mut nodes);
        }
    }
    Ok(nodes)
}

/// Every mountpoint lsblk reports for a single node.
///
/// util-linux emits `mountpoint` (a scalar, possibly null) on older versions and
/// `mountpoints` (an array, `[null]` when unmounted) on newer ones. A device with
/// a bind mount or a btrfs subvolume can report several. Read both: missing one
/// of them means a mounted device looks free.
fn node_mountpoints(node: &Value) -> Vec<String> {
    let mut out = Vec::new();
    if let Some(mp) = node.get("mountpoint").and_then(|v| v.as_str()) {
        if !mp.is_empty() {
            out.push(mp.to_string());
        }
    }
    if let Some(list) = node.get("mountpoints").and_then(|v| v.as_array()) {
        for mp in list.iter().filter_map(|v| v.as_str()) {
            if !mp.is_empty() && !out.iter().any(|s| s == mp) {
                out.push(mp.to_string());
            }
        }
    }
    out
}

/// The first mountpoint lsblk reports for this node, in either spelling.
///
/// Every mountpoint lookup goes through here. Four call sites used to read the
/// scalar `mountpoint` directly, so on a util-linux that emits only the
/// `mountpoints` array a mounted stick looked unmounted: `status` showed
/// SEEN-but-not-READY, `push` reported "not mounted" per role, `pull` errored
/// and `usb seed` skipped the sticks — all while the volumes were mounted and
/// writable. One helper means the next format change is one edit.
fn node_mountpoint(node: &Value) -> Option<String> {
    node_mountpoints(node).into_iter().next()
}

fn node_size(node: &Value) -> Option<u64> {
    node.get("size").and_then(|v| v.as_u64()).or_else(|| {
        node.get("size")
            .and_then(|v| v.as_str())
            .and_then(|s| s.parse().ok())
    })
}

/// Refuse anything that is, or sits under, a mount this system is running from.
fn is_system_mount(mp: &str) -> bool {
    mp == "/"
        || mp == "/boot"
        || mp == "/nix"
        || mp.starts_with("/boot/")
        || mp.starts_with("/nix/")
        || mp == "/home"
        || mp.starts_with("/home/")
}

/// Depth-first mount check over a node and *everything* beneath it.
///
/// The subtree matters: with LUKS or LVM the real mountpoint lives on a
/// `/dev/mapper/...` node that is a child of a child of the physical disk and
/// shares none of its name, so a check that only looks at same-named partitions
/// sees an encrypted system disk as unmounted.
fn first_mount_in_subtree(node: &Value) -> Option<(String, String)> {
    let path = node
        .get("path")
        .and_then(|v| v.as_str())
        .or_else(|| node.get("name").and_then(|v| v.as_str()))
        .unwrap_or("<unnamed>")
        .to_string();
    if let Some(mp) = node_mountpoints(node).into_iter().next() {
        return Some((path, mp));
    }
    if let Some(children) = node.get("children").and_then(|v| v.as_array()) {
        for c in children {
            if let Some(hit) = first_mount_in_subtree(c) {
                return Some(hit);
            }
        }
    }
    None
}

// 256 GB class flash is ~240–270 GB. Refuse laptop HDDs / tiny stubs.
const MIN_USB_BYTES: u64 = 64 * 1000 * 1000 * 1000;
const MAX_USB_BYTES: u64 = 512 * 1000 * 1000 * 1000;

/// The whole decision for [`format_usb`], as a pure function over a parsed
/// lsblk tree so it can be tested without a block device.
///
/// `canon` resolves a path the way the filesystem would: it is threaded in
/// rather than called directly so tests can stand in a fake `/dev/disk/by-id`
/// symlink farm. Every outcome that is not "this is definitely a 64–512 GB
/// unmounted stick" is an `Err` — a device we could not find or could not size
/// is refused, never waved through.
fn evaluate_format_target(
    tree: &Value,
    device: &Path,
    canon: &dyn Fn(&Path) -> Option<PathBuf>,
) -> Result<(PathBuf, u64)> {
    let target = canon(device).ok_or_else(|| {
        Error::store(format!(
            "refusing to format {}: cannot resolve it to a real device node (canonicalize failed)",
            device.display()
        ))
    })?;

    let devices = tree
        .get("blockdevices")
        .and_then(|v| v.as_array())
        .map(|v| v.as_slice())
        .unwrap_or(&[]);

    // Match on the canonicalized path, not on the string the caller typed:
    // /dev/disk/by-id/usb-..., /dev//sdb and /dev/sdb are all the same disk and
    // must all land on the same lsblk node.
    let mut matched: Option<&Value> = None;
    for node in devices {
        let Some(path) = node.get("path").and_then(|v| v.as_str()) else {
            continue;
        };
        if canon(Path::new(path)).as_deref() == Some(target.as_path()) {
            matched = Some(node);
            break;
        }
    }

    let node = matched.ok_or_else(|| {
        Error::store(format!(
            "refusing to format {} ({}): lsblk lists no whole-disk device at that path. \
             Pass the disk itself (e.g. /dev/sdb), not a partition.",
            device.display(),
            target.display()
        ))
    })?;

    if let Some((path, mp)) = first_mount_in_subtree(node) {
        if is_system_mount(&mp) {
            return Err(Error::store(format!(
                "refusing to format {}: {path} is mounted at {mp} — that looks like this running system",
                target.display()
            )));
        }
        return Err(Error::store(format!(
            "refusing to format {}: {path} is mounted at {mp}; unmount first",
            target.display()
        )));
    }

    let size = node_size(node).ok_or_else(|| {
        Error::store(format!(
            "refusing to format {}: lsblk reported no usable size for it",
            target.display()
        ))
    })?;
    if !(MIN_USB_BYTES..=MAX_USB_BYTES).contains(&size) {
        return Err(Error::store(format!(
            "refusing to format {}: size {size} B is outside the 64–512 GB window expected for a Reliquary 256 GB stick",
            target.display()
        )));
    }
    Ok((target, size))
}

pub fn find_by_label(label: &str) -> Result<Option<Value>> {
    for n in all_nodes()? {
        if n.get("label").and_then(|v| v.as_str()) == Some(label) {
            return Ok(Some(n));
        }
    }
    Ok(None)
}

fn brief(node: Option<&Value>, label: &str) -> Value {
    match node {
        None => json!({"label": label, "present": false}),
        Some(n) => json!({
            "label": label,
            "present": true,
            "path": n.get("path").and_then(|v| v.as_str()).unwrap_or(""),
            "size": n.get("size").and_then(|v| v.as_u64()).or_else(|| n.get("size").and_then(|v| v.as_str()).and_then(|s| s.parse().ok())).unwrap_or(0),
            "fstype": n.get("fstype"),
            "mountpoint": n.get("mountpoint"),
            "uuid": n.get("uuid"),
        }),
    }
}

pub fn volume_status(cfg: &Config) -> Result<Value> {
    let mut map = serde_json::Map::new();
    for role in [&cfg.usb_a, &cfg.usb_b] {
        let meta = find_by_label(role.meta_label)?;
        let data = find_by_label(role.data_label)?;
        let present = meta.is_some() || data.is_some();
        let ready = data.as_ref().and_then(node_mountpoint).is_some()
            && meta.as_ref().and_then(node_mountpoint).is_some();
        map.insert(
            role.role.to_string(),
            json!({
                "role": role.role,
                "disk_label": role.disk_label,
                "meta": brief(meta.as_ref(), role.meta_label),
                "data": brief(data.as_ref(), role.data_label),
                "present": present,
                "ready": ready,
            }),
        );
    }
    Ok(Value::Object(map))
}

pub fn format_usb(cfg: &Config, device: &Path, role: &UsbRole, confirm: &str) -> Result<Value> {
    let _ = cfg;
    if confirm != WIPE_PHRASE {
        return Err(Error::store(format!(
            "refusing to format {}: pass --confirm {WIPE_PHRASE} after you have triple-checked the device node.",
            device.display()
        )));
    }
    if !device.exists() {
        return Err(Error::store(format!("no such device: {}", device.display())));
    }
    // Resolve the caller's path and re-check the gates against the *resolved*
    // device, then keep using that resolved path for everything below — the
    // string the caller handed us may be a by-id symlink, and sgdisk should be
    // pointed at the node lsblk actually described.
    let (device, _whole_size) =
        evaluate_format_target(&lsblk_json()?, device, &|p: &Path| p.canonicalize().ok())?;
    let device = device.as_path();
    let dev_str = device.to_string_lossy();

    let sgdisk = require_tool("sgdisk")?;
    let mkfs_vfat = require_tool("mkfs.vfat")?;
    let mkfs_ext4 = require_tool("mkfs.ext4")?;

    run(&[&sgdisk, "--zap-all", &dev_str], None)?;
    run(&[&sgdisk, "-og", &dev_str], None)?;
    let n1 = format!("1:0:+{USB_META_MIB}M");
    let c1 = format!("1:{}", role.meta_label);
    run(
        &[&sgdisk, "-n", &n1, "-t", "1:0700", "-c", &c1, &dev_str],
        None,
    )?;
    let c2 = format!("2:{}", role.data_label);
    run(
        &[&sgdisk, "-n", "2:0:0", "-t", "2:8300", "-c", &c2, &dev_str],
        None,
    )?;
    let _ = run_unchecked(&["partprobe", &dev_str], None);

    let (p1, p2) = partition_nodes(device);
    let label11: String = role.meta_label.chars().take(11).collect();
    run(&[&mkfs_vfat, "-F", "32", "-n", &label11, &p1], None)?;
    run(&[&mkfs_ext4, "-F", "-L", role.data_label, "-m", "1", &p2], None)?;
    Ok(json!({
        "device": device.display().to_string(),
        "role": role.role,
        "meta": {"path": p1, "label": role.meta_label, "fstype": "vfat", "size_mib": USB_META_MIB},
        "data": {"path": p2, "label": role.data_label, "fstype": "ext4"},
        "note": "Mount by label, then run: reliquary usb seed && reliquary push --all",
    }))
}

fn partition_nodes(device: &Path) -> (String, String) {
    let name = device
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let base = device.display().to_string();
    if name.starts_with("nvme") || name.starts_with("mmcblk") || name.starts_with("loop") {
        (format!("{base}p1"), format!("{base}p2"))
    } else {
        (format!("{base}1"), format!("{base}2"))
    }
}

pub fn mountpoint_for(label: &str) -> Result<PathBuf> {
    let node = find_by_label(label)?;
    match node.as_ref().and_then(node_mountpoint).map(PathBuf::from) {
        Some(p) => Ok(p),
        None => Err(Error::store(format!(
            "partition labelled {label} is not mounted. e.g. mkdir -p /mnt/{label} && mount -L {label} /mnt/{label}"
        ))),
    }
}

pub fn seed_meta(cfg: &Config, store: &Store) -> Result<Vec<String>> {
    let mut written = Vec::new();
    let catalog = store.catalog()?;
    for role in [&cfg.usb_a, &cfg.usb_b] {
        let node = find_by_label(role.meta_label)?;
        let Some(n) = node else { continue };
        let Some(mp) = node_mountpoint(&n) else {
            continue;
        };
        let root = Path::new(&mp);
        std::fs::write(root.join("README-RELIQUARY.txt"), meta_readme(role))?;
        crate::manifest::write_json(&root.join("catalog.json"), &catalog)?;
        written.push(mp);
    }
    Ok(written)
}

/// Resolve a `--roles` string to the roles it names.
///
/// Errors rather than selecting nothing. The old test was
/// `roles.contains(role.role)` against the `&'static str`s `"A"` and `"B"`, so
/// `--roles a`, `--roles ""` and `--roles "a,b"` matched neither role, took the
/// `continue` arm on both iterations, and returned an empty object that a
/// caller reads as "pushed, nothing to report". Someone could unplug or evict
/// their only local copy on the strength of that — the precise data loss this
/// tool exists to prevent.
///
/// Accepts `A`, `b`, `AB`, `a,b`, `a b`: every alphanumeric character is a role
/// letter, anything unrecognized is refused by name.
fn parse_roles<'a>(cfg: &'a Config, roles: &str) -> Result<Vec<&'a UsbRole>> {
    let known: [&'a UsbRole; 2] = [&cfg.usb_a, &cfg.usb_b];
    let mut want: Vec<&'a UsbRole> = Vec::new();
    let mut unknown = String::new();

    for ch in roles.chars().filter(|c| c.is_alphanumeric()) {
        let up = ch.to_ascii_uppercase();
        match known.iter().copied().find(|r| r.role == up.to_string()) {
            Some(r) => {
                if !want.iter().any(|w| w.role == r.role) {
                    want.push(r);
                }
            }
            None => unknown.push(ch),
        }
    }

    if !unknown.is_empty() {
        return Err(Error::store(format!(
            "unknown USB role(s) {unknown:?} in {roles:?}; expected A, B, or AB"
        )));
    }
    if want.is_empty() {
        return Err(Error::store(format!(
            "no USB role selected by {roles:?}; expected A, B, or AB"
        )));
    }
    Ok(want)
}

pub fn push_block(cfg: &Config, store: &Store, block_id: &str, roles: &str) -> Result<Value> {
    crate::store::validate_block_id(block_id)?;
    let targets = parse_roles(cfg, roles)?;
    let mut map = serde_json::Map::new();
    let mut wrote = 0usize;

    for role in targets {
        let mp = find_by_label(role.data_label)?
            .as_ref()
            .and_then(node_mountpoint);
        match mp {
            Some(mp) => {
                let dest = Path::new(&mp).join("blocks");
                let path = store.copy_block(block_id, &dest, &format!("usb-{}", role.role))?;
                wrote += 1;
                map.insert(
                    role.role.to_string(),
                    json!({"ok": true, "path": path.display().to_string()}),
                );
            }
            None => {
                map.insert(
                    role.role.to_string(),
                    json!({"ok": false, "error": format!("{} not mounted", role.data_label)}),
                );
            }
        }
    }

    // A push that copied nothing is a failure, not a result. Returning Ok here
    // would put the "no USB copy exists" case behind a per-role `ok: false` that
    // a caller has to go looking for; the whole point of the verb is that after
    // it returns Ok, the bytes are somewhere else too.
    if wrote == 0 {
        return Err(Error::store(format!(
            "pushed {block_id} to no USB volume: {}",
            serde_json::to_string(&Value::Object(map)).unwrap_or_default()
        )));
    }

    let _ = seed_meta(cfg, store);
    Ok(Value::Object(map))
}

pub fn pull_block(cfg: &Config, store: &Store, block_id: &str, role_name: &str) -> Result<PathBuf> {
    crate::store::validate_block_id(block_id)?;
    let role = cfg.role(role_name);
    let root = mountpoint_for(role.data_label)?;
    let src = root.join("blocks").join(block_id);
    if !src.exists() {
        return Err(Error::store(format!(
            "{block_id} not on USB {} ({})",
            role.role,
            src.display()
        )));
    }
    let dest = store.block_dir(block_id);
    if dest.exists() {
        return Err(Error::store(format!(
            "{block_id} already in local store; verify instead"
        )));
    }
    crate::util::copy_dir_all(&src, &dest)?;
    Ok(dest)
}

fn meta_readme(role: &UsbRole) -> String {
    let other = if role.role == "A" { "B" } else { "A" };
    format!(
        "RELIQUARY USB {role}\n\
         ====================\n\n\
         This stick is one half of a duplicated pair.\n\n\
           Disk GPT label : {disk}\n\
           This partition : {meta}  (FAT32 catalog)\n\
           Data partition : {data}  (ext4 blocks)\n\n\
         Each block under the data partition is a self-contained preservation\n\
         unit:\n\n\
           manifest.json     identity, origin, hashes\n\
           payload.tar.zst   the files\n\
           SHA256SUMS / SHA512SUMS\n\
           payload.tar.zst.par2 + recovery volumes\n\n\
         Verify a block without Reliquary installed:\n\n\
           sha256sum -c SHA256SUMS\n\
           par2 verify payload.tar.zst.par2\n\n\
         Extract:\n\n\
           tar -xf payload.tar.zst\n\n\
         The sibling stick (role {other}) is an identical copy. Prefer verifying\n\
         both after any write. CD-R images for the same blocks live in the local\n\
         store's iso/ directory and can be burned with xorriso.\n",
        role = role.role,
        disk = role.disk_label,
        meta = role.meta_label,
        data = role.data_label,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn test_cfg() -> Config {
        Config {
            store_root: PathBuf::from("/tmp/reliquary-test"),
            work_root: PathBuf::from("/tmp/reliquary-test/work"),
            par2_redundancy: 20,
            par2_volumes: 4,
            zstd_level: 19,
            cd_capacity_bytes: 700 * 1024 * 1024,
            cd_payload_bytes: 600 * 1024 * 1024,
            usb_a: UsbRole::a(),
            usb_b: UsbRole::b(),
        }
    }

    fn roles_of(cfg: &Config, s: &str) -> Vec<String> {
        parse_roles(cfg, s)
            .unwrap()
            .into_iter()
            .map(|r| r.role.to_string())
            .collect()
    }

    /// The regression this guards: `roles.contains("A")` is case-sensitive, so
    /// a lowercase or empty selector matched nothing, skipped both roles and
    /// returned `{}` — read by a caller as a push that succeeded.
    #[test]
    fn a_role_selector_that_names_nothing_is_refused_not_ignored() {
        let cfg = test_cfg();
        assert!(parse_roles(&cfg, "").is_err());
        assert!(parse_roles(&cfg, "   ").is_err());
        assert!(parse_roles(&cfg, ",").is_err());
    }

    #[test]
    fn an_unknown_role_is_refused_by_name() {
        let cfg = test_cfg();
        let err = parse_roles(&cfg, "c").unwrap_err().to_string();
        assert!(err.contains('c'), "error should name the bad role: {err}");
        assert!(parse_roles(&cfg, "ax").is_err());
    }

    #[test]
    fn role_selectors_are_case_and_separator_insensitive() {
        let cfg = test_cfg();
        assert_eq!(roles_of(&cfg, "a"), ["A"]);
        assert_eq!(roles_of(&cfg, "A"), ["A"]);
        assert_eq!(roles_of(&cfg, "b"), ["B"]);
        for both in ["AB", "ab", "a,b", "a b", "A, B", "ba"] {
            let got = roles_of(&cfg, both);
            assert_eq!(got.len(), 2, "{both:?} should select both roles, got {got:?}");
            assert!(got.contains(&"A".to_string()) && got.contains(&"B".to_string()));
        }
    }

    #[test]
    fn a_repeated_role_is_selected_once() {
        let cfg = test_cfg();
        assert_eq!(roles_of(&cfg, "aa"), ["A"]);
        assert_eq!(roles_of(&cfg, "aab").len(), 2);
    }

    /// Newer util-linux emits only the `mountpoints` array. Every lookup goes
    /// through `node_mountpoint`, so a mounted stick must never look free.
    #[test]
    fn a_mountpoint_is_found_in_either_lsblk_spelling() {
        let scalar = json!({ "mountpoint": "/mnt/reliquary/data-a" });
        let array = json!({ "mountpoints": ["/mnt/reliquary/data-a"] });
        let both = json!({
            "mountpoint": "/mnt/reliquary/data-a",
            "mountpoints": ["/mnt/reliquary/data-a"]
        });
        for node in [&scalar, &array, &both] {
            assert_eq!(
                node_mountpoint(node).as_deref(),
                Some("/mnt/reliquary/data-a")
            );
        }
    }

    #[test]
    fn an_unmounted_node_reports_no_mountpoint_in_either_spelling() {
        assert_eq!(node_mountpoint(&json!({ "mountpoint": null })), None);
        assert_eq!(node_mountpoint(&json!({ "mountpoint": "" })), None);
        assert_eq!(node_mountpoint(&json!({ "mountpoints": [null] })), None);
        assert_eq!(node_mountpoint(&json!({ "mountpoints": [] })), None);
        assert_eq!(node_mountpoint(&json!({})), None);
    }

    /// Stand-in for `Path::canonicalize`: an alias table plus slash squashing,
    /// with anything unknown reported as non-existent (canonicalize's ENOENT).
    fn fake_canon(p: &Path) -> Option<PathBuf> {
        let raw = p.to_string_lossy();
        let squashed = format!("/{}", raw.split('/').filter(|s| !s.is_empty()).collect::<Vec<_>>().join("/"));
        let resolved = match squashed.as_str() {
            "/dev/disk/by-id/usb-Reliquary_256GB-0:0" => "/dev/sdb",
            "/dev/disk/by-id/ata-SYSTEM_DISK-1" => "/dev/sda",
            other => other,
        };
        let real = ["/dev/sda", "/dev/sdb", "/dev/sdb1", "/dev/mapper/cryptroot"];
        real.contains(&resolved).then(|| PathBuf::from(resolved))
    }

    fn eval(tree: &Value, device: &str) -> Result<(PathBuf, u64)> {
        evaluate_format_target(tree, Path::new(device), &fake_canon)
    }

    /// /dev/sda is a 1 TB system disk whose only mountpoints live on a LUKS
    /// mapper node two levels down; /dev/sdb is a clean 256 GB stick.
    fn tree() -> Value {
        json!({"blockdevices": [
            {
                "name": "sda", "path": "/dev/sda", "size": 1_000_204_886_016u64,
                "type": "disk", "mountpoint": null,
                "children": [{
                    "name": "sda2", "path": "/dev/sda2", "size": 999_000_000_000u64,
                    "type": "part", "fstype": "crypto_LUKS", "mountpoint": null,
                    "children": [{
                        "name": "cryptroot", "path": "/dev/mapper/cryptroot",
                        "type": "crypt", "mountpoint": "/"
                    }]
                }]
            },
            {
                "name": "sdb", "path": "/dev/sdb", "size": 256_060_514_304u64,
                "type": "disk", "tran": "usb", "mountpoint": null
            }
        ]})
    }

    #[test]
    fn a_by_id_alias_resolves_to_the_same_disk_and_is_still_gated() {
        // The whole point: the old string compare found no node for a by-id
        // path, left whole_size at 0, and skipped every gate.
        let err = eval(&tree(), "/dev/disk/by-id/ata-SYSTEM_DISK-1").unwrap_err();
        let msg = err.to_string();
        assert!(msg.contains("refusing to format"), "{msg}");
        assert!(msg.contains("this running system"), "{msg}");

        // ...and the alias for the legitimate stick resolves to it.
        let (path, size) = eval(&tree(), "/dev/disk/by-id/usb-Reliquary_256GB-0:0").unwrap();
        assert_eq!(path, Path::new("/dev/sdb"));
        assert_eq!(size, 256_060_514_304);
    }

    #[test]
    fn a_luks_mapper_child_mount_is_found_deep_in_the_subtree() {
        // /dev/mapper/cryptroot is a child of a child of /dev/sda and shares
        // none of its name, so prefix matching never saw it.
        let err = eval(&tree(), "/dev/sda").unwrap_err();
        let msg = err.to_string();
        assert!(msg.contains("/dev/mapper/cryptroot"), "{msg}");
        assert!(msg.contains("this running system"), "{msg}");
    }

    #[test]
    fn a_redundant_slash_does_not_dodge_the_gates() {
        let err = eval(&tree(), "/dev//sda").unwrap_err();
        assert!(err.to_string().contains("refusing to format"), "{err}");
        assert_eq!(eval(&tree(), "/dev//sdb").unwrap().0, Path::new("/dev/sdb"));
    }

    #[test]
    fn a_device_absent_from_lsblk_is_refused_not_waved_through() {
        // Present on disk, but lsblk lists no whole-disk node for it: a
        // partition, say. Unknown size must mean refuse, not "size 0, skip".
        let t = json!({"blockdevices": [{"name": "sdb", "path": "/dev/sdb", "size": 256_060_514_304u64, "type": "disk"}]});
        let err = eval(&t, "/dev/sdb1").unwrap_err();
        assert!(err.to_string().contains("lsblk lists no whole-disk device"), "{err}");
    }

    #[test]
    fn an_unresolvable_path_is_refused() {
        let err = eval(&tree(), "/dev/sdz").unwrap_err();
        assert!(err.to_string().contains("canonicalize failed"), "{err}");
    }

    #[test]
    fn the_size_window_still_applies_to_a_found_device() {
        let small = json!({"blockdevices": [{"name": "sdb", "path": "/dev/sdb", "size": 8_000_000_000u64, "type": "disk"}]});
        let err = eval(&small, "/dev/sdb").unwrap_err();
        assert!(err.to_string().contains("outside the 64–512 GB window"), "{err}");

        let missing = json!({"blockdevices": [{"name": "sdb", "path": "/dev/sdb", "type": "disk"}]});
        let err = eval(&missing, "/dev/sdb").unwrap_err();
        assert!(err.to_string().contains("no usable size"), "{err}");
    }

    #[test]
    fn a_mountpoints_array_counts_as_mounted() {
        // Newer util-linux emits `mountpoints: [...]` and no scalar field.
        let t = json!({"blockdevices": [{
            "name": "sdb", "path": "/dev/sdb", "size": 256_060_514_304u64, "type": "disk",
            "children": [{"name": "sdb1", "path": "/dev/sdb1", "mountpoints": ["/run/media/asher/RELIQUARY"]}]
        }]});
        let err = eval(&t, "/dev/sdb").unwrap_err();
        assert!(err.to_string().contains("unmount first"), "{err}");
    }
}
