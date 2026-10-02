# companion-cli-tests — `oligarchy-companion` against a fake companion.
#
# The script runs for real; ssh, the companion's sudo/nixos-rebuild/wg, and
# this host's nixos-rebuild/dsp-ctl/ip/getent are stubs that record what they
# were asked. The fake ssh runs the remote command locally with /etc/nixos
# rewritten to a fake root, so the tar/install/mv the script sends really
# happen to a directory tree that can be inspected. What it proves:
#
#   enroll  copies the companion's flake, writes a commander.nix that EVALUATES
#           to the attrset ArchibaldOS's companion module reads, installs it
#           remotely, switches remotely, reads the companion's key back, and
#           refuses a machine that is not a companion;
#   deploy  builds HERE against the tunnel address, syncs /etc/nixos back with
#           the previous copy kept, and refuses when the companion's
#           hosts/installed moved since the last sync (unless --force);
#   status  hands dsp-ctl the ssh transport, user and tunnel address.
#
# What it cannot prove: a real SSH session, a real switch on ArchibaldOS, a
# real tunnel. ArchibaldOS's checks.installed-contract evaluates the same
# commander.nix shape (its companion-enrolled fixture) against the module.
{ pkgs }:

let
  stub = name: text: pkgs.writeShellScript name text;
in
pkgs.runCommand "companion-cli-tests"
{
  nativeBuildInputs = with pkgs; [ bash jq gnutar coreutils findutils gnugrep gawk gnused nix ];
}
  ''
    set -euo pipefail
    export HOME=$TMPDIR/home FAKE=$TMPDIR/fake LOG=$TMPDIR/calls
    mkdir -p $HOME/.ssh bin remote-bin
    : > $LOG
    echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEY maria@werkbank" > $HOME/.ssh/id_ed25519.pub

    # ── the fake companion ────────────────────────────────────────────────
    mkcompanion() { # ROOT PROFILE
      mkdir -p $1/etc/nixos/hosts/installed
      echo '{ outputs = _: { }; }' > $1/etc/nixos/flake.nix
      echo "{ \"schema\": 1, \"profile\": \"$2\", \"user\": { \"name\": \"asher\" } }" > $1/etc/nixos/hosts/installed/install.json
      echo '{ }' > $1/etc/nixos/hosts/installed/hardware-configuration.nix
    }
    mkcompanion $FAKE companion
    mkcompanion $TMPDIR/audio-box audio

    # ── stubs ─────────────────────────────────────────────────────────────
    cp ${stub "ssh" ''
      while [ $# -gt 0 ]; do
        case "$1" in
          -o|-p|-i|-l) shift 2 ;;
          -O) echo "ssh -O $2" >> $LOG; exit 0 ;;
          -t|-tt|-T|-q|-n) shift ;;
          *) break ;;
        esac
      done
      dest=$1; shift
      echo "ssh $dest $*" >> $LOG
      [ $# -gt 0 ] || exit 0
      root=$FAKE
      case "$dest" in *audio-box*) root=$TMPDIR/audio-box ;; esac
      cmd="$*"
      cmd=''${cmd//\/etc\/nixos/$root\/etc\/nixos}
      cmd=''${cmd//\~\//$root\/home\/}
      mkdir -p $root/home
      PATH=$PWD/remote-bin:$PATH exec bash -c "$cmd"
    ''} bin/ssh
    cp ${stub "sudo" ''exec "$@"''} remote-bin/sudo
    cp ${stub "nixos-rebuild-remote" ''echo "remote nixos-rebuild $*" >> $LOG''} remote-bin/nixos-rebuild
    cp ${stub "wg" ''echo "COMPANIONKEY0000000000000000000000000000000="''} remote-bin/wg
    cp ${stub "nixos-rebuild" ''echo "local nixos-rebuild $*" >> $LOG''} bin/nixos-rebuild
    cp ${stub "dsp-ctl" ''echo "dsp-ctl $*" >> $LOG''} bin/dsp-ctl
    cp ${stub "getent" ''echo "192.168.1.42    STREAM $2"''} bin/getent
    cp ${stub "ip" ''echo "192.168.1.42 dev wlan0 src 192.168.1.10 uid 1000"''} bin/ip
    cp ${stub "hostname" ''echo commander''} bin/hostname
    export PATH=$PWD/bin:$PATH

    # ── the hub ───────────────────────────────────────────────────────────
    echo "HUBKEY00000000000000000000000000000000000000=" > $TMPDIR/hub.pub
    conf() { # MEMBERS-JSON
      jq -n --arg pk $TMPDIR/hub.pub --argjson m "$1" \
        '{interface: "wg-companions", address: "10.77.0.1", prefixLength: 24, listenPort: 51877, publicKeyFile: $pk, members: $m}' \
        > $TMPDIR/companions.json
    }
    export OLIGARCHY_COMPANIONS_CONF=$TMPDIR/companions.json
    conf '{"rack": {"address": "10.77.0.2", "user": "x"}}'
    oc() { bash ${../../modules/companions/oligarchy-companion.sh} "$@"; }
    pass() { echo "PASS: $*"; }
    fail() { echo "FAIL: $*"; cat $LOG; exit 1; }

    # ── enroll ────────────────────────────────────────────────────────────
    oc enroll surface asher@surface.lan > enroll.out 2> enroll.err || { cat enroll.err; fail "enroll exited non-zero"; }
    flake=$HOME/.local/state/oligarchy-companion/surface/flake
    [ -f $flake/hosts/installed/install.json ] || fail "the companion's flake was not copied"
    pass "enroll copies the companion's /etc/nixos"

    got=$(NIX_STATE_DIR=$TMPDIR/nix-state nix-instantiate --store dummy:// --eval --strict --json \
      $flake/hosts/installed/commander.nix 2>eval.err) || { cat eval.err; fail "commander.nix does not evaluate"; }
    want='{"archibald":{"companion":{"commander":{"address":"10.77.0.1","sshKeys":["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEY maria@werkbank"],"wireguard":{"address":"10.77.0.3/24","enable":true,"endpoint":"192.168.1.10:51877","peerPublicKey":"HUBKEY00000000000000000000000000000000000000="}}}}}'
    [ "$(jq -cS . <<<"$got")" = "$(jq -cS . <<<"$want")" ] || { echo "$got"; fail "commander.nix evaluates to the wrong attrset"; }
    pass "commander.nix evaluates to what ArchibaldOS's companion module reads (.2 taken by a member, so .3)"

    cmp $flake/hosts/installed/commander.nix $FAKE/etc/nixos/hosts/installed/commander.nix || fail "commander.nix not installed on the companion"
    grep -q "remote nixos-rebuild switch --flake $FAKE/etc/nixos#installed" $LOG || fail "the companion did not switch"
    pass "commander.nix installed on the companion, which switched to it"

    jq -e '.publicKey == "COMPANIONKEY0000000000000000000000000000000=" and .address == "10.77.0.3"' \
      $HOME/.local/state/oligarchy-companion/surface/meta.json >/dev/null || fail "meta.json"
    grep -q 'custom.companions.members.surface' enroll.out && grep -q 'publicKey = "COMPANIONKEY' enroll.out \
      || fail "enroll did not print the members entry"
    grep -q "ssh root@surface.lan wg show wg-oligarchy public-key" $LOG || fail "the key was not read back as root"
    pass "the companion's key is read back as root and the members entry printed"

    if oc enroll box asher@audio-box.lan > /dev/null 2> refuse.err; then fail "enrolled a non-companion"; fi
    grep -q "runs the 'audio' profile, not a companion" refuse.err || { cat refuse.err; fail "wrong refusal"; }
    pass "enroll refuses a machine that is not a companion"

    # ── deploy ────────────────────────────────────────────────────────────
    conf '{"surface": {"address": "10.77.0.3", "user": "asher"}}'
    echo '{ archibald.companion.audio.device = "hw:1"; }' > $flake/hosts/installed/local.nix
    : > $LOG
    oc deploy surface 2> deploy.err || { cat deploy.err; fail "deploy exited non-zero"; }
    grep -q "local nixos-rebuild switch --flake path:$flake#installed --target-host root@10.77.0.3" $LOG \
      || fail "deploy did not build here against the tunnel address"
    cmp $flake/hosts/installed/local.nix $FAKE/etc/nixos/hosts/installed/local.nix || fail "the copy was not synced back"
    [ -f $FAKE/etc/nixos.prev/flake.nix ] || fail "the previous /etc/nixos was not kept"
    pass "deploy builds here, switches over the tunnel, syncs /etc/nixos back and keeps the previous one"

    echo '{ }' > $FAKE/etc/nixos/hosts/installed/local.nix   # an edit made on the companion
    if oc deploy surface 2> diverge.err; then fail "deploy overwrote an edit made on the companion"; fi
    grep -q "changed since the last sync" diverge.err || { cat diverge.err; fail "wrong refusal"; }
    oc deploy surface --force 2>/dev/null || fail "--force did not deploy"
    cmp $flake/hosts/installed/local.nix $FAKE/etc/nixos/hosts/installed/local.nix || fail "--force did not sync"
    pass "deploy refuses when the companion's hosts/installed moved since the last sync; --force overrides"

    # ── status ────────────────────────────────────────────────────────────
    : > $LOG
    oc status surface 2>/dev/null
    grep -qx "dsp-ctl --transport ssh --user asher --host 10.77.0.3 status" $LOG || fail "status"
    oc status surface latency 2>/dev/null
    grep -qx "dsp-ctl --transport ssh --user asher --host 10.77.0.3 latency" $LOG || fail "status args"
    pass "status drives dsp-ctl over ssh as the companion user at the tunnel address"

    touch $out
  ''
