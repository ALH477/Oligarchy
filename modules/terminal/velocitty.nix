# velocitty — the CPU-rendered X11 terminal behind `custom.terminal.system`.
# Upstream (github:valvesky/velocitty) ships no flake, so this builds it from
# the pinned `velocitty` source input. modules/terminal/README.md carries the
# full landmine list; the four that shape THIS file are inline below.
{ lib
, stdenv
, zig_0_16
, patchelf
, symlinkJoin
, xorg
, libxkbcommon
, fontconfig
, liberation_ttf
, noto-fonts-color-emoji
, nerd-fonts
, src
, version ? "1.0.1"
}:

let
  # build.zig does its own library resolution — every linkSystemLibrary call
  # passes `use_pkg_config = .no`, so pkg-config is NOT a build input and
  # adding one does nothing — and hardcodes the two FHS paths it expects X11
  # under: `/usr/include` (addAfterIncludePath) and `/usr/lib`
  # (addLibraryPath, native-arch branch). NixOS has neither, so `-lX11` would
  # not resolve. build.zig has exactly one slot for each, which is why this is
  # one joined tree rather than three separate flags.
  x11Libs = [ xorg.libX11 xorg.libXi libxkbcommon ];
  fhs = symlinkJoin {
    name = "velocitty-x11-tree";
    # dev carries include/, out carries lib/*.so. xorgproto is headers-only and
    # single-output; libX11's headers include X11/X.h and X11/extensions/ from
    # it, so leaving it out fails at the first #include, not at link time.
    # Build-time only — postFixup below keeps this tree out of the runtime
    # closure, which is what stops the dev outputs riding along into it.
    paths = map lib.getDev x11Libs ++ map lib.getLib x11Libs ++ [ xorg.xorgproto ];
  };

  runtimeLibs = lib.makeLibraryPath x11Libs;

  # The font paths the unit tests open. Upstream hardcodes Arch's locations;
  # patches/0002 turns a miss into a LOUD skip, and these pins turn the five
  # skips into five real assertions. They are store paths, so they can never
  # be an upstream commit -- which is exactly why this is substituteInPlace
  # and not a third patch file. See patches/README.md.
  liberationMono = "${liberation_ttf}/share/fonts/truetype/LiberationMono-Regular.ttf";
  notoEmoji = "${noto-fonts-color-emoji}/share/fonts/noto/NotoColorEmoji.ttf";
  iosevkaDir = "${nerd-fonts.iosevka}/share/fonts/truetype/NerdFonts/Iosevka";
in

stdenv.mkDerivation {
  pname = "velocitty";
  inherit version src;

  nativeBuildInputs = [ zig_0_16.hook patchelf ];
  buildInputs = x11Libs;

  postPatch = ''
    # Font discovery is `fc-match` spawned off PATH (src/main.zig), and when
    # that lookup fails the fallbacks are all hardcoded Arch paths
    # (/usr/share/fonts/iosevka-term, .../liberation, .../TTF/DejaVuSansMono.ttf)
    # that do not exist here. With both legs dead main.zig logs
    # "no fonts found; drawing without glyphs" and KEEPS RUNNING: a terminal
    # window that draws nothing, exit status 0. A system terminal is launched
    # by desktop entries, `setsid` and a tray daemon, none of which guarantee
    # fontconfig on PATH — so the path is burned in here rather than prefixed
    # onto PATH with makeWrapper. That distinction matters: velocitty hands its
    # own environ to the shell it spawns, so a PATH prefix would leak into
    # every command the user then runs in that window.
    substituteInPlace src/main.zig \
      --replace-fail '"fc-match", "-f"' '"${fontconfig}/bin/fc-match", "-f"'

    # `hyprctl monitors -j` (also src/main.zig) is deliberately left as a bare
    # PATH lookup: it is a soft refresh-rate/scale query with a 60 Hz +
    # GDK_SCALE fallback, and pinning it would drag Hyprland into a terminal's
    # closure.

    substituteInPlace build.zig \
      --replace-fail '.{ .cwd_relative = "/usr/include" }' '.{ .cwd_relative = "${fhs}/include" }' \
      --replace-fail '.{ .cwd_relative = "/usr/lib" }' '.{ .cwd_relative = "${fhs}/lib" }'

    # Point the unit tests at fonts that exist here. Without this the five
    # font tests SKIP instead of running, and checkPhase refuses a skip.
    substituteInPlace src/type.zig \
      --replace-fail '/usr/share/fonts/liberation/LiberationMono-Regular.ttf' '${liberationMono}' \
      --replace-fail '/usr/share/fonts/noto/NotoColorEmoji.ttf' '${notoEmoji}' \
      --replace-fail '/usr/share/fonts/TTF/IosevkaNerdFontMono-Regular.ttf' '${iosevkaDir}/IosevkaNerdFontMono-Regular.ttf' \
      --replace-fail '/usr/share/fonts/TTF/IosevkaNerdFontMono-Bold.ttf' '${iosevkaDir}/IosevkaNerdFontMono-Bold.ttf' \
      --replace-fail '/usr/share/fonts/TTF/IosevkaNerdFontMono-Italic.ttf' '${iosevkaDir}/IosevkaNerdFontMono-Italic.ttf'
    substituteInPlace src/type/truetype.zig \
      --replace-fail '/usr/share/fonts/liberation/LiberationMono-Regular.ttf' '${liberationMono}'
    substituteInPlace src/type/cbdt.zig \
      --replace-fail '/usr/share/fonts/noto/NotoColorEmoji.ttf' '${notoEmoji}'
  '';

  # Upstream ships no `test` step, so the 95 test blocks in src/ had never been
  # run by `zig build`. patches/0001 adds one; patches/0002 stops the font
  # tests passing silently when the font is absent. Both are byte-for-byte the
  # commits proposed upstream -- see patches/README.md for the rule that keeps
  # them from drifting.
  patches = [
    ./patches/0001-build-add-a-test-step-so-zig-build-test-runs-the-tes.patch
    ./patches/0002-src-font-tests-must-skip-loudly-not-pass-silently.patch
  ];

  # The hook's defaults are `-Dcpu=baseline --release=safe`. Keep baseline (the
  # closure must not depend on this machine's CPU features) but take the
  # optimize mode upstream's own install-usr step uses: a terminal's VT parser
  # and glyph rasteriser are the latency-visible part.
  dontSetZigDefaultFlags = true;
  zigBuildFlags = [ "-Dcpu=baseline" "--release=fast" ];

  # `dontUseZigCheck = true` used to live here, which was the honest statement
  # that nothing was checked. patches/0001 gives the build a real `test` step,
  # so it is replaced by a checkPhase that refuses two different kinds of
  # nothing: a suite that did not run, and a suite that ran but skipped.
  #
  # Upstream's tests/ tree is still NOT wired and cannot be: it imports a `ZT`
  # module build.zig never declares and src/ does not export. Reported
  # upstream; see patches/README.md. So the golden PNGs stay unmeasured.
  doCheck = true;
  checkPhase = ''
    runHook preCheck

    TERM=dumb zig build test --summary all -Dcpu=baseline 2>&1 | tee zig-test.log
    st=''${PIPESTATUS[0]}
    [ "$st" -eq 0 ] || { echo "velocitty: zig build test exited $st" >&2; exit 1; }

    # `zig build test` prints nothing on success without --summary, so a green
    # silent suite would be indistinguishable from one that ran no tests.
    passed=$(sed -n 's/.*; \([0-9]\+\)\/[0-9]\+ tests passed.*/\1/p' zig-test.log | head -n1)
    [ -n "$passed" ] || { echo "velocitty: no test summary in the log" >&2; exit 1; }
    if [ "$passed" -lt 90 ]; then
      echo "velocitty: only $passed tests ran; expected at least 90" >&2; exit 1
    fi

    # The font pins in postPatch exist so these do not skip. A skip here means
    # a pin missed -- which patches/0002 makes visible instead of silent.
    if grep -q "SKIP: font not installed" zig-test.log; then
      grep "SKIP: font not installed" zig-test.log >&2
      echo "velocitty: a font pin missed, so a test skipped instead of running" >&2; exit 1
    fi
    echo "velocitty: $passed unit tests passed, none skipped"

    runHook postCheck
  '';

  # `zig build install` already places bin/velocitty plus the .desktop, the
  # icon and the man page (build.zig's three b.installFile calls), so there is
  # nothing to install by hand.
  #
  # postFixup, not postInstall: nixpkgs' own fixup runs `patchelf
  # --shrink-rpath`, which drops any entry it judges redundant — so an rpath
  # added before fixup is silently thrown away again. Two things have to be
  # corrected here, and --set-rpath does both at once:
  #
  #  1. zig leaves a RELATIVE entry, `.zig-cache/o/<hash>`, pointing at the
  #     build-time directory of the libxkbcommon link stub. A relative rpath is
  #     resolved against the process's CWD, so it is both dead weight and a
  #     library-injection surface for anything launched from a writable dir.
  #  2. Resolution would otherwise run through the symlinkJoin above, dragging
  #     the X11 *dev* outputs into the runtime closure for no reason.
  #
  # libxkbcommon is the entry that MUST survive: build.zig always links a
  # generated stub .so for it (addX11LinkStub — the host library needs a newer
  # glibc than zig's) and never installs it, so the binary carries
  # DT_NEEDED libxkbcommon.so.0 with nothing else resolving it.
  postFixup = ''
    patchelf --set-rpath "${runtimeLibs}" "$out/bin/velocitty"

    # Upstream's velocitty.desktop carries Categories=System;TerminalEmulator;
    # and a full X-TerminalArg* set, which makes it a live candidate whenever
    # anything asks the desktop for "a terminal" -- and kitty currently only
    # wins that scan because `k` sorts before `v`. Velocitty is the ADMIN
    # terminal here; it must never be picked as the interactive default by
    # accident. So the entry is moved out of the XDG search path rather than
    # deleted: the reference copy is what installCheck reads to confirm `-e` is
    # still the exec flag upstream advertises.
    #
    # rmdir, not `rm -rf`: it fails loudly if upstream ever installs a SECOND
    # desktop entry, instead of silently swallowing it.
    mkdir -p "$out/share/velocitty"
    mv "$out/share/applications/velocitty.desktop" "$out/share/velocitty/velocitty.desktop"
    rmdir "$out/share/applications"
  '';

  # The package guards itself, the way modules/windscribe-app does, because
  # every failure above is invisible to a "does the file exist" check.
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck

    fail=0
    check() { if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1" >&2; fail=1; fi; }

    # The rpath is the whole ballgame: zig drives its own lld and never sees
    # the nixpkgs ld-wrapper, so nothing adds these automatically.
    check "every DT_NEEDED resolves" \
      '! ldd "$out/bin/velocitty" | grep -q "not found"'
    check "rpath names libxkbcommon (stub-linked, so a miss is fatal at runtime only)" \
      'patchelf --print-rpath "$out/bin/velocitty" | grep -q "${lib.getLib libxkbcommon}/lib"'
    check "rpath has no relative entry (CWD-dependent library search)" \
      '! patchelf --print-rpath "$out/bin/velocitty" | tr ":" "\n" | grep -q "^[^/]"'
    check "rpath does not drag the build-time X11 tree into the closure" \
      '! patchelf --print-rpath "$out/bin/velocitty" | grep -q "velocitty-x11-tree"'
    # Anti-vacuity for the postPatch: fails if the substitution matched but the
    # string never reached the binary, or if someone swaps in a PATH wrapper.
    check "fc-match is burned in as an absolute store path" \
      'grep -qF "${fontconfig}/bin/fc-match" "$out/bin/velocitty"'
    check "-e is still the exec flag upstream advertises" \
      'grep -qF "X-TerminalArgExec=-e" "$out/share/velocitty/velocitty.desktop"'
    # Anti-vacuity for the relocation: fails if a future zig build reinstalls
    # the entry, or if someone "tidies away" the mv above.
    check "no desktop entry in the XDG search path (velocitty is not a chooser candidate)" \
      '! test -e "$out/share/applications"'
    # The asymmetry the wrapper's shell --hold exists for: xdg-terminal-exec
    # honours --hold only via this key and silently does nothing without it.
    check "velocitty still declares no X-TerminalArgHold (so the wrapper must hold in shell)" \
      '! grep -q "X-TerminalArgHold" "$out/share/velocitty/velocitty.desktop"'
    check "man page installed" \
      'test -e "$out/share/man/man1/velocitty.1" -o -e "$out/share/man/man1/velocitty.1.gz"'

    [ "$fail" -eq 0 ] || { echo "velocitty: installCheck FAILED" >&2; exit 1; }

    runHook postInstallCheck
  '';

  meta = {
    description = "Lightning-fast CPU-rendered X11 terminal emulator";
    homepage = "https://github.com/valvesky/velocitty";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "velocitty";
  };
}
