{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  makeBinaryWrapper,
  undmg,
  # Runtime dependencies for Linux (sandbox networking, process tools).
  bubblewrap,
  procps,
  ripgrep,
  socat,
}:

let
  version = "0.1.0-dev.20260630.t212931.sha2bc1ac8";

  baseUrl = "https://downloads.claude.ai/claude-science/latest";

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
    [ makeBinaryWrapper ]
    ++ lib.optionals stdenv.isLinux [
      autoPatchelfHook
      bubblewrap
      procps
      ripgrep
      socat
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
        install -m755 "$src" "$out/bin/claude-science"

        wrapProgram "$out/bin/claude-science" \
          --set DISABLE_AUTOUPDATER 1 \
          --prefix PATH : "${lib.makeBinPath [ bubblewrap procps ripgrep socat ]}"

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
