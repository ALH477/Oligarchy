# dsp-netjack-tests — the DSP VM's audio path, run in the build sandbox with
# the commands the modules generate. No KVM, no guest: the guest's units run
# here as processes, each JACK server under its own name.
#
#   guest   the guest's own dsp-jackd start script (no ALSA card here, so it
#           must pick the dummy driver), its jack-netmanager, its jack-router
#           with the guest's rules, and an engine stand-in named demod-rt
#           that copies in to out (ArchibaldOS tests/netjack2's jackprobe)
#   box1    a companion: jackd on the dummy driver, ArchibaldOS's
#           jack-netadapter and jack-router commands for a box
#   host    this host: a PipeWire daemon standing in for the user's, and the
#           dsp-netjack user unit's own command (PipeWire's netjack2 driver)
#
# What it proves, each against the module's own command line:
#   1. the guest's JACK starts on the dummy driver when it has no card;
#   2. a box and this host both join the guest's manager, under their names;
#   3. no guest router, no path (anti-vacuity: the router makes the path);
#   4. box -> guest engine -> box over NetJack2: a tone comes back (~0.5);
#   5. a PipeWire app on this host -> guest engine -> the same app: a tone
#      played into dsp-vm.sink comes back on dsp-vm.source (~0.5).
#
# Addresses are loopback here (the evaluations in flake.nix set them); the
# routed tap, the forward table and WireGuard are .#dsp-route-contract's.
#
# Emulated, and said so: WirePlumber. The netjack2 driver creates its ports
# when a session manager sets PortConfig on its nodes; this sets it with
# pw-cli, the one step WirePlumber does on the real host. pw-cat's streams
# configure their own ports (adapter.auto-port-config) and are linked with
# pw-link for the same reason.
#
# Unmeasured: real-time scheduling, the passed-through interface, a real
# network, the real demod-rt (the stand-in only copies), latency. Also
# whether an idle follower costs the guest cycles: "netmanager was not
# finished" ran 1-8 per 10 s here in every configuration tried (host
# joined or not, ports configured or not, node.always-process or not),
# which is this sandbox's noise floor, so no check could tell them apart.
{ pkgs, guest, box, host, probe }:

let
  lib = pkgs.lib;
  svc = cfg: name: cfg.config.systemd.services.${name}.serviceConfig;
  usvc = cfg: name: cfg.config.systemd.user.services.${name}.serviceConfig;
  hostCmd = (usvc host "dsp-netjack").ExecStart;

  # The user's PipeWire daemon, as far as this needs one: the native
  # protocol, client nodes, links, and a dummy driver to run the graph.
  daemonConf = pkgs.writeText "pipewire-daemon.conf" ''
    context.properties = { support.dbus = false core.daemon = true core.name = pipewire-0 default.clock.rate = 48000 }
    context.spa-libs = { audio.convert.* = audioconvert/libspa-audioconvert audio.adapt = audioconvert/libspa-audioconvert support.* = support/libspa-support }
    context.modules = [
      { name = libpipewire-module-protocol-native }
      { name = libpipewire-module-profiler }
      { name = libpipewire-module-metadata }
      { name = libpipewire-module-spa-node-factory }
      { name = libpipewire-module-client-node }
      { name = libpipewire-module-access args = { } }
      { name = libpipewire-module-adapter }
      { name = libpipewire-module-link-factory }
    ]
    context.objects = [
      { factory = metadata args = { metadata.name = default } }
      { factory = spa-node-factory args = { factory.name = support.node.driver node.name = Dummy-Driver node.group = pipewire.dummy priority.driver = 20000 } }
    ]
  '';

  clientName = host.config.custom.vm.dsp.archibaldOS.netjack.clientName;
in
pkgs.runCommand "dsp-netjack-tests"
{
  nativeBuildInputs = [ pkgs.jack2 pkgs.jack-example-tools pkgs.pipewire probe pkgs.python3 pkgs.gawk pkgs.gnugrep pkgs.coreutils ];
}
  ''
    export HOME=$TMPDIR XDG_RUNTIME_DIR=$TMPDIR/run JACK_NO_AUDIO_RESERVATION=1
    mkdir -p $XDG_RUNTIME_DIR
    fail=0
    pass() { echo "PASS: $*"; }
    bad() { echo "FAIL: $*"; fail=1; }
    peak_ok() { awk -v p="$1" 'BEGIN { exit !(p > 0.4 && p < 0.6) }'; }
    silent() { awk -v p="$1" 'BEGIN { exit !(p < 0.01) }'; }
    box() { JACK_DEFAULT_SERVER=box1 "$@"; }
    roundtrip() { # peak on box1's netadapter:capture_1 while a tone plays into playback_1
      jackprobe box1 tone netadapter:playback_1 4 & local t=$!
      sleep 1; local p; p=$(jackprobe box1 meter netadapter:capture_1 2); wait $t; echo "$p"
    }
    pw_props='node.autoconnect = false adapter.auto-port-config = { mode = dsp monitor = false control = false position = preserve }'
    host_roundtrip() { # TAG: play a tone into dsp-vm.sink, record dsp-vm.source, print the peak
      timeout 20 pw-cat --playback -P "{ node.name = tone-$1 $pw_props }" tone.wav > play-$1.log 2>&1 &
      timeout 10 pw-cat --record -P "{ node.name = rec-$1 $pw_props }" --rate 48000 --channels 2 --format f32 rec-$1.wav > rec-$1.log 2>&1 & local rec=$!
      local i; for i in $(seq 1 40); do pw-link -o | grep -q "tone-$1" && pw-link -i | grep -q "rec-$1" && break; sleep 0.25; done
      pw-link tone-$1:output_FL dsp-vm.sink:playback_1 && pw-link tone-$1:output_FR dsp-vm.sink:playback_2
      pw-link dsp-vm.source:capture_1 rec-$1:input_FL && pw-link dsp-vm.source:capture_2 rec-$1:input_FR
      wait $rec || true
      python3 -c '
    import struct, sys
    d = open(sys.argv[1], "rb").read(); i = d.find(b"data"); raw = d[i + 8:]
    f = struct.unpack("<%df" % (len(raw) // 4), raw[:len(raw) // 4 * 4])
    print("%.4f" % max((abs(x) for x in f), default=0.0))' rec-$1.wav
    }
    python3 - <<'EOF'
    import math, struct, wave
    w = wave.open("tone.wav", "wb"); w.setnchannels(2); w.setsampwidth(2); w.setframerate(48000)
    w.writeframes(b"".join(struct.pack("<hh", s, s) for s in
      (int(16384 * math.sin(2 * math.pi * 1000 * i / 48000)) for i in range(48000 * 6))))
    w.close()
    EOF

    # ── the guest ─────────────────────────────────────────────────────────
    echo "guest jackd:  ${(svc guest "dsp-jackd").ExecStart}"
    ${(svc guest "dsp-jackd").ExecStart} > guest-jackd.log 2>&1 & GJ=$!
    jack_wait -w -t 20 > /dev/null
    if head -n 1 guest-jackd.log | grep -q 'dummy driver'; then pass "no ALSA card: the guest's JACK picked the dummy driver"
    else bad "the guest's JACK did not report the dummy driver"; cat guest-jackd.log; fi

    echo "manager:      ${(svc guest "jack-netmanager").ExecStart}"
    ${(svc guest "jack-netmanager").ExecStartPre}
    ${(svc guest "jack-netmanager").ExecStart}
    jackprobe default engine demod-rt 900 & ENG=$!

    # ── a box ─────────────────────────────────────────────────────────────
    jackd -r -n box1 -d dummy -r 48000 -p 256 > box1.log 2>&1 & B1=$!
    box jack_wait -w -t 20 > /dev/null
    echo "box adapter:  ${(svc box "jack-netadapter").ExecStart}"
    box ${(svc box "jack-netadapter").ExecStart}
    box ${(svc box "jack-router").ExecStart} 2> box1-router.log & BR=$!

    # ── this host ─────────────────────────────────────────────────────────
    pipewire -c ${daemonConf} > pw.log 2>&1 & PW=$!
    sleep 1
    echo "host:         ${hostCmd}"
    ${hostCmd} > host-nj.log 2>&1 & HN=$!
    for i in $(seq 1 40); do pw-dump 2>/dev/null | grep -q '"dsp-vm.source"' && break; sleep 0.5; done
    # WirePlumber's step: configure the nodes' ports.
    pw-cli set-param dsp-vm.sink PortConfig '{ direction: Input, mode: dsp }' > /dev/null
    pw-cli set-param dsp-vm.source PortConfig '{ direction: Output, mode: dsp }' > /dev/null
    sleep 4

    jack_lsp > guest-ports.txt
    if grep -qx 'box1:from_slave_1' guest-ports.txt; then pass "box1 joined the guest's manager as box1"
    else bad "box1 never appeared on the guest"; cat guest-ports.txt; fi
    if grep -qx '${clientName}:from_slave_1' guest-ports.txt; then pass "this host joined the guest's manager as ${clientName}"
    else bad "this host never appeared on the guest as ${clientName}"; cat guest-ports.txt host-nj.log; fi

    # ── 3, 4: a box, before and after the guest's router ─────────────────
    p0=$(roundtrip)
    if silent "$p0"; then pass "no guest router, no path: box1 hears $p0"
    else bad "audio came back before the guest's router existed ($p0): the round trips would be vacuous"; fi
    p2=$(host_roundtrip before)
    if silent "$p2"; then pass "no guest router, no path: this host hears $p2"
    else bad "this host heard itself before the guest's router existed ($p2): check 5 would be vacuous"; fi

    echo "router:       ${(svc guest "jack-router").ExecStart}"
    ${(svc guest "jack-router").ExecStart} 2> guest-router.log & GR=$!
    sleep 3
    p1=$(roundtrip)
    if peak_ok "$p1"; then pass "box1 -> guest engine -> box1 with the guest's rules: peak $p1"
    else bad "box1 round trip: peak $p1"; cat guest-router.log; fi

    # ── 5: a PipeWire app on this host, through the guest's engine ──────
    p3=$(host_roundtrip after)
    if peak_ok "$p3"; then pass "a PipeWire app -> dsp-vm.sink -> guest engine -> dsp-vm.source: peak $p3"
    else bad "host round trip: peak $p3"; cat play-after.log rec-after.log host-nj.log; fi

    echo "guest router log:"; sed 's/^/  /' guest-router.log
    kill $GR $BR $ENG $HN $PW $B1 $GJ 2>/dev/null || true
    [ $fail -eq 0 ] || exit 1
    touch $out
  ''
