# oligarchy-companion — command ArchibaldOS companion machines from here.
#
#   oligarchy-companion list
#   oligarchy-companion pubkey
#   oligarchy-companion enroll NAME USER@HOST [--address A] [--endpoint IP:PORT] [--key FILE]
#   oligarchy-companion deploy NAME [--force] [--boot]
#   oligarchy-companion pull NAME
#   oligarchy-companion status NAME [DSP-CTL ARGS...]
#   oligarchy-companion ssh NAME [COMMAND...]
#   oligarchy-companion path NAME
#
# Each companion has a copy of its flake here, under
# ${XDG_STATE_HOME:-~/.local/state}/oligarchy-companion/NAME/flake. Deploys
# build from that copy on THIS machine (a 4 GB companion never compiles) and
# then sync it back to the companion's /etc/nixos, so the two stay identical.
# Edit hosts/installed/local.nix in the copy, then `deploy`.
#
# Wired by modules/companions (custom.companions); reads
# /etc/oligarchy/companions.json, never a key.

set -euo pipefail

CONF=${OLIGARCHY_COMPANIONS_CONF:-/etc/oligarchy/companions.json}
STATE=${XDG_STATE_HOME:-$HOME/.local/state}/oligarchy-companion

die() { echo "oligarchy-companion: $*" >&2; exit 1; }
say() { echo "==> $*" >&2; }

usage() {
  cat >&2 <<'EOF'
usage: oligarchy-companion list
       oligarchy-companion pubkey
       oligarchy-companion enroll NAME USER@HOST [--address A] [--endpoint IP:PORT] [--key FILE]
       oligarchy-companion deploy NAME [--force] [--boot]
       oligarchy-companion pull NAME
       oligarchy-companion status NAME [DSP-CTL ARGS...]
       oligarchy-companion ssh NAME [COMMAND...]
       oligarchy-companion path NAME
EOF
  exit 2
}

# enroll's SSH control master, closed on exit. Globals: a trap runs after the
# function that set it has returned, when its locals are gone.
CM_DIR=""
CM_TARGET=""
cleanup() {
  if [ -n "$CM_DIR" ]; then
    ssh -o ControlPath="$CM_DIR/cm" -O exit "$CM_TARGET" 2>/dev/null || true
    rm -rf "$CM_DIR"
  fi
}
trap cleanup EXIT

conf() {
  [ -r "$CONF" ] || die "$CONF is missing: set custom.companions.enable = true and rebuild."
  jq -r "$1" "$CONF"
}

check_name() {
  [[ "$1" =~ ^[a-z][a-z0-9-]{0,31}$ ]] || die "'$1' is not a companion name (lowercase letters, digits, '-')."
}

dir_of() { echo "$STATE/$1"; }

meta() { jq -r "$2" "$(dir_of "$1")/meta.json"; }

# Where to reach NAME: its tunnel address once it is a declared member, the
# LAN host it was enrolled from until then.
address_of() {
  local a
  a=$(jq -r --arg n "$1" '.members[$n].address // empty' "$CONF" 2>/dev/null || true)
  if [ -n "$a" ]; then echo "$a"; return; fi
  [ -f "$(dir_of "$1")/meta.json" ] || die "no companion '$1' (enroll it first)."
  say "'$1' is not in custom.companions.members yet: using its LAN address."
  meta "$1" .lanHost
}

user_of() {
  local u
  u=$(jq -r --arg n "$1" '.members[$n].user // empty' "$CONF" 2>/dev/null || true)
  if [ -n "$u" ]; then echo "$u"; return; fi
  meta "$1" .user
}

# A digest of hosts/installed (sorted path + content hash), so a deploy can
# tell whether the companion's copy moved since the last sync.
installed_digest_cmd='cd /etc/nixos/hosts/installed && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d" " -f1'

local_digest() {
  (cd "$(dir_of "$1")/flake/hosts/installed" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d" " -f1)
}

fetch_flake() { # SSH_ARGS... DEST
  local dest=${*: -1}
  local ssh_args=("${@:1:$#-1}")
  rm -rf "$dest.new"
  mkdir -p "$dest.new"
  # shellcheck disable=SC2029
  ssh "${ssh_args[@]}" 'test -f /etc/nixos/hosts/installed/install.json && tar -C /etc/nixos -cf - .' |
    tar -C "$dest.new" -xf - ||
    die "could not copy /etc/nixos from the companion (is it an ArchibaldOS install?)"
  rm -rf "$dest.prev"
  [ -e "$dest" ] && mv "$dest" "$dest.prev"
  mv "$dest.new" "$dest"
}

# Addresses handed out by enroll but not yet declared as members. (An `if`,
# not `[ -f ] && …`: the last test's status would be the loop's, and under
# pipefail + errexit a failed loop in a substitution ends the script silently.)
enrolled_addresses() {
  local m
  for m in "$STATE"/*/meta.json; do
    if [ -f "$m" ]; then jq -r .address "$m"; fi
  done
}

cmd_list() {
  conf '.members | to_entries[] | "\(.key)\t\(.value.address)\t\(.value.user)"'
  if [ -d "$STATE" ]; then
    for d in "$STATE"/*/meta.json; do
      [ -f "$d" ] || continue
      n=$(basename "$(dirname "$d")")
      jq -e --arg n "$n" '.members[$n]' "$CONF" >/dev/null 2>&1 ||
        echo -e "$n\t(enrolled, not yet a member)\t$(jq -r .user "$d")"
    done
  fi
}

cmd_pubkey() {
  local f
  f=$(conf .publicKeyFile)
  [ -r "$f" ] || die "$f is missing: is the $(conf .interface) interface up?"
  cat "$f"
}

cmd_enroll() {
  local name=${1:-} target=${2:-}
  [ -n "$name" ] && [ -n "$target" ] || usage
  shift 2
  check_name "$name"
  [[ "$target" == *@* ]] || die "give the companion as USER@HOST (the user chosen at install)."
  local user=${target%@*} host=${target#*@}
  local address="" endpoint="" key=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --address) address=$2; shift 2 ;;
      --endpoint) endpoint=$2; shift 2 ;;
      --key) key=$2; shift 2 ;;
      *) die "unknown option $1" ;;
    esac
  done

  local hub iface port prefix hubkey
  hub=$(conf .address)
  iface=$(conf .interface)
  port=$(conf .listenPort)
  prefix=$(conf .prefixLength)
  hubkey=$(cmd_pubkey)

  if [ -z "$address" ]; then
    [ "$prefix" = 24 ] || die "pick an address with --address (automatic choice needs a /24)."
    local net used n
    net=${hub%.*}
    used=$( { conf '.members[].address'; echo "$hub"; enrolled_addresses; } | sort -u)
    for n in $(seq 2 254); do
      grep -qx "$net.$n" <<<"$used" || { address="$net.$n"; break; }
    done
    [ -n "$address" ] || die "no free address left in $net.0/24."
  fi

  if [ -z "$endpoint" ]; then
    local ip src
    ip=$(getent ahostsv4 "$host" | awk 'NR==1{print $1}')
    [ -n "$ip" ] || die "cannot resolve $host."
    src=$(ip -4 route get "$ip" | grep -o 'src [0-9.]*' | awk '{print $2}')
    [ -n "$src" ] || die "no route to $ip; give --endpoint IP:PORT (this host as the companion sees it)."
    endpoint="$src:$port"
  fi

  if [ -z "$key" ]; then
    for k in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_ecdsa.pub" "$HOME/.ssh/id_rsa.pub"; do
      [ -f "$k" ] && { key=$k; break; }
    done
    [ -n "$key" ] || die "no SSH key in ~/.ssh: create one (ssh-keygen -t ed25519) or pass --key FILE."
  fi
  local pub
  pub=$(head -n1 "$key")
  [[ "$pub" =~ ^(ssh-|ecdsa-|sk-) ]] || die "$key does not look like an SSH public key."

  local d
  d=$(dir_of "$name")
  mkdir -p "$d"
  CM_DIR=$(mktemp -d)
  CM_TARGET=$target
  local ssh=(-o ControlMaster=auto -o ControlPath="$CM_DIR/cm" -o ControlPersist=300 "$target")

  say "Connecting to $target (its password, once)"
  ssh "${ssh[@]}" true

  say "Copying its /etc/nixos to $d/flake"
  fetch_flake "${ssh[@]}" "$d/flake"
  local profile
  profile=$(jq -r .profile "$d/flake/hosts/installed/install.json")
  [[ "$profile" == companion* ]] || die "$host runs the '$profile' profile, not a companion."

  say "Writing hosts/installed/commander.nix"
  cat >"$d/flake/hosts/installed/commander.nix" <<EOF
# Written by \`oligarchy-companion enroll $name\` on $(hostname). Re-run enroll
# to change it; your own settings belong in local.nix.
{
  archibald.companion.commander = {
    address = "$hub";
    sshKeys = [ "$pub" ];
    wireguard = {
      enable = true;
      address = "$address/$prefix";
      peerPublicKey = "$hubkey";
      endpoint = "$endpoint";
    };
  };
}
EOF

  say "Installing it on $host and switching (sudo asks for the password)"
  ssh "${ssh[@]}" 'cat > ~/.oligarchy-commander.nix' <"$d/flake/hosts/installed/commander.nix"
  ssh -t "${ssh[@]}" 'sudo install -m 0644 ~/.oligarchy-commander.nix /etc/nixos/hosts/installed/commander.nix && rm -f ~/.oligarchy-commander.nix && sudo nixos-rebuild switch --flake /etc/nixos#installed'

  say "Reading its WireGuard key back (as root, with your key: password logins are now off)"
  local theirs
  theirs=$(ssh -o ControlPath=none -o BatchMode=yes "root@$host" 'wg show wg-oligarchy public-key')
  [ -n "$theirs" ] || die "the companion has no wg-oligarchy key yet; check 'systemctl status wireguard-wg-oligarchy' there."

  jq -n --arg u "$user" --arg h "$host" --arg a "$address" --arg k "$theirs" \
    '{user: $u, lanHost: $h, address: $a, publicKey: $k}' >"$d/meta.json"
  local_digest "$name" >"$d/synced"

  cat <<EOF

$name is enrolled. Add it to this host's configuration and rebuild:

  custom.companions.members.$name = {
    address = "$address";
    publicKey = "$theirs";
    user = "$user";
  };

Until then the tunnel is down; to bring it up now, for this boot only:

  sudo wg set $iface peer $theirs allowed-ips $address/32

Then:  oligarchy-companion status $name
EOF
}

cmd_pull() {
  local name=${1:-}
  [ -n "$name" ] || usage
  check_name "$name"
  local addr
  addr=$(address_of "$name")
  say "Copying root@$addr:/etc/nixos to $(dir_of "$name")/flake (the old copy is kept as flake.prev)"
  fetch_flake -o BatchMode=yes "root@$addr" "$(dir_of "$name")/flake"
}

cmd_deploy() {
  local name=${1:-} force=0 action=switch
  [ -n "$name" ] || usage
  shift
  check_name "$name"
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=1; shift ;;
      --boot) action=boot; shift ;;
      *) die "unknown option $1" ;;
    esac
  done
  local d addr theirs ours
  d=$(dir_of "$name")
  [ -f "$d/flake/flake.nix" ] || die "no copy of '$name' here: enroll it first."
  addr=$(address_of "$name")

  # The companion's own hosts/installed must not have moved since the last
  # sync, or this deploy would silently undo an edit made there.
  # shellcheck disable=SC2029
  theirs=$(ssh -o BatchMode=yes "root@$addr" "$installed_digest_cmd")
  if [ "$force" != 1 ] && [ -f "$d/synced" ] && [ "$theirs" != "$(cat "$d/synced")" ]; then
    die "the companion's /etc/nixos/hosts/installed changed since the last sync. 'oligarchy-companion pull $name' takes its version; --force overwrites it."
  fi

  say "Building $name here and switching it ($action)"
  nixos-rebuild "$action" --flake "path:$d/flake#installed" --target-host "root@$addr"

  say "Syncing the copy to $addr:/etc/nixos (the previous one is kept as /etc/nixos.prev)"
  tar -C "$d/flake" -cf - . | ssh -o BatchMode=yes "root@$addr" \
    'set -e; t=$(mktemp -d /etc/nixos.sync.XXXXXX); tar -C "$t" -xf -; chmod 755 "$t"; rm -rf /etc/nixos.prev; if [ -e /etc/nixos ]; then mv /etc/nixos /etc/nixos.prev; fi; mv "$t" /etc/nixos'
  ours=$(local_digest "$name")
  echo "$ours" >"$d/synced"
}

cmd_status() {
  local name=${1:-}
  [ -n "$name" ] || usage
  shift
  check_name "$name"
  local addr user
  addr=$(address_of "$name")
  user=$(user_of "$name")
  if [ $# -eq 0 ]; then set -- status; fi
  exec dsp-ctl --transport ssh --user "$user" --host "$addr" "$@"
}

cmd_ssh() {
  local name=${1:-}
  [ -n "$name" ] || usage
  shift
  check_name "$name"
  exec ssh "$(user_of "$name")@$(address_of "$name")" "$@"
}

cmd_path() {
  [ -n "${1:-}" ] || usage
  check_name "$1"
  echo "$(dir_of "$1")/flake"
}

case "${1:-}" in
  list) shift; cmd_list "$@" ;;
  pubkey) shift; cmd_pubkey "$@" ;;
  enroll) shift; cmd_enroll "$@" ;;
  deploy) shift; cmd_deploy "$@" ;;
  pull) shift; cmd_pull "$@" ;;
  status) shift; cmd_status "$@" ;;
  ssh) shift; cmd_ssh "$@" ;;
  path) shift; cmd_path "$@" ;;
  *) usage ;;
esac
