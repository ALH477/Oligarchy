#!/usr/bin/env bash
# captive-vm-run — one portal login in a disposable, verified microVM.
#
#   captive-vm-run [run]        the whole lifecycle (captive-vm.service ExecStart)
#   captive-vm-run verify       check the reference and every hash, then stop
#   captive-vm-run plan         verify, decide the display mode, print the QEMU argv
#   captive-vm-run audit-verify check the audit log's hash chain
#
# Runs as root because it creates the tap, loads the egress table and flips
# forwarding. It never runs guest-influenced code: QEMU runs as captive-vm in
# a sandboxed transient unit, the display viewer as captive-view on its own VT,
# and the only things read back from the guest side are "is the VMM still
# running" and NetworkManager's own connectivity probe.
#
# Pipeline, in order, each step refusing on failure:
#   1. reference   sha256(manifest.json) == the value baked in at build time
#   2. signature   ssh-keygen -Y verify, when a public key is configured
#   3. hashes      kernel and initrd are COPIED into the run dir and the copies
#                  are hashed, so what was checked is what QEMU boots; the hash
#                  tree and egress policy are hashed too; the store disk is
#                  checked block by block by dm-verity inside the guest
#   4. mode        GPU passthrough when a configured GPU is fully bound to
#                  vfio-pci, else a CPU framebuffer shown on its own VT
#   5. network     tap + NAT + egress table + DNS forwarder, torn down on exit
#   6. VMM         QEMU under coresched when SMT is active
#   7. wait        until NetworkManager reports full, the VMM exits, the link
#                  changes or the timeout passes
#   8. discard     every step above undone on EVERY exit path; one audit line
#
# Environment (exported by the Nix wrapper; the no-KVM gate sets fakes):
#   CVM_MANIFEST, CVM_REFERENCE   manifest path and its expected sha256
#   CVM_PUBKEY, CVM_SIG           "ssh-ed25519 AAAA…" or empty; signature file
#   CVM_QEMU, CVM_CORESCHED, CVM_DNSMASQ
#   CVM_USER, CVM_GROUP           captive-vm, captive-vm (the VM user's own
#                                 group; a separate seam because the no-KVM
#                                 gate runs as a user whose name is NOT also
#                                 a group name, which `-g $CVM_USER` refused)
#   CVM_VIEW_GROUP                captive-view
#   CVM_RUNDIR, CVM_STATEDIR, CVM_STATUS
#   CVM_TAP, CVM_GUEST_MAC        cp0, 02:ca:97:00:00:02
#   CVM_FB_WIDTH, CVM_FB_HEIGHT
#   CVM_GPU_FUNCTIONS             "0000:03:00.0 0000:03:00.1" or empty
#   CVM_GPU_ROM, CVM_GPU_INPUTS ("auto" or evdev paths), CVM_GPU_GRAB_TOGGLE
#   CVM_CPU                       AllowedCPUs for the VMM, or empty
#   CVM_VIEWER_UNIT, CVM_VT
#   CVM_DEBUG                     1: guest serial console to the run dir
#   CVM_SYSFS, CVM_DEVDIR, CVM_PROCSYS   test seams; /sys, /dev, /proc/sys
set -euo pipefail
export LC_ALL=C

: "${CVM_MANIFEST:?}" "${CVM_REFERENCE:?}" "${CVM_QEMU:?}"
: "${CVM_PUBKEY:=}" "${CVM_SIG:=/var/lib/captive-portal/manifest.sig}"
: "${CVM_CORESCHED:=}" "${CVM_DNSMASQ:=dnsmasq}"
: "${CVM_USER:=captive-vm}" "${CVM_VIEW_GROUP:=captive-view}"
: "${CVM_GROUP:=$CVM_USER}"
: "${CVM_RUNDIR:=/run/captive-vm}" "${CVM_STATEDIR:=/var/lib/captive-portal}"
: "${CVM_STATUS:=/run/captive-portal/vm-status}"
: "${CVM_TAP:=cp0}" "${CVM_GUEST_MAC:=02:ca:97:00:00:02}"
: "${CVM_FB_WIDTH:=1600}" "${CVM_FB_HEIGHT:=1000}"
: "${CVM_GPU_FUNCTIONS:=}" "${CVM_GPU_ROM:=}" "${CVM_GPU_INPUTS:=auto}"
: "${CVM_GPU_GRAB_TOGGLE:=ctrl-ctrl}" "${CVM_CPU:=}"
: "${CVM_VIEWER_UNIT:=captive-vm-viewer.service}" "${CVM_VT:=7}"
: "${CVM_DEBUG:=0}"
: "${CVM_SYSFS:=/sys}" "${CVM_DEVDIR:=/dev}" "${CVM_PROCSYS:=/proc/sys}"

HOST_IP=10.207.0.1
QEMU_UNIT=captive-vm-qemu.service
NS=oligarchy-captive-vm
AUDIT="$CVM_STATEDIR/audit.log"

# ── state the discard step needs, whatever point the run reached ───────────
run_id="" start_ts="" reference="" signature="none"
mode="" mode_reason="" fallback="none" result="refused" reason=""
uplink="" connection="" fwd_uplink_old="" tap_made=0 table_made=0
dns_pid="" viewer_started=0 orig_vt="" vfio_group="" vfio_owner=""
root_hash="" cmdline="" mem=1536 timeout=600 interval=20 grace=45
store_disk="" hash_tree="" policy_file=""
kbd_devs=() ptr_devs=()
discarded=0

log() { printf 'captive-vm-run: %s\n' "$*" >&2; }

status() { # status <state> — tiny JSON for captive-portal-open's fallback message
  mkdir -p "$(dirname "$CVM_STATUS")"
  jq -cn --arg state "$1" --arg reason "$reason" --arg mode "$mode" \
    --arg run "$run_id" --arg ts "$(date -u +%FT%TZ)" \
    '{state: $state, reason: $reason, mode: $mode, run: $run, time: $ts}' > "$CVM_STATUS.tmp"
  chmod 0644 "$CVM_STATUS.tmp"
  mv -f "$CVM_STATUS.tmp" "$CVM_STATUS"
}

refuse() { # refuse <reason> — before the VM is up; start fails, caller falls back
  reason=$1
  result=refused
  log "refused: $reason"
  exit 1
}

sha() { sha256sum "$1" | cut -c1-64; }
is_hex64() { [[ $1 =~ ^[0-9a-f]{64}$ ]]; }
is_uint() { [[ $1 =~ ^[0-9]+$ ]]; }
mf() { jq -er "$1" "$CVM_MANIFEST"; }

# ── 1–3: reference, signature, hashes ──────────────────────────────────────
verify() {
  [ -f "$CVM_MANIFEST" ] || refuse "manifest $CVM_MANIFEST is missing"
  is_hex64 "$CVM_REFERENCE" || refuse "launcher reference is not a sha256"
  reference=$(sha "$CVM_MANIFEST")
  [ "$reference" = "$CVM_REFERENCE" ] ||
    refuse "manifest sha256 $reference does not match the reference this launcher was built with"
  [ "$(mf .schema)" = "oligarchy-captive-vm/1" ] || refuse "unknown manifest schema"

  if [ -n "$CVM_PUBKEY" ]; then
    # Only a bare ed25519 key: anything else could smuggle options into the
    # allowed_signers line.
    [[ $CVM_PUBKEY =~ ^ssh-ed25519\ [A-Za-z0-9+/]+=*$ ]] || refuse "configured public key is not a bare ssh-ed25519 key"
    [ -s "$CVM_SIG" ] || refuse "a signature is required and $CVM_SIG is missing"
    local allowed
    allowed=$(mktemp)
    printf 'captive-vm namespaces="%s" %s\n' "$NS" "$CVM_PUBKEY" > "$allowed"
    if ! ssh-keygen -Y verify -f "$allowed" -I captive-vm -n "$NS" -s "$CVM_SIG" \
      < "$CVM_MANIFEST" > /dev/null 2>&1; then
      rm -f "$allowed"
      refuse "manifest signature does not verify against the configured key"
    fi
    rm -f "$allowed"
    signature=ok
  fi

  root_hash=$(mf .store.verity.root)
  is_hex64 "$root_hash" || refuse "verity root in the manifest is not a sha256"
  cmdline=$(mf .cmdline)
  case "$cmdline" in
    *captive.verity=*) refuse "manifest cmdline already carries captive.verity=" ;;
  esac
  [[ $cmdline == *$'\n'* ]] && refuse "manifest cmdline contains a newline"

  store_disk=$(mf .store.path)
  hash_tree=$(mf .store.verity.hashTree)
  policy_file=$(mf .policy.nft)
  [ -f "$store_disk" ] || refuse "store disk $store_disk is missing"
  [ "$(sha "$hash_tree")" = "$(mf .store.verity.hashTreeSha256)" ] || refuse "verity hash tree does not match the manifest"
  [ "$(sha "$policy_file")" = "$(mf .policy.nftSha256)" ] || refuse "egress policy does not match the manifest"

  mem=$(mf .policy.limits.memMiB)
  timeout=$(mf .policy.limits.timeoutSec)
  interval=$(mf .policy.limits.probeIntervalSec)
  grace=$(mf .policy.limits.gpuGraceSec)
  for v in "$mem" "$timeout" "$interval" "$grace"; do
    is_uint "$v" || refuse "manifest limits are not integers"
  done

  [ -c "$CVM_DEVDIR/kvm" ] || refuse "no $CVM_DEVDIR/kvm on this host"
}

# Copy, then hash the copy: QEMU boots exactly the bytes that were checked.
stage_boot() {
  install -d -m 0755 "$CVM_RUNDIR/boot"
  local c
  for c in kernel initrd; do
    install -m 0644 "$(mf ".$c.path")" "$CVM_RUNDIR/boot/$c"
    [ "$(sha "$CVM_RUNDIR/boot/$c")" = "$(mf ".$c.sha256")" ] ||
      refuse "$c does not match the manifest"
  done
}

# ── 4: display mode ────────────────────────────────────────────────────────
driver_of() { # driver_of <sysfs device dir> -> driver name or "none"
  if [ -L "$1/driver" ]; then basename "$(readlink "$1/driver")"; else echo none; fi
}

gpu_ready() {
  mode_reason=""
  if [ -z "$CVM_GPU_FUNCTIONS" ]; then mode_reason="no GPU configured"; return 1; fi
  local groups="$CVM_SYSFS/kernel/iommu_groups"
  if [ ! -d "$groups" ] || [ -z "$(ls -A "$groups" 2>/dev/null)" ]; then
    mode_reason="IOMMU is off"; return 1
  fi
  local f dev grp d drv first_group=""
  for f in $CVM_GPU_FUNCTIONS; do
    dev="$CVM_SYSFS/bus/pci/devices/$f"
    [ -e "$dev" ] || { mode_reason="$f is not present"; return 1; }
    drv=$(driver_of "$dev")
    [ "$drv" = vfio-pci ] || { mode_reason="$f is bound to $drv, not vfio-pci"; return 1; }
    grp=$(basename "$(readlink "$dev/iommu_group")")
    [ -z "$first_group" ] && first_group=$grp
    [ "$grp" = "$first_group" ] || { mode_reason="GPU functions span IOMMU groups"; return 1; }
    # Every endpoint sharing the group must be the guest's too, or VFIO
    # would hand the guest DMA reach over a device the host still uses.
    for d in "$groups/$grp/devices/"*; do
      drv=$(driver_of "$d")
      case "$drv" in
        vfio-pci | pcieport | none) ;;
        *) mode_reason="IOMMU group $grp also holds $(basename "$d") bound to $drv"; return 1 ;;
      esac
    done
  done
  [ -e "$CVM_DEVDIR/vfio/$first_group" ] || { mode_reason="$CVM_DEVDIR/vfio/$first_group is missing"; return 1; }
  vfio_group=$first_group

  kbd_devs=() ptr_devs=()
  if [ "$CVM_GPU_INPUTS" = auto ]; then
    local p
    for p in "$CVM_DEVDIR"/input/by-path/*-event-kbd; do [ -e "$p" ] && kbd_devs+=("$(readlink -f "$p")"); done
    for p in "$CVM_DEVDIR"/input/by-path/*-event-mouse; do [ -e "$p" ] && ptr_devs+=("$(readlink -f "$p")"); done
  else
    local p
    for p in $CVM_GPU_INPUTS; do
      case "$p" in *-kbd) kbd_devs+=("$(readlink -f "$p")") ;; *) ptr_devs+=("$(readlink -f "$p")") ;; esac
    done
  fi
  [ "${#kbd_devs[@]}" -gt 0 ] || { mode_reason="no keyboard to hand the GPU guest"; return 1; }
  return 0
}

decide_mode() {
  if gpu_ready; then
    mode=gpu
    mode_reason="GPU $CVM_GPU_FUNCTIONS in IOMMU group $vfio_group"
  else
    mode=framebuffer
  fi
}

# ── 5: network ─────────────────────────────────────────────────────────────
default_dev() {
  ip -4 -j route show default 2>/dev/null |
    jq -r 'sort_by(.metric // 0) | .[0].dev // empty'
}

net_up() {
  uplink=$(default_dev)
  [ -n "$uplink" ] || refuse "no IPv4 default route"
  # It goes into an nft ruleset through sed: interface-name characters only.
  [[ $uplink =~ ^[A-Za-z0-9_.:-]{1,15}$ ]] || refuse "uplink name '$uplink' is not a plain interface name"
  case "$uplink" in
    tailscale* | "$CVM_TAP") refuse "the default route is via $uplink; a portal cannot be reached through it" ;;
  esac
  connection=$(nmcli -t -g GENERAL.CONNECTION device show "$uplink" 2>/dev/null || true)

  ip tuntap add dev "$CVM_TAP" mode tap user "$CVM_USER" group "$CVM_GROUP"
  tap_made=1
  ip addr add "$HOST_IP/30" dev "$CVM_TAP"
  ip link set "$CVM_TAP" up

  fwd_uplink_old=$(cat "$CVM_PROCSYS/net/ipv4/conf/$uplink/forwarding")
  echo 1 > "$CVM_PROCSYS/net/ipv4/conf/$CVM_TAP/forwarding"
  echo 1 > "$CVM_PROCSYS/net/ipv4/conf/$uplink/forwarding"

  sed "s/@UPLINK@/$uplink/g" "$policy_file" | nft -f -
  table_made=1

  # Answers from resolved's stub, so the guest sees exactly what this host
  # sees on the uplink — the portal's hijacked names included — and nothing
  # about the host's other links.
  "$CVM_DNSMASQ" --keep-in-foreground --conf-file=/dev/null \
    --interface="$CVM_TAP" --bind-interfaces --listen-address="$HOST_IP" \
    --no-resolv --no-hosts --no-poll --server=127.0.0.53 --cache-size=0 \
    --no-dhcp-interface="$CVM_TAP" --user=nobody --group=nogroup --log-facility=- &
  dns_pid=$!
}

# ── 6: the VMM ─────────────────────────────────────────────────────────────
qemu_argv() { # fills the global array QARGS for $mode
  local console=""
  QARGS=(
    -name "captive-vm,process=captive-vm"
    -M "q35,accel=kvm,mem-merge=off"
    -cpu host
    -smp 1 -m "$mem"
    -nodefaults -no-user-config -no-reboot
    -sandbox "on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny"
    -display none
    -monitor none -parallel none
    -kernel "$CVM_RUNDIR/boot/kernel" -initrd "$CVM_RUNDIR/boot/initrd"
    -drive "id=store,format=raw,read-only=on,file=$store_disk,if=none"
    -device "virtio-blk-pci,drive=store,serial=nixstore"
    -drive "id=verity,format=raw,read-only=on,file=$hash_tree,if=none"
    -device "virtio-blk-pci,drive=verity,serial=nixverity"
    -netdev "tap,id=net0,ifname=$CVM_TAP,script=no,downscript=no,vhost=off"
    -device "virtio-net-pci,netdev=net0,mac=$CVM_GUEST_MAC,romfile="
    -device virtio-rng-pci
  )
  if [ "$CVM_DEBUG" = 1 ]; then
    QARGS+=(-serial "file:$CVM_RUNDIR/ctl/serial.log")
    # The manifest cmdline says `quiet`; a debugging run wants systemd's unit
    # status on the serial console regardless (the VM gate greps it).
    console=" console=ttyS0 systemd.show_status=1"
  else
    QARGS+=(-serial none)
  fi
  QARGS+=(-append "$cmdline captive.verity=$root_hash$console")

  if [ "$mode" = framebuffer ]; then
    QARGS+=(
      -vnc "unix:$CVM_RUNDIR/vnc/vnc.sock"
      -device "virtio-gpu-pci,xres=$CVM_FB_WIDTH,yres=$CVM_FB_HEIGHT"
      -device virtio-keyboard-pci -device virtio-tablet-pci
    )
  else
    QARGS+=(-device "pcie-root-port,id=rp0,chassis=1,slot=0")
    local i=0 f opts
    for f in $CVM_GPU_FUNCTIONS; do
      opts="vfio-pci,host=$f,bus=rp0,addr=0.$i"
      if [ "$i" -eq 0 ]; then
        opts="$opts,multifunction=on"
        [ -n "$CVM_GPU_ROM" ] && opts="$opts,romfile=$CVM_GPU_ROM"
      fi
      QARGS+=(-device "$opts")
      i=$((i + 1))
    done
    # Exclusive grab: while the guest runs, the host session gets no key
    # presses at all. The toggle hands them back.
    i=0
    for f in "${kbd_devs[@]}"; do
      QARGS+=(-object "input-linux,id=kbd$i,evdev=$f,grab_all=on,repeat=on,grab-toggle=$CVM_GPU_GRAB_TOGGLE")
      i=$((i + 1))
    done
    i=0
    for f in "${ptr_devs[@]}"; do
      QARGS+=(-object "input-linux,id=ptr$i,evdev=$f")
      i=$((i + 1))
    done
  fi
}

unit_props() { # fills UPROPS for $mode
  UPROPS=(
    -p "User=$CVM_USER" -p "Group=$CVM_GROUP" -p UMask=0007
    -p NoNewPrivileges=yes -p CapabilityBoundingSet= -p AmbientCapabilities=
    -p ProtectSystem=strict -p ProtectHome=yes -p PrivateTmp=yes -p PrivateIPC=yes
    -p ProtectKernelTunables=yes -p ProtectKernelModules=yes -p ProtectKernelLogs=yes
    -p ProtectControlGroups=yes -p ProtectClock=yes -p ProtectHostname=yes -p ProtectProc=invisible
    -p RestrictNamespaces=yes -p LockPersonality=yes -p RestrictRealtime=yes -p RestrictSUIDSGID=yes
    -p MemoryDenyWriteExecute=yes -p SystemCallArchitectures=native
    -p RestrictAddressFamilies=AF_UNIX
    -p DevicePolicy=closed -p "DeviceAllow=/dev/kvm rw" -p "DeviceAllow=/dev/net/tun rw"
    -p "ReadWritePaths=$CVM_RUNDIR/vnc $CVM_RUNDIR/ctl"
    -p "MemoryMax=$((mem + 768))M" -p TasksMax=128
  )
  [ -n "$CVM_CPU" ] && UPROPS+=(-p "AllowedCPUs=$CVM_CPU")
  if [ "$mode" = gpu ]; then
    UPROPS+=(-p "DeviceAllow=/dev/vfio/vfio rw" -p "DeviceAllow=/dev/vfio/$vfio_group rw"
      -p LimitMEMLOCK=infinity -p SupplementaryGroups=input)
    local d
    for d in "${kbd_devs[@]}" "${ptr_devs[@]}"; do UPROPS+=(-p "DeviceAllow=$d r"); done
  fi
}

smt_active() { [ "$(cat "$CVM_SYSFS/devices/system/cpu/smt/active" 2>/dev/null || echo 0)" = 1 ]; }

vmm_up() {
  install -d -m 2750 -o "$CVM_USER" -g "$CVM_VIEW_GROUP" "$CVM_RUNDIR/vnc"
  install -d -m 0700 -o "$CVM_USER" -g "$CVM_GROUP" "$CVM_RUNDIR/ctl"
  if [ "$mode" = gpu ]; then
    vfio_owner=$(stat -c %u "$CVM_DEVDIR/vfio/$vfio_group")
    chown "$CVM_USER" "$CVM_DEVDIR/vfio/$vfio_group"
  fi
  qemu_argv
  unit_props
  local prefix=()
  # Core scheduling: no host thread shares a physical core with the guest's
  # vCPU while it runs. Without SMT there is no sibling to share.
  if smt_active; then
    if [ -n "$CVM_CORESCHED" ] && "$CVM_CORESCHED" new -- true 2> /dev/null; then
      prefix=("$CVM_CORESCHED" new --)
    else
      refuse "SMT is active and core scheduling is unavailable (kernel CONFIG_SCHED_CORE or coresched)"
    fi
  fi
  systemd-run --unit="$QEMU_UNIT" --collect --quiet --service-type=exec \
    "${UPROPS[@]}" -- "${prefix[@]}" "$CVM_QEMU" "${QARGS[@]}"
  vmm_started=$(date +%s)
}

vmm_active() { systemctl is-active --quiet "$QEMU_UNIT"; }

vmm_down() {
  systemctl stop "$QEMU_UNIT" 2> /dev/null || true
  systemctl kill -s KILL "$QEMU_UNIT" 2> /dev/null || true
  systemctl reset-failed "$QEMU_UNIT" 2> /dev/null || true
}

viewer_up() {
  local _
  for _ in $(seq 1 100); do
    [ -S "$CVM_RUNDIR/vnc/vnc.sock" ] && break
    sleep 0.1
  done
  [ -S "$CVM_RUNDIR/vnc/vnc.sock" ] || refuse "QEMU did not open its display socket"
  # Switch first: the viewer's logind session is then born active on its VT,
  # so cage gets the seat's DRM and input devices at once. From here until
  # discard, the desktop session is on an inactive VT and gets no input.
  orig_vt=$(fgconsole 2> /dev/null || true)
  chvt "$CVM_VT" || true
  systemctl start "$CVM_VIEWER_UNIT"
  viewer_started=1
}

# A previous run that was SIGKILLed never reached discard: clear what it may
# have left, or the tap and table below would fail to create.
preclean() {
  vmm_down
  if ip link show "$CVM_TAP" > /dev/null 2>&1; then
    log "removing a stale $CVM_TAP from an earlier run"
    ip link del "$CVM_TAP"
  fi
  if nft list table inet captive_vm > /dev/null 2>&1; then
    log "removing a stale captive_vm table from an earlier run"
    nft delete table inet captive_vm
  fi
}

# ── 8: discard — runs on every exit ────────────────────────────────────────
audit_append() {
  install -d -m 0700 "$CVM_STATEDIR"
  local prev=genesis line
  [ -s "$AUDIT" ] && prev=$(tail -n 1 "$AUDIT" | tr -d '\n' | sha256sum | cut -c1-64)
  line=$(jq -cn --sort-keys \
    --arg run "$run_id" --arg start "$start_ts" --arg end "$(date -u +%FT%TZ)" \
    --arg reference "$reference" --arg signature "$signature" \
    --arg mode "$mode" --arg fallback "$fallback" --arg result "$result" \
    --arg reason "$reason" --arg uplink "$uplink" --arg connection "$connection" \
    --arg prev "$prev" \
    '{v: 1, run: $run, start: $start, end: $end, reference: $reference,
      signature: $signature, mode: $mode, fallback: $fallback, result: $result,
      reason: $reason, uplink: $uplink, connection: $connection, prev: $prev}')
  printf '%s\n' "$line" >> "$AUDIT"
  chmod 0600 "$AUDIT"
}

discard() {
  [ "$discarded" = 1 ] && return 0
  discarded=1
  set +e
  [ "$viewer_started" = 1 ] && systemctl stop "$CVM_VIEWER_UNIT" 2> /dev/null
  [ -n "$orig_vt" ] && chvt "$orig_vt"
  vmm_down
  [ -n "$dns_pid" ] && kill "$dns_pid" 2> /dev/null && wait "$dns_pid" 2> /dev/null
  [ "$table_made" = 1 ] && nft delete table inet captive_vm
  [ "$tap_made" = 1 ] && ip link del "$CVM_TAP"
  [ -n "$fwd_uplink_old" ] && echo "$fwd_uplink_old" > "$CVM_PROCSYS/net/ipv4/conf/$uplink/forwarding"
  [ -n "$vfio_owner" ] && chown "$vfio_owner" "$CVM_DEVDIR/vfio/$vfio_group"
  rm -rf "${CVM_RUNDIR:?}/boot" "${CVM_RUNDIR:?}/vnc"
  [ "$CVM_DEBUG" = 1 ] || rm -rf "${CVM_RUNDIR:?}/ctl"
  [ -n "$start_ts" ] && audit_append
  status "$result"
  log "discarded: result=$result mode=${mode:-none} fallback=$fallback${reason:+ reason=$reason}"
}

# ── 7: the run ─────────────────────────────────────────────────────────────
sleep_i() { sleep "$1" & wait $!; } # interruptible by the TERM trap

cmd_run() {
  run_id=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
  start_ts=$(date -u +%FT%TZ)
  install -d -m 0755 "$CVM_RUNDIR"
  trap discard EXIT
  trap 'result=aborted; reason="stopped"; exit 0' TERM INT

  verify
  stage_boot
  decide_mode
  preclean
  net_up
  vmm_up
  [ "$mode" = framebuffer ] && viewer_up
  result=running
  status running
  systemd-notify --ready --status="portal VM up ($mode)" 2> /dev/null || true
  log "up: run=$run_id mode=$mode (${mode_reason:-framebuffer}) uplink=$uplink reference=$reference signature=$signature"

  local now state
  while :; do
    sleep_i "$interval"
    now=$(date +%s)
    if ! vmm_active; then
      if [ "$mode" = gpu ] && [ "$fallback" = none ] && [ $((now - vmm_started)) -lt "$grace" ]; then
        # The guest powers itself off when it finds no display: a GPU with
        # nothing plugged into it. Once, retry on the framebuffer.
        fallback=gpu-no-display
        log "GPU guest exited after $((now - vmm_started))s; falling back to the framebuffer"
        vmm_down
        if [ -n "$vfio_owner" ]; then chown "$vfio_owner" "$CVM_DEVDIR/vfio/$vfio_group"; vfio_owner=""; fi
        mode=framebuffer
        vmm_up
        viewer_up
        continue
      fi
      result=vmm-exit
      reason="guest powered off (browser closed or no display)"
      break
    fi
    state=$(nmcli networking connectivity check 2> /dev/null || echo unknown)
    if [ "$state" = full ]; then
      result=full
      reason=""
      break
    fi
    if [ "$(default_dev)" != "$uplink" ]; then
      result=link-change
      reason="default route moved off $uplink"
      break
    fi
    if [ $((now - vmm_started)) -ge "$timeout" ]; then
      result=timeout
      reason="no login within ${timeout}s"
      break
    fi
  done
  exit 0
}

cmd_audit_verify() {
  [ -s "$AUDIT" ] || { echo "audit log $AUDIT is empty"; return 0; }
  local prev=genesis n=0 line got
  while IFS= read -r line; do
    n=$((n + 1))
    got=$(jq -r .prev <<< "$line")
    if [ "$got" != "$prev" ]; then
      echo "audit chain broken at line $n" >&2
      return 1
    fi
    prev=$(printf '%s' "$line" | sha256sum | cut -c1-64)
  done < "$AUDIT"
  echo "audit chain intact: $n line(s)"
}

case "${1:-run}" in
  run) cmd_run ;;
  verify)
    verify
    stage_boot
    rm -rf "${CVM_RUNDIR:?}/boot"
    echo "verified: reference=$reference signature=$signature root=$root_hash"
    ;;
  plan)
    verify
    decide_mode
    qemu_argv
    unit_props
    echo "mode=$mode reason=${mode_reason:-}"
    printf '%s\n' "${UPROPS[@]}" | sed 's/^/prop: /'
    printf '%s\n' "${QARGS[@]}" | sed 's/^/arg: /'
    ;;
  audit-verify) cmd_audit_verify ;;
  *)
    echo "usage: captive-vm-run [run|verify|plan|audit-verify]" >&2
    exit 64
    ;;
esac
