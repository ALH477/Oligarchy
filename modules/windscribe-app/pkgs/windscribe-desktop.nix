# Windscribe Desktop-App, repackaged from the upstream release artifact.
#
# NOT built from source, and that is a considered decision rather than a
# shortcut. Upstream's Linux build drives vcpkg against a CUSTOM Windscribe
# registry (tools/vcpkg/vcpkg-configuration.json) holding patched qtbase,
# openssl, curl-with-ech, openvpn, c-ares and spdlog, then FetchContent-clones
# github.com/Windscribe/wsnet at configure time, then builds Qt itself from
# tools/deps. Every one of those steps wants the network, which a Nix build
# does not have. Reproducing it means pinning vcpkg, the registry, wsnet and
# the upstream tarball of each of ~25 ports as separate fixed-output
# derivations, and then convincing vcpkg to run fully offline. See the README
# for what that would take.
#
# The GPLv2 release .deb is the same artifact Debian, Fedora, openSUSE and Arch
# users install, so this tracks upstream exactly.
{ lib
, stdenvNoCC
, fetchurl
, dpkg
, autoPatchelfHook
, bash
, coreutils
, gnugrep
, gnused
, gawk
, util-linux
, iproute2
, procps
, nftables
, systemd
, dbus
, acl
, libcap_ng
, libnl
, glib
, brotli
, libdrm
, zstd
, pcre2
, harfbuzz
, freetype
, fontconfig
, libglvnd
, libxkbcommon
, wayland
, xorg
, openssl
}:

let
  version = "2.24.13";

  # sha256 of the upstream release asset, per architecture. Regenerate with
  #   nix store prefetch-file --hash-type sha256 <url>
  sources = {
    x86_64-linux = {
      deb = "windscribe_${version}_amd64.deb";
      hash = "sha256-eanxf898hY6NKzHM2umrfabjhA+8kKl0AQTLCsvOGZE=";
    };
    aarch64-linux = {
      deb = "windscribe_${version}_arm64.deb";
      hash = "sha256-pvbcsQ4Uz51bDmdvoE69l3E7/ivf7OFGWB5Psoi8Fls=";
    };
  };

  src' = sources.${stdenvNoCC.hostPlatform.system} or
    (throw "windscribe-desktop: no upstream release artifact for ${stdenvNoCC.hostPlatform.system}");

  # Tools the helper's root scripts reach for. The shipped systemd unit pins
  # PATH to /usr/sbin:/usr/bin:/sbin:/bin, which holds none of these on NixOS,
  # so each script gets this prepended to its own PATH rather than relying on
  # whatever the helper hands down.
  scriptPath = lib.makeBinPath [
    bash
    coreutils
    gnugrep
    gnused
    gawk
    util-linux # mount, used by cgroups-up/down to find the net_cls hierarchy
    iproute2 # ip
    procps
    nftables
    systemd # resolvectl
  ];
in
stdenvNoCC.mkDerivation {
  pname = "windscribe-desktop";
  inherit version;

  src = fetchurl {
    url = "https://github.com/Windscribe/Desktop-App/releases/download/v${version}/${src'.deb}";
    inherit (src') hash;
  };

  nativeBuildInputs = [ dpkg autoPatchelfHook ];

  buildInputs = [
    acl
    glib
    brotli
    libdrm
    zstd
    pcre2
    harfbuzz
    freetype
    fontconfig
    libglvnd # libGL, libEGL
    libxkbcommon
    wayland
    openssl
    nftables # libnftables.so.1, needed by the helper
    # The bundled windscribeopenvpn wants these; nothing else in the tree does.
    libcap_ng
    libnl
    (lib.getLib systemd) # libudev
    xorg.libX11
    xorg.libxcb
    xorg.xcbutil
    xorg.xcbutilimage
    xorg.xcbutilkeysyms
    xorg.xcbutilwm # libxcb-icccm
    xorg.xcbutilrenderutil
    xorg.xcbutilcursor
    xorg.libXext
    xorg.libXfixes
    xorg.libXrender
  ];

  # Qt is statically linked into the client, so there is no Qt plugin path to
  # wrap; the X/Wayland/GL stack above is the whole of it. The three libraries
  # upstream bundles (libwsnet.so and their own libcrypto/libssl soname 4) live
  # in $out/opt/windscribe/lib, which autoPatchelfHook picks up from the output
  # itself.
  unpackPhase = ''
    runHook preUnpack
    dpkg-deb -x "$src" ./unpacked
    runHook postUnpack
  '';

  installPhase = ''
        runHook preInstall

        mkdir -p "$out/opt" "$out/bin" "$out/share"
        cp -r ./unpacked/opt/windscribe "$out/opt/windscribe"
        cp -r ./unpacked/usr/share/icons "$out/share/icons"

        # The scripts the root helper executes. Two changes each: a real shebang
        # (NixOS has no /bin/bash) and a PATH prepend, because the helper runs them
        # with a PATH that names only FHS directories.
        for s in "$out"/opt/windscribe/scripts/*; do
          [ -f "$s" ] || continue
          substituteInPlace "$s" --replace-quiet '#!/bin/bash' '#!${bash}/bin/bash'
          sed -i "2i export PATH=${scriptPath}:\$PATH" "$s"
          chmod +x "$s"
        done

        # In-app update is meaningless here and would be actively wrong: it dpkg's
        # a downloaded .deb over /opt/windscribe, which on this system is a symlink
        # into the read-only store. Replace it with an honest refusal rather than
        # leaving a script that fails with a permissions error.
        rm -f "$out/opt/windscribe/scripts/install-update"
        cat > "$out/opt/windscribe/scripts/install-update" <<EOS
    #!${bash}/bin/bash
    echo "windscribe: in-app update is disabled on NixOS." >&2
    echo "This build is pinned by modules/windscribe-app/pkgs/windscribe-desktop.nix;" >&2
    echo "bump the version and hash there, then rebuild." >&2
    exit 1
    EOS
        chmod +x "$out/opt/windscribe/scripts/install-update"

        # Plain launchers, not makeWrapper: makeWrapper asserts its target is an
        # executable file at BUILD time, and these execute the store binaries
        # directly. The /opt/windscribe tree the NixOS module materialises is still
        # required at runtime — it is where the compiled-in scripts/ paths point —
        # but it is not what these resolve.
        # QT_QPA_PLATFORM=xcb — XWayland — and this is measured, not folklore.
        # Under native Wayland on Hyprland the client asks for a fixed-size
        # window, does not get it, and paints its scene clipped inside a
        # surface the compositor sized differently: the UI draws in the wrong
        # place with garbage around it. The identical build under XWayland
        # renders correctly at its requested size. Override per launch with
        # WINDSCRIBE_QT_PLATFORM=wayland once upstream fixes it.
        cat > "$out/bin/windscribe" <<EOS
    #!${bash}/bin/bash
    : "\''${WINDSCRIBE_QT_PLATFORM:=xcb}"
    export QT_QPA_PLATFORM="\$WINDSCRIBE_QT_PLATFORM"
    exec "$out/opt/windscribe/Windscribe" "\$@"
    EOS
        cat > "$out/bin/windscribe-cli" <<EOS
    #!${bash}/bin/bash
    exec "$out/opt/windscribe/windscribe-cli" "\$@"
    EOS
        chmod +x "$out/bin/windscribe" "$out/bin/windscribe-cli"

        # Both shipped entries carry Exec=/opt/windscribe/Windscribe, which
        # bypasses the launcher above and therefore the XWayland default.
        # Repoint them so the app launcher and the autostart entry behave the
        # same way the command line does.
        install -Dm644 ./unpacked/usr/share/applications/windscribe.desktop \
          "$out/share/applications/windscribe.desktop"
        install -Dm644 ./unpacked/etc/windscribe/autostart/windscribe.desktop \
          "$out/share/windscribe/autostart/windscribe.desktop"
        substituteInPlace \
          "$out/share/applications/windscribe.desktop" \
          "$out/share/windscribe/autostart/windscribe.desktop" \
          --replace-quiet "/opt/windscribe/Windscribe" "$out/bin/windscribe"

        runHook postInstall
  '';

  # ------------------------------------------------------------------------
  # autoPatchelfHook vs. the two Go helpers: the trap, the evidence, the fix.
  #
  # windscribewstunnel and windscribeamneziawg are Go binaries (cgo-linked
  # against libc.so.6 only, per `patchelf --print-needed` on the upstream
  # artifact), sitting in the same $out/opt/windscribe tree as three
  # ordinary C/C++ binaries. autoPatchelf (auto_patchelf_file in
  # pkgs/by-name/au/auto-patchelf's auto-patchelf.py) patches every ELF it
  # finds with TWO SEPARATE subprocess calls per file: one
  # `patchelf --set-interpreter <long /nix/store/...-glibc/lib/ld-linux...>`,
  # then a second, independent `patchelf --set-rpath <rpath>` on the same
  # already-rewritten file. For the C binaries here that two-step rewrite is
  # invisible. For these two it is fatal: measured against the real upstream
  # v2.24.13 release artifact, a fresh copy run through exactly that
  # two-call sequence dies to SIGSEGV (rc=139) on every invocation — no
  # args, --help, --version, all of them — reproduced by hand outside the
  # Nix sandbox to confirm it is the sequence itself and not something
  # sandbox-specific. Neither binary ever prints so much as a loader
  # error; the client only ever sees a dead process and logs
  # "wstunnel failed to start" / ConnectionManager error 5, because nothing
  # about a SIGSEGV during dynamic linking is Windscribe's to report.
  #
  # A SINGLE combined `--set-interpreter ... --set-rpath ...` invocation on
  # a FRESH copy is not the fix either — it still crashes just the same, so
  # "it's the two-call split" is not the whole mechanism. What reliably
  # produces a working binary, verified across eight independent
  # fresh-copy trials (four each, both helpers, both --version and --help
  # probed on every trial), is applying that identical combined patchelf
  # invocation TWICE in a row on the same file. The working theory: the
  # first pass has to grow the .interp content (21 bytes of
  # "/lib64/ld-linux-x86-64.so.2" to 70-odd bytes of a Nix store path) and
  # add an rpath that was not there before, so it must relocate program
  # headers and repad the file to make room — and something about that
  # first, "cold" rewrite of a binary shipped with only the upstream
  # ld.so's minimal reserved header space leaves a layout Go's own runtime
  # cannot survive at process start (Go parses its own ELF program headers
  # directly off the auxiliary vector rather than trusting the dynamic
  # linker to have gotten them right — part of why the earlier diagnosis
  # here saw crashes attributed to ld-linux-x86-64.so.2 itself). The second
  # pass rewrites a file that already has that room and needs no further
  # relocation, and its output has run cleanly in every trial, including a
  # deliberate third re-patch afterward to rule out the fix being fragile.
  # This is an empirically confirmed workaround, not a documented patchelf
  # behaviour, and deliberately not `--no-clobber-old-sections`: that flag
  # does not exist before patchelf 0.18, and the toolchain pinned here
  # (nixpkgs 25.11) carries patchelf 0.15.2 — confirmed by hand, the flag
  # is rejected outright ("getting info about '--no-clobber-old-sections':
  # No such file or directory") rather than silently ignored.
  #
  # The fix: pull these two out of autoPatchelfHook's sweep entirely (a
  # half-patched-then-crashed binary is worse than an untouched one), let
  # the hook patch everything else exactly as it always has, then patch
  # these two by hand, twice, once the hook has already decided what
  # interpreter and rpath the rest of the tree is using. That interpreter
  # and rpath are read back off windscribeopenvpn — an ordinary,
  # dynamically-linked C binary in the same directory that wants libc same
  # as these two do — rather than re-derived from glibc's own store path
  # independently, so this can never drift from whatever autoPatchelfHook
  # chose for its siblings on a future rebuild. Deliberately NOT
  # windscribectrld: the build log shows autoPatchelf skipping it
  # ("skipping .../windscribectrld because it is statically linked") — it
  # carries no .interp/.dynamic section at all, and asking patchelf to
  # print either off a static binary is itself a build failure
  # ("no section headers. The input file is probably a statically linked,
  # self-decompressing binary"), caught the hard way once already while
  # writing this fix.
  preFixup = ''
    mkdir -p "$TMPDIR/go-helper-stash"
    mv "$out/opt/windscribe/windscribewstunnel" "$TMPDIR/go-helper-stash/windscribewstunnel"
    mv "$out/opt/windscribe/windscribeamneziawg" "$TMPDIR/go-helper-stash/windscribeamneziawg"

    # Scheduled to run AFTER autoPatchelfPostFixup, not before: that hook's
    # setup script already pushed itself onto postFixupHooks at build
    # start (setup hooks from nativeBuildInputs are sourced long before any
    # phase, including this preFixup, ever runs), so appending our own
    # entry here lands after it in the array runHook postFixup iterates —
    # autoPatchelf gets to sweep the (Go-binary-free) tree first, then this
    # runs.
    fixUpGoHelperInterpreters() {
      local go_bin interp rpath

      mv "$TMPDIR/go-helper-stash/windscribewstunnel" "$out/opt/windscribe/windscribewstunnel"
      mv "$TMPDIR/go-helper-stash/windscribeamneziawg" "$out/opt/windscribe/windscribeamneziawg"

      interp="$(patchelf --print-interpreter "$out/opt/windscribe/windscribeopenvpn")"
      rpath="$(patchelf --print-rpath "$out/opt/windscribe/windscribeopenvpn")"

      for go_bin in windscribewstunnel windscribeamneziawg; do
        # Twice, deliberately — this is not a typo and not defensive
        # belt-and-braces. See the block comment above this phase: a
        # single pass on a fresh copy still corrupts these two.
        patchelf --set-interpreter "$interp" --set-rpath "$rpath" \
          "$out/opt/windscribe/$go_bin"
        patchelf --set-interpreter "$interp" --set-rpath "$rpath" \
          "$out/opt/windscribe/$go_bin"
      done
    }
    postFixupHooks+=(fixUpGoHelperInterpreters)
  '';

  # THE ONE THING autoPatchelfHook CANNOT SEE.
  #
  # Qt's QtDBus here is built with -dbus-runtime, so it dlopen()s
  # libdbus-1.so.3 by soname instead of linking it. There is no DT_NEEDED
  # entry, so autoPatchelfHook has nothing to resolve and reports a clean
  # build — and the failure lands nowhere near D-Bus: the client starts,
  # paints nothing, and SEGVs inside
  # QDBusAbstractInterface::callWithArgumentList. The chain is
  # QSystemTrayIcon::isSystemTrayAvailable -> QDBusTrayIcon ->
  # QDBusMenuConnection, whose constructor calls
  # m_connection.interface()->isServiceRegistered(...) with no null check.
  # With libdbus missing, Qt never connects to the session bus, interface()
  # is null, and that unguarded dereference is the crash.
  #
  # Verified by strace: 28 RUNPATH directories searched for libdbus-1.so.3
  # (and for QLibrary's doubly-prefixed liblibdbus-1.so.3 fallback), zero
  # hits, and no connect() to the bus socket at any point.
  #
  # dbus is the ONLY such library — a full strace sweep for openat() of any
  # .so that was never resolved finds nothing else.
  appendRunpaths = [
    "${lib.getLib dbus}/lib"
    # autoPatchelfHook rewrites RPATH, which drops the compiled-in
    # /opt/windscribe/lib. The bundled libraries are in the output so it finds
    # them on its own; this only guards the case where a future upstream
    # binary dlopen()s out of that directory instead of linking it.
    "/opt/windscribe/lib"
  ];

  # ------------------------------------------------------------------------
  # Exec-smoke: the build gate for the Go-helper trap above.
  # autoPatchelfHook reported a clean build the first time this went wrong,
  # and it always will — a patchelf-corrupted Go binary is still a
  # perfectly valid file with the right name, permission bits and DT_NEEDED
  # entries, so nothing upstream of actually running it can catch this
  # class of breakage. This runs all five bundled helpers the frozen
  # contract names, out of $out/opt/windscribe (the real binaries the NixOS
  # module and the client actually exec — not the $out/bin launcher shims,
  # which only wrap the GUI and the CLI), and fails the build if any of
  # them dies to a signal. Signal death is the one and only symptom this
  # specific corruption produces; a clean non-zero exit with a usage
  # message is normal and expected (windscribeamneziawg in particular
  # legitimately refuses to run at all without an interface name), so
  # testing `rc == 0` would fail this package on itself even when nothing
  # is wrong. Do not weaken this to an rc==0 check.
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck

    exec_smoke_failed=0

    for bin in windscribewstunnel windscribeamneziawg windscribeopenvpn windscribectrld windscribe-cli; do
      bin_path="$out/opt/windscribe/$bin"
      died_on_signal=1

      # --version first, then --help, then no arguments at all, stopping
      # at the first one that comes back alive. Not every helper
      # understands --version (wstunnel and openvpn just print normal
      # usage text for an unrecognised flag instead of erroring), and that
      # is fine — falling through to the next argument form only matters
      # for telling a live-but-unhappy exit apart from a dead one, never
      # for deciding pass/fail on its own.
      for argset in --version --help ""; do
        set +e
        if [ -z "$argset" ]; then
          timeout 5 "$bin_path" >/dev/null 2>&1
        else
          timeout 5 "$bin_path" "$argset" >/dev/null 2>&1
        fi
        rc=$?
        set -e

        # A process killed by signal N reports exit status 128+N to the
        # shell - 139 for SIGSEGV, 134 for SIGABRT, 132 for SIGILL, and so
        # on for any other N. `timeout`'s own "the process was still
        # running after 5s" exit is 124, which sits below 128 and so is
        # never mistaken for a signal death here: a helper that is still
        # alive and simply hasn't returned (openvpn/ctrld with no
        # arguments can sit waiting on input) is exactly the "not dead"
        # outcome this check wants, not a failure to chase down.
        if [ "$rc" -gt 128 ]; then
          continue
        fi

        died_on_signal=0
        break
      done

      if [ "$died_on_signal" -eq 1 ]; then
        echo "exec-smoke FAIL: $bin died on a signal under --version/--help/(no args)" >&2
        exec_smoke_failed=1
      else
        echo "exec-smoke PASS: $bin"
      fi
    done

    if [ "$exec_smoke_failed" -ne 0 ]; then
      echo "windscribe-desktop: one or more bundled helpers died on a signal - see above" >&2
      exit 1
    fi

    runHook postInstallCheck
  '';

  meta = {
    description = "Windscribe VPN desktop client and CLI";
    longDescription = ''
      The official Windscribe desktop client, repackaged from the upstream
      GPLv2 release .deb. Provides the Qt GUI, the windscribe-cli command, the
      root helper daemon, and the bundled openvpn/amneziawg/ctrld/wstunnel
      binaries the client drives.

      Needs the NixOS module (custom.windscribeApp) to be usable: the binaries
      have /opt/windscribe compiled in and the helper refuses to serve unless a
      group named "windscribe" exists.
    '';
    homepage = "https://github.com/Windscribe/Desktop-App";
    changelog = "https://github.com/Windscribe/Desktop-App/blob/v${version}/CHANGELOG.md";
    license = lib.licenses.gpl2Only;
    platforms = [ "x86_64-linux" "aarch64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "windscribe";
  };
}
