# haven-smoke — boots the Haven server inside the build sandbox on loopback and
# probes /api/version, failing on a non-200. No KVM, no network beyond the
# package's own build-time fetches: the server listens on 127.0.0.1 and the
# test curls it. This proves the packaged server actually starts, generates its
# self-signed certificate, and answers — the failure mode every "it builds"
# gate misses.
#
# Haven writes its data dir and certificate on first boot, so HAVEN_DATA_DIR is
# pointed at a scratch dir under $TMPDIR. A background node process is started,
# polled for readiness, probed, then killed before the derivation ends.
{
  lib,
  pkgs,
  haven,
}:

pkgs.runCommand "haven-smoke"
  {
    nativeBuildInputs = [ haven pkgs.curl ];
    meta = with lib; {
      description = "Haven smoke test — boot the server and probe /api/version";
      license = licenses.bsd3;
      platforms = platforms.linux;
    };
  }
  ''
    set -euo pipefail
    export HAVEN_DATA_DIR="$TMPDIR/haven-data"
    export PORT=3300
    export HOST=127.0.0.1
    export ADMIN_USERNAME=smoketest

    haven &
    pid=$!

    cleanup() { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }
    trap cleanup EXIT

    # Haven takes a few seconds to generate its cert and come up. Poll the
    # version endpoint (self-signed, so -k) until it answers or we time out.
    ok=0
    for i in $(seq 1 60); do
      if curl -ks "https://127.0.0.1:$PORT/api/version" > "$TMPDIR/version.json" 2>/dev/null; then
        ok=1
        break
      fi
      sleep 1
    done

    if [ "$ok" -ne 1 ]; then
      echo "haven-smoke FAILED: server did not answer within 60s" >&2
      exit 1
    fi

    echo "haven-smoke: /api/version ->" >&2
    cat "$TMPDIR/version.json" >&2

    touch "$out"
  ''
