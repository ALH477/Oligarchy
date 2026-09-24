#!/usr/bin/env bash
# No-KVM gate for bin/captive-vm-run.sh. Drives the real orchestrator against
# fakes (fakes-vm/) for everything that needs root or hardware — ip, nft,
# dnsmasq, systemd-run, systemctl, nmcli, chvt — and REAL jq, sha256sum and
# ssh-keygen, so the reference, hash and signature checks are the ones that
# ship. Asserts:
#   - every verification refusal (reference, hashes, policy, tree, signature,
#     key shape, cmdline, /dev/kvm, uplink) refuses, and discard still runs
#   - the display decision (GPU only when the whole IOMMU group is vfio-pci)
#   - the exact QEMU argv and unit sandbox for both modes
#   - the lifecycle: full, timeout, VMM exit, link change, SIGTERM, GPU guest
#     exiting at once -> framebuffer fallback; every one leaves nothing behind
#   - the audit log's hash chain, and that tampering breaks it
#
#   bash modules/captive-portal/tests/vm-run.sh     (or: nix build .#captive-portal-tests)
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BIN=${BIN:-$here/../bin}
FAKES=$here/fakes-vm
POLICY=$here/../vm/policy.nft

work=$(mktemp -d)
cleanup() {
  [ -n "${opid:-}" ] && kill "$opid" 2> /dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

# Resolved BEFORE the fakes go on PATH: fakes-vm/install has to reach the
# real coreutils one to actually create the directories.
FAKE_REAL_INSTALL=$(command -v install)
export FAKE_REAL_INSTALL
export PATH="$FAKES:$PATH"
export FAKE_DIR=$work/fake FAKE_LOG=$work/fake/log
export FAKE_ROUTE=$work/route.json FAKE_ROUTE2=$work/route2.json
export CVM_RUNDIR=$work/run CVM_STATEDIR=$work/state CVM_STATUS=$work/status/vm-status
export CVM_USER CVM_GROUP CVM_VIEW_GROUP
CVM_USER=$(id -un)
# The orchestrator's `install -o USER -g GROUP` is real, not faked, so both
# names must exist on whatever host runs this gate. A login user's name is
# usually NOT also a group name (here: asher's primary group is `users`), so
# the VM user's own group has to come from id -gn rather than from CVM_USER.
CVM_GROUP=$(id -gn)
CVM_VIEW_GROUP=$(id -gn)
export CVM_QEMU=/fake/bin/qemu-system-x86_64 CVM_CORESCHED=$FAKES/coresched CVM_DNSMASQ=$FAKES/dnsmasq
export CVM_SYSFS=$work/sys CVM_DEVDIR=$work/dev CVM_PROCSYS=$work/procsys
export CVM_SIG=$work/state/manifest.sig CVM_PUBKEY=""
export FAKE_VNC_SOCK=$CVM_RUNDIR/vnc/vnc.sock
unset CVM_GPU_FUNCTIONS CVM_CPU CVM_GPU_ROM CVM_GPU_INPUTS

ran=0
fail=0
check() {
  local name=$1
  shift
  ran=$((ran + 1))
  if "$@"; then
    echo "PASS  $name"
  else
    echo "FAIL  $name" >&2
    # The orchestrator's own stderr is the only thing that says WHY it
    # refused, and it goes to $work/err (orch() above). Without this a
    # failure here is just a name, which is what made the CVM_GROUP break
    # take a local re-run to diagnose instead of being readable in CI.
    [ -s "$work/err" ] && sed 's/^/        | /' "$work/err" >&2
    fail=1
  fi
}
has() { grep -qF -- "$1" "$2"; }
hasx() { grep -qxF -- "$1" "$2"; }
# A negative assertion over a file that does not exist inspected NOTHING and
# must fail, not pass: when the orchestrator broke before writing
# systemd-run.argv at all, the core-scheduling check below went green on a
# missing file while every other check in its group failed.
hasnt() { [ -e "$2" ] && ! grep -qF -- "$1" "$2"; }
last_audit() { tail -n 1 "$CVM_STATEDIR/audit.log" | jq -r "$1"; }

# ── host fixture ───────────────────────────────────────────────────────────
mkdir -p "$work/dev/input/by-path" "$work/dev/vfio" "$work/procsys/net/ipv4/conf/wlp1s0" \
  "$work/procsys/net/ipv4/conf/cp0" "$work/procsys/net/ipv4/conf/eth0" \
  "$work/sys/devices/system/cpu/smt" "$FAKE_DIR"
ln -s /dev/null "$work/dev/kvm" # any character device will do for [ -c ]
echo 0 > "$work/sys/devices/system/cpu/smt/active"
echo '[{"dst":"default","gateway":"192.168.1.1","dev":"wlp1s0","metric":600}]' > "$FAKE_ROUTE"
echo '[{"dst":"default","gateway":"10.0.0.1","dev":"eth0","metric":100}]' > "$FAKE_ROUTE2"

reset() {
  rm -rf "$FAKE_DIR" "$CVM_RUNDIR" "$work/status"
  mkdir -p "$FAKE_DIR"
  : > "$FAKE_LOG"
  echo 0 > "$work/procsys/net/ipv4/conf/wlp1s0/forwarding"
  echo 0 > "$work/procsys/net/ipv4/conf/cp0/forwarding"
  unset FAKE_NM_FULL_AFTER FAKE_QEMU_DIES FAKE_GPU_DIES FAKE_ROUTE_SWITCH_AFTER FAKE_CORESCHED_OK
}

# ── image fixture: fake boot files, a real manifest, the real policy ──────
mk_image() { # mk_image [cmdline]
  local img=$work/img cmdline=${1:-"panic=-1 reboot=t quiet init=/nix/store/x-toplevel/init"}
  rm -rf "$img"
  mkdir -p "$img"
  printf 'kernel-bytes' > "$img/bzImage"
  printf 'initrd-bytes' > "$img/initrd"
  head -c 8192 /dev/zero > "$img/store.erofs"
  printf 'hash-tree-bytes' > "$img/verity.img"
  cp "$POLICY" "$img/policy.nft"
  s() { sha256sum "$1" | cut -c1-64; }
  jq -n --sort-keys \
    --arg k "$img/bzImage" --arg ks "$(s "$img/bzImage")" \
    --arg i "$img/initrd" --arg is "$(s "$img/initrd")" \
    --arg st "$img/store.erofs" --arg sts "$(s "$img/store.erofs")" \
    --arg t "$img/verity.img" --arg ts "$(s "$img/verity.img")" \
    --arg r "$(printf root | sha256sum | cut -c1-64)" \
    --arg c "$cmdline" \
    --arg n "$img/policy.nft" --arg ns "$(s "$img/policy.nft")" \
    '{schema: "oligarchy-captive-vm/1",
      kernel: {path: $k, sha256: $ks}, initrd: {path: $i, sha256: $is},
      store: {path: $st, sha256: $sts,
              verity: {hashTree: $t, hashTreeSha256: $ts, root: $r, algorithm: "sha256", blockSize: 4096}},
      cmdline: $c, guest: {toplevel: "/nix/store/x-toplevel"},
      policy: {nft: $n, nftSha256: $ns,
               limits: {memMiB: 512, timeoutSec: 4, probeIntervalSec: 1, gpuGraceSec: 3}},
      inputs: {}}' > "$img/manifest.json"
  export CVM_MANIFEST=$img/manifest.json
  CVM_REFERENCE=$(s "$img/manifest.json")
  export CVM_REFERENCE
}

# ── GPU fixture: two functions in IOMMU group 14 ───────────────────────────
mk_gpu() { # mk_gpu <driver of .0> <driver of .1> [<driver of a third group member>]
  local S=$work/sys f drv i=0
  rm -rf "$S/bus" "$S/kernel" "$work/dev/vfio" "$work/dev/input"
  mkdir -p "$S/kernel/iommu_groups/14/devices" "$work/dev/vfio" "$work/dev/input/by-path"
  local fns=("0000:03:00.0" "0000:03:00.1" "0000:03:00.2")
  for drv in "$@"; do
    f=${fns[$i]}
    mkdir -p "$S/bus/pci/devices/$f"
    ln -s "../../../../bus/pci/drivers/$drv" "$S/bus/pci/devices/$f/driver"
    ln -s "../../../kernel/iommu_groups/14" "$S/bus/pci/devices/$f/iommu_group"
    ln -s "$S/bus/pci/devices/$f" "$S/kernel/iommu_groups/14/devices/$f"
    i=$((i + 1))
  done
  : > "$work/dev/vfio/14"
  : > "$work/dev/input/event3"
  : > "$work/dev/input/event5"
  ln -s ../event3 "$work/dev/input/by-path/platform-i8042-serio-0-event-kbd"
  ln -s ../event5 "$work/dev/input/by-path/pci-0000:c4:00.3-usb-0:1:1.0-event-mouse"
  export CVM_GPU_FUNCTIONS="0000:03:00.0 0000:03:00.1"
}
no_gpu() { unset CVM_GPU_FUNCTIONS; rm -rf "$work/sys/bus" "$work/sys/kernel"; }

orch() { bash "$BIN/captive-vm-run.sh" "$@" > "$work/out" 2> "$work/err"; }
refuses() { # refuses <reason fragment> <cmd...>
  local frag=$1
  shift
  if "$@"; then return 1; fi
  grep -qF -- "$frag" "$work/err"
}

reset
mk_image

# ── verification ───────────────────────────────────────────────────────────
check "verify: a good image verifies" orch verify
check "verify: prints the reference" has "reference=$CVM_REFERENCE" "$work/out"
check "verify: signature is 'none' without a key" has "signature=none" "$work/out"
check "verify: staged copies are cleaned up" test ! -e "$CVM_RUNDIR/boot"

bad_ref() { CVM_REFERENCE=$(printf other | sha256sum | cut -c1-64) orch verify; }
check "verify: refuses a manifest that is not the baked reference" refuses "does not match the reference" bad_ref

printf 'evil' >> "$work/img/bzImage"
check "verify: refuses a kernel that differs from the manifest" refuses "kernel does not match" orch verify
mk_image
printf 'evil' >> "$work/img/initrd"
check "verify: refuses an initrd that differs from the manifest" refuses "initrd does not match" orch verify
mk_image
printf '\n' >> "$work/img/policy.nft"
check "verify: refuses an egress policy that differs from the manifest" refuses "egress policy does not match" orch verify
mk_image
printf 'x' >> "$work/img/verity.img"
check "verify: refuses a hash tree that differs from the manifest" refuses "hash tree does not match" orch verify
mk_image "panic=-1 captive.verity=0000"
check "verify: refuses a cmdline that already carries captive.verity=" refuses "already carries captive.verity" orch verify
mk_image
no_kvm() { CVM_DEVDIR=$work/nodev orch verify; }
check "verify: refuses without /dev/kvm" refuses "no $work/nodev/kvm" no_kvm

# ── signature ──────────────────────────────────────────────────────────────
ssh-keygen -q -t ed25519 -N '' -C captive-vm -f "$work/key"
ssh-keygen -q -t ed25519 -N '' -C other -f "$work/other"
pub=$(cut -d' ' -f1,2 "$work/key.pub")
mkdir -p "$CVM_STATEDIR"
ssh-keygen -Y sign -q -f "$work/key" -n oligarchy-captive-vm < "$CVM_MANIFEST" > "$CVM_SIG"
with_key() { CVM_PUBKEY=$pub orch verify; }
check "signature: a good signature verifies" with_key
check "signature: reported as ok" has "signature=ok" "$work/out"
wrong_key() { CVM_PUBKEY=$(cut -d' ' -f1,2 "$work/other.pub") orch verify; }
check "signature: refuses a signature from another key" refuses "does not verify" wrong_key
ssh-keygen -Y sign -q -f "$work/key" -n some-other-namespace < "$CVM_MANIFEST" > "$work/wrongns.sig"
wrong_ns() { CVM_PUBKEY=$pub CVM_SIG=$work/wrongns.sig orch verify; }
check "signature: refuses a signature for another namespace" refuses "does not verify" wrong_ns
missing_sig() { CVM_PUBKEY=$pub CVM_SIG=$work/absent.sig orch verify; }
check "signature: refuses when required and missing" refuses "is missing" missing_sig
injected_key() { CVM_PUBKEY="cert-authority,$pub" orch verify; }
check "signature: refuses a key string carrying allowed_signers options" refuses "not a bare ssh-ed25519" injected_key
injected_key2() { CVM_PUBKEY="$pub extra" orch verify; }
check "signature: refuses a key string with trailing fields" refuses "not a bare ssh-ed25519" injected_key2

# ── plan: framebuffer ──────────────────────────────────────────────────────
no_gpu
orch plan
P=$work/out
check "plan/fb: no GPU configured -> framebuffer" hasx "mode=framebuffer reason=no GPU configured" "$P"
check "plan/fb: VNC only on a unix socket in the run dir" hasx "arg: unix:$CVM_RUNDIR/vnc/vnc.sock" "$P"
check "plan/fb: 2D virtio-gpu at the configured size" hasx "arg: virtio-gpu-pci,xres=1600,yres=1000" "$P"
check "plan/fb: virtio keyboard and tablet" has "arg: virtio-tablet-pci" "$P"
check "plan/fb: no VFIO device" hasnt "vfio-pci" "$P"
check "plan/fb: root hash appended to the manifest cmdline" \
  hasx "arg: panic=-1 reboot=t quiet init=/nix/store/x-toplevel/init captive.verity=$(printf root | sha256sum | cut -c1-64)" "$P"
check "plan/fb: store and hash tree are read-only drives" \
  hasx "arg: id=store,format=raw,read-only=on,file=$work/img/store.erofs,if=none" "$P"
check "plan/fb: disks carry the serials the guest's initrd waits for" hasx "arg: virtio-blk-pci,drive=verity,serial=nixverity" "$P"
check "plan/fb: boots the staged copies, not the store paths" hasx "arg: $CVM_RUNDIR/boot/kernel" "$P"
check "plan/fb: tap without vhost-net" hasx "arg: tap,id=net0,ifname=cp0,script=no,downscript=no,vhost=off" "$P"
check "plan/fb: QEMU seccomp sandbox with every deny" \
  hasx "arg: on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny" "$P"
check "plan/fb: KSM off for this guest" hasx "arg: q35,accel=kvm,mem-merge=off" "$P"
check "plan/fb: no guest serial by default" hasx "arg: none" "$P"
check "plan/fb: unit runs as the VM user with no capabilities" hasx "prop: CapabilityBoundingSet=" "$P"
check "plan/fb: unit device policy is closed" hasx "prop: DevicePolicy=closed" "$P"
check "plan/fb: unit may open /dev/kvm" hasx "prop: DeviceAllow=/dev/kvm rw" "$P"
check "plan/fb: unit gets no VFIO and no input group" hasnt "vfio" "$P"
check "plan/fb: unit memory is capped" hasx "prop: MemoryMax=1280M" "$P"

debugged() {
  CVM_DEBUG=1 orch plan &&
    hasx "arg: file:$CVM_RUNDIR/ctl/serial.log" "$work/out" &&
    has "captive.verity=$(printf root | sha256sum | cut -c1-64) console=ttyS0 systemd.show_status=1" "$work/out"
}
check "plan: debug sends the guest console to the run dir, with unit status" debugged
pinned() { CVM_CPU=4 orch plan && hasx "prop: AllowedCPUs=4" "$work/out"; }
check "plan: a configured core pins the VMM" pinned

# ── plan: GPU ──────────────────────────────────────────────────────────────
mk_gpu vfio-pci vfio-pci
orch plan
check "plan/gpu: whole group on vfio-pci -> gpu" has "mode=gpu reason=GPU 0000:03:00.0 0000:03:00.1 in IOMMU group 14" "$P"
check "plan/gpu: first function multifunction on a root port" \
  hasx "arg: vfio-pci,host=0000:03:00.0,bus=rp0,addr=0.0,multifunction=on" "$P"
check "plan/gpu: second function at .1" hasx "arg: vfio-pci,host=0000:03:00.1,bus=rp0,addr=0.1" "$P"
check "plan/gpu: keyboard grabbed exclusively, with a toggle" \
  hasx "arg: input-linux,id=kbd0,evdev=$work/dev/input/event3,grab_all=on,repeat=on,grab-toggle=ctrl-ctrl" "$P"
check "plan/gpu: pointer passed" hasx "arg: input-linux,id=ptr0,evdev=$work/dev/input/event5" "$P"
check "plan/gpu: no VNC, no virtio-gpu" hasnt "vnc.sock" "$P"
check "plan/gpu: unit may open exactly this VFIO group" hasx "prop: DeviceAllow=/dev/vfio/14 rw" "$P"
check "plan/gpu: unit may read exactly the grabbed input devices" hasx "prop: DeviceAllow=$work/dev/input/event3 r" "$P"
check "plan/gpu: VFIO can pin guest memory" hasx "prop: LimitMEMLOCK=infinity" "$P"
rom() { CVM_GPU_ROM=/etc/vbios.rom orch plan && hasx "arg: vfio-pci,host=0000:03:00.0,bus=rp0,addr=0.0,multifunction=on,romfile=/etc/vbios.rom" "$work/out"; }
check "plan/gpu: a VBIOS file is attached to the first function" rom

mk_gpu amdgpu vfio-pci
orch plan
check "plan/gpu: a function on amdgpu -> framebuffer" hasx "mode=framebuffer reason=0000:03:00.0 is bound to amdgpu, not vfio-pci" "$P"
mk_gpu vfio-pci vfio-pci xhci_hcd
orch plan
check "plan/gpu: another endpoint in the group on a host driver -> framebuffer" \
  hasx "mode=framebuffer reason=IOMMU group 14 also holds 0000:03:00.2 bound to xhci_hcd" "$P"
mk_gpu vfio-pci vfio-pci pcieport
orch plan
check "plan/gpu: a PCIe bridge in the group is allowed" has "mode=gpu" "$P"
mk_gpu vfio-pci vfio-pci
rm "$work/dev/input/by-path/"*-event-kbd
orch plan
check "plan/gpu: no keyboard to hand over -> framebuffer" hasx "mode=framebuffer reason=no keyboard to hand the GPU guest" "$P"
mk_gpu vfio-pci vfio-pci
rm -rf "$work/sys/kernel/iommu_groups/"*
orch plan
check "plan/gpu: IOMMU off -> framebuffer" hasx "mode=framebuffer reason=IOMMU is off" "$P"
no_gpu

# ── run: the happy path ────────────────────────────────────────────────────
reset
export FAKE_NM_FULL_AFTER=2
check "run/fb: exits 0 when the portal lets us through" orch run
L=$FAKE_LOG
check "run/fb: result full in the audit log" test "$(last_audit .result)" = full
check "run/fb: audit carries the reference" test "$(last_audit .reference)" = "$CVM_REFERENCE"
check "run/fb: audit carries the uplink's connection name, escaped" test "$(last_audit .connection)" = 'Venue "Guest" Wi-Fi'
check "run/fb: tap created for the VM user only" hasx "ip tuntap add dev cp0 mode tap user $CVM_USER group $CVM_GROUP" "$L"
check "run/fb: egress policy loaded with the uplink substituted" has 'oifname "wlp1s0" ip saddr 10.207.0.2 tcp dport { 80, 443 } accept' "$FAKE_DIR/nft-loaded"
check "run/fb: no placeholder left in the loaded policy" hasnt "@UPLINK@" "$FAKE_DIR/nft-loaded"
check "run/fb: DNS forwarder on the tap address only" has "--listen-address=10.207.0.1" "$L"
check "run/fb: forwarder answers from resolved's stub" has "--server=127.0.0.53" "$L"
check "run/fb: VMM started under core scheduling only when SMT is on (it is off here)" hasnt "coresched new -- /fake" "$FAKE_DIR/systemd-run.argv"
check "run/fb: the VNC socket dir is setgid to the viewer group" \
  hasx "install -d -m 2750 -o $CVM_USER -g $CVM_VIEW_GROUP $CVM_RUNDIR/vnc" "$L"
check "run/fb: the control dir is private to the VM user" \
  hasx "install -d -m 0700 -o $CVM_USER -g $CVM_GROUP $CVM_RUNDIR/ctl" "$L"
check "run/fb: viewer started" hasx "systemctl start captive-vm-viewer.service" "$L"
check "run/fb: switched to the VM's VT" hasx "chvt 7" "$L"
check "run/fb: told systemd it is ready" has "systemd-notify --ready" "$L"
check "discard: viewer stopped" hasx "systemctl stop captive-vm-viewer.service" "$L"
check "discard: back on the original VT" hasx "chvt 1" "$L"
check "discard: VMM stopped" hasx "systemctl stop captive-vm-qemu.service" "$L"
check "discard: forwarder stopped" hasx "dnsmasq stopped" "$L"
check "discard: egress table deleted" hasx "nft delete table inet captive_vm" "$L"
check "discard: tap deleted" hasx "ip link del cp0" "$L"
check "discard: uplink forwarding restored" test "$(cat "$work/procsys/net/ipv4/conf/wlp1s0/forwarding")" = 0
check "discard: staged boot files removed" test ! -e "$CVM_RUNDIR/boot"
check "discard: status file says full" test "$(jq -r .state "$CVM_STATUS")" = full
check "discard: status file is world-readable" test "$(stat -c %a "$CVM_STATUS")" = 644

before() { # before <first> <second> — both logged, first earlier
  local a b
  a=$(grep -nxF -- "$1" "$FAKE_LOG" | head -n 1 | cut -d: -f1)
  b=$(grep -nxF -- "$2" "$FAKE_LOG" | head -n 1 | cut -d: -f1)
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}
check "run/fb: VT switched before the viewer starts (its session is born active)" \
  before "chvt 7" "systemctl start captive-vm-viewer.service"
check "run/fb: no stale state, nothing pre-cleaned" test "$(grep -c '^ip link del cp0$' "$FAKE_LOG")" = 1

reset
touch "$FAKE_DIR/stale-tap" "$FAKE_DIR/stale-table"
export FAKE_NM_FULL_AFTER=1
check "run/stale: a tap and table left by a killed run are cleared first" orch run
check "run/stale: the stale tap was deleted before the new one was made" \
  before "ip link del cp0" "ip tuntap add dev cp0 mode tap user $CVM_USER group $CVM_GROUP"
check "run/stale: the stale table was deleted before the policy loaded" \
  before "nft delete table inet captive_vm" "nft -f -"

# ── run: other endings ─────────────────────────────────────────────────────
reset
check "run/timeout: exits 0" orch run
check "run/timeout: result timeout" test "$(last_audit .result)" = timeout
check "run/timeout: still discarded" hasx "ip link del cp0" "$FAKE_LOG"

reset
export FAKE_QEMU_DIES=1
orch run || true
check "run/vmm-exit: guest powering off ends the run" test "$(last_audit .result)" = vmm-exit
check "run/vmm-exit: still discarded" hasx "nft delete table inet captive_vm" "$FAKE_LOG"

reset
export FAKE_ROUTE_SWITCH_AFTER=1
orch run || true
check "run/link-change: default route moving ends the run" test "$(last_audit .result)" = link-change

reset
mk_gpu vfio-pci vfio-pci
export FAKE_GPU_DIES=1 FAKE_NM_FULL_AFTER=2
orch run || true
check "run/gpu: a GPU guest that exits at once falls back to the framebuffer" test "$(last_audit .fallback)" = gpu-no-display
check "run/gpu: the run then completes on the framebuffer" test "$(last_audit .result)/$(last_audit .mode)" = full/framebuffer
check "run/gpu: two VMM starts, the second without VFIO" \
  test "$(grep -c '^--- systemd-run' "$FAKE_DIR/systemd-run.argv")" = 2
check "run/gpu: the viewer came up only for the fallback" hasx "systemctl start captive-vm-viewer.service" "$FAKE_LOG"
no_gpu

reset
echo 1 > "$work/sys/devices/system/cpu/smt/active"
export FAKE_NM_FULL_AFTER=1
orch run || true
check "run/smt: VMM runs under a new core-scheduling cookie" hasx "new" "$FAKE_DIR/systemd-run.argv"
reset
echo 1 > "$work/sys/devices/system/cpu/smt/active"
export FAKE_CORESCHED_OK=0
check "run/smt: SMT on without core scheduling refuses" refuses "core scheduling is unavailable" orch run
check "run/smt: the refusal is audited" test "$(last_audit .result)" = refused
check "run/smt: the refusal still tore down the network" hasx "ip link del cp0" "$FAKE_LOG"
echo 0 > "$work/sys/devices/system/cpu/smt/active"

reset
echo '[{"dst":"default","dev":"tailscale0","metric":0}]' > "$work/route-ts.json"
via_ts() { FAKE_ROUTE=$work/route-ts.json orch run; }
check "run: refuses when the default route is the tailnet" refuses "via tailscale0" via_ts
reset
echo '[{"dst":"default","dev":"wl;p","metric":0}]' > "$work/route-odd.json"
odd() { FAKE_ROUTE=$work/route-odd.json orch run; }
check "run: refuses an uplink name that is not a plain interface name" refuses "not a plain interface name" odd
check "run: refused before creating anything" hasnt "ip tuntap add" "$FAKE_LOG"

reset
bad_run() { CVM_REFERENCE=$(printf other | sha256sum | cut -c1-64) orch run; }
check "run: a bad reference refuses" refuses "does not match the reference" bad_run
check "run: the refusal names its reason in the status file" has "does not match the reference" "$CVM_STATUS"
check "run: the refusal is audited with its reason" has "does not match the reference" "$CVM_STATEDIR/audit.log"

reset
bash "$BIN/captive-vm-run.sh" run > "$work/out" 2> "$work/err" &
opid=$!
for _ in $(seq 1 50); do grep -q "systemd-notify --ready" "$FAKE_LOG" && break; sleep 0.1; done
kill -TERM "$opid"
wait "$opid" || true
opid=""
check "run/stop: SIGTERM ends the run as aborted" test "$(last_audit .result)" = aborted
check "run/stop: and still discards" hasx "ip link del cp0" "$FAKE_LOG"

# ── audit chain ────────────────────────────────────────────────────────────
check "audit: the chain over every run above is intact" orch audit-verify
lines=$(wc -l < "$CVM_STATEDIR/audit.log")
# 12 runs above: full, stale cleanup, timeout, vmm-exit, link-change, gpu
# fallback, smt, smt refusal, tailnet refusal, odd uplink, bad reference, SIGTERM.
check "audit: exactly one line per run" test "$lines" -eq 12
first_hash=$(head -n 1 "$CVM_STATEDIR/audit.log" | tr -d '\n' | sha256sum | cut -c1-64)
check "audit: each line names its predecessor" test "$(sed -n 2p "$CVM_STATEDIR/audit.log" | jq -r .prev)" = "$first_hash"
sed -i '3s/"result":"[a-z-]*"/"result":"full"/' "$CVM_STATEDIR/audit.log"
tamper() { ! orch audit-verify; }
check "audit: rewriting a past result breaks the chain" tamper

expected=109
echo
echo "captive-vm-run tests: $ran checks run, expected $expected"
if [ "$ran" -ne "$expected" ]; then
  echo "captive-vm-run tests: check count drifted — update 'expected'" >&2
  exit 1
fi
[ "$fail" -eq 0 ] || { echo "captive-vm-run tests: FAILED" >&2; exit 1; }
echo "captive-vm-run tests: OK"
