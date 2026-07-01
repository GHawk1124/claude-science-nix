{
  bash,
  coreutils,
  lib,
  runCommand,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  undmg,
  # Runtime dependencies for Linux (sandbox networking, process tools).
  bubblewrap,
  procps,
  ripgrep,
  socat,
  # nix-ld and the libraries it serves to dynamically-linked binaries
  # running inside Claude Science's bwrap sandboxes.
  nix-ld,
  cacert,
  zlib,
  openssl,
  bzip2,
  curl,
  xz,
  libxml2,
  zstd,
  attr,
  acl,
  libsodium,
  libssh,
  util-linux,
}:

let
  version = "0.1.0-dev.20260630.t212931.sha2bc1ac8";

  baseUrl = "https://downloads.claude.ai/claude-science/latest";

  # Claude Science's bundled micromamba shells out via bubblewrap to a
  # hardcoded `/run/current-system/sw/bin/bash`, but that bwrap invocation
  # never binds /run, so the path can never exist inside the sandbox.
  # Claude Science actually discovers "bash" at runtime by scanning PATH
  # (skipping whichever directory its own internal shell — /bin/sh —
  # resolves through), so we hand it a bash + coreutils at a *different*
  # store path. The sandbox does bind /nix wholesale, so this is visible
  # inside it once picked up. See: strace of the bwrap argv showed `/run`
  # is never referenced anywhere except the unreachable exec target.
  sandboxShellShim =
    runCommand "claude-science-sandbox-shell-shim" { }
      ''
        mkdir -p $out/bin
        ln -s ${bash}/bin/bash $out/bin/bash
        ln -s ${bash}/bin/sh   $out/bin/sh
        for f in ${coreutils}/bin/*; do
          ln -s "$f" "$out/bin/$(basename "$f")"
        done
      '';

  # Libraries needed by dynamically-linked binaries running inside Claude
  # Science's sandbox.  Mirrors the default set from the NixOS
  # programs.nix-ld module so that conda/micromamba packages have their
  # shared library dependencies available without relying on the host's
  # programs.nix-ld configuration.
  baseLibraries = [
    zlib
    openssl
    bzip2
    stdenv.cc.cc
    curl
    xz
    libxml2
    zstd
    attr
    acl
    libsodium
    libssh
    util-linux
  ];

  # Symlink farm at $out/share/nix-ld/lib/ — all .so files from
  # baseLibraries plus ld.so → glibc's actual dynamic linker.
  nixLdLibraries = runCommand "claude-science-nix-ld-libraries"
    {
      libPaths = map (p: "${lib.getLib p}") baseLibraries;
    }
    ''
      mkdir -p $out/share/nix-ld/lib
      for pkg in $libPaths; do
        if [ -d "$pkg/lib" ]; then
          for f in "$pkg"/lib/*; do
            ln -sf "$f" "$out/share/nix-ld/lib/"
          done
        fi
      done
      ln -sf ${stdenv.cc.bintools.dynamicLinker} $out/share/nix-ld/lib/ld.so
    '';

  # Patched nix-ld with compile-time defaults that point at real /nix/store
  # paths instead of /run/current-system/sw/share/nix-ld/... .  This ensures
  # that even when Claude Science's bwrap sandbox does not pass the NIX_LD
  # env var through, nix-ld's fallback still finds the correct dynamic
  # linker and libraries.
  #
  # DEFAULT_NIX_LD is set via option_env!("DEFAULT_NIX_LD") at compile time
  # — overriding it as a derivation attribute injects it as a build env var.
  # DEFAULT_NIX_LD_LIBRARY_PATH is a hardcoded byte-string literal in
  # src/main.rs — we substitute it directly with the bundled library path.
  patchedNixLd = nix-ld.overrideAttrs (old: {
    DEFAULT_NIX_LD = "${nixLdLibraries}/share/nix-ld/lib/ld.so";
    postPatch = (old.postPatch or "") + ''
      substituteInPlace src/main.rs \
        --replace \
        'b"/run/current-system/sw/share/nix-ld/lib"' \
        'b"${nixLdLibraries}/share/nix-ld/lib"'
    '';
  });

  srcs = {
    "x86_64-linux" = fetchurl {
      url = "${baseUrl}/linux-x64";
      hash = "sha256-0Tdxuk6FyCfvSEdy0tUEWy2v/5Si1WnWVRDpN1+OKwY=";
    };
    "aarch64-darwin" = fetchurl {
      url = "${baseUrl}/mac-arm64.dmg";
      hash = "sha256-qw78WcVgvSG7HQSSWY9YiQa0Gmn/XiAL0HfYFqxLwvg=";
    };
    "x86_64-darwin" = fetchurl {
      url = "${baseUrl}/mac-x64.dmg";
      hash = "sha256-hWOHYAUa4th2T2a1iekflbEtO+QyPztHTNiY5VtAc98=";
    };
  };
in
stdenv.mkDerivation (finalAttrs: {
  inherit version;
  pname = "claude-science";

  src = builtins.getAttr stdenv.system srcs;

  # Linux: the source is the raw binary, no unpacking needed.
  # macOS: the source is a DMG; undmg setup hook extracts it during unpackPhase.
  dontUnpack = stdenv.isLinux;

  nativeBuildInputs =
    lib.optionals stdenv.isLinux [
      autoPatchelfHook
      bash
      bubblewrap
      coreutils
      procps
      ripgrep
      socat
      stdenv.cc.cc.lib
    ]
    ++ lib.optionals stdenv.isDarwin [ undmg ];

  # Stripping may corrupt the embedded Bun/JavaScript trailer, same as Claude Code.
  dontStrip = true;

  # macOS: undmg extracts to the build directory itself.
  sourceRoot = lib.optionalString stdenv.isDarwin ".";

  installPhase =
    if stdenv.isDarwin then
      ''
        runHook preInstall

        mkdir -p "$out/Applications"
        cp -R "Claude Science.app" "$out/Applications/"

        # Symlink the CLI binary so `claude-science` is on PATH.
        mkdir -p "$out/bin"
        ln -s \
          "$out/Applications/Claude Science.app/Contents/Resources/bin/claude-science" \
          "$out/bin/claude-science"

        runHook postInstall
      ''
    else
      ''
        runHook preInstall

        mkdir -p "$out/bin"
        install -m755 "$src" "$out/bin/.claude-science-wrapped"

        # A hand-written shell wrapper (rather than makeBinaryWrapper, whose
        # compiled wrappers can only set static, build-time-known env vars)
        # because $HOME and $PWD must be resolved fresh on every launch, and
        # the outer bwrap command embeds store paths from two derivations.
        cat > "$out/bin/claude-science" <<WRAPPER
#!${bash}/bin/sh
export DISABLE_AUTOUPDATER=1
export PATH="${lib.makeBinPath [ sandboxShellShim bash bubblewrap procps ripgrep socat ]}:\$PATH"
export LD_LIBRARY_PATH="${lib.makeLibraryPath [ stdenv.cc.cc.lib ]}:\$LD_LIBRARY_PATH"

# Claude Science's inner bwrap sandbox does --ro-bind /etc/ssl from the
# outer namespace, but /etc/ssl/certs/ca-certificates.crt on NixOS is a
# symlink through /etc/static/... that breaks inside the sandbox's tmpfs
# /etc.  Bind the real CA bundle file directly so it stays resolvable.
export SSL_CERT_FILE="${cacert}/etc/ssl/certs/ca-bundle.crt"
export CURL_CA_BUNDLE="${cacert}/etc/ssl/certs/ca-bundle.crt"

# --version and --help don't need a sandbox; skip the outer bwrap to
# avoid "bwrap: setting up uid map: Permission denied" in containerised
# environments (e.g. GitHub Actions runners) where user namespaces are
# disabled.
case "\$1" in
  --version|-V|--help|-h)
    exec "$out/bin/.claude-science-wrapped" "\$@"
    ;;
esac

# Outer bubblewrap: overlay patched nix-ld, bash, and CA certificates.
# Claude Science's inner bwrap binds /lib64, /bin, and /etc/ssl wholesale
# into its sandboxes, so whatever we place there is visible to both
# micromamba (env creation) and MCP server subprocesses.
#
# NixOS /bin only contains 'sh' — no 'bash' symlink — but MCP connectors
# launched by Claude Science's Python bridge use 'bwrap ... /bin/bash'.
# We shadow /bin with a tmpfs and symlink both sh and bash to the
# sandboxShellShim so both resolution paths work inside the inner sandbox.
exec ${bubblewrap}/bin/bwrap \
  --ro-bind / / \
  --tmpfs /lib64 \
  --ro-bind ${patchedNixLd}/libexec/nix-ld /lib64/ld-linux-x86-64.so.2 \
  --tmpfs /etc/ssl/certs \
  --ro-bind ${cacert}/etc/ssl/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt \
  --ro-bind ${cacert}/etc/ssl/certs/ca-bundle.crt /etc/ssl/certs/ca-bundle.crt \
  --tmpfs /bin \
  --symlink ${sandboxShellShim}/bin/sh /bin/sh \
  --symlink ${sandboxShellShim}/bin/bash /bin/bash \
  --bind /run /run \
  --bind /tmp /tmp \
  --bind "\$HOME" "\$HOME" \
  --proc /proc \
  --dev /dev \
  --chdir "\$PWD" \
  --die-with-parent \
  -- \
  "$out/bin/.claude-science-wrapped" "\$@"
WRAPPER
        chmod +x "$out/bin/claude-science"

        runHook postInstall
      '';

  meta = with lib; {
    description = "Claude Science — your research partner for rigorous science";
    longDescription = ''
      Claude Science is an AI-powered scientific workbench that runs analyses,
      searches databases, and traces every step from data wrangling to
      publication.  Supports persistent Python and R kernels, manages compute
      environments on your laptop, your cluster, or GPUs, and includes built-in
      renderers for proteins, structures, molecules, alignments, genomic
      tracks, chemical structures, and PDFs.
    '';
    homepage = "https://claude.com/product/claude-science";
    license = licenses.unfree;
    mainProgram = "claude-science";
    platforms = [ "x86_64-linux" "aarch64-darwin" "x86_64-darwin" ];
    maintainers = [ ];
  };
})
