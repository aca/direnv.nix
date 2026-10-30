{
  lib,
  stdenv,
  zig_0_17,
  python3,
  bash,
  zsh,
  elvish,
  fish,
  coreutils,
}:
stdenv.mkDerivation {
  pname = "direnv.nix";
  version = "0.1.0-dev";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./build.zig
      ./src
      ./LICENSE
      (lib.fileset.fileFilter (file: file.hasExt "py") ./tests)
    ];
  };

  nativeBuildInputs = [ zig_0_17 ];
  nativeCheckInputs = [
    python3
    bash
    zsh
    elvish
    fish
    coreutils
  ];
  dontConfigure = true;
  # Own the phases: the Zig setup hook's default flags target other build files.
  buildPhase = ''
    runHook preBuild
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
    export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
    zig build -Drelease=true -Dcpu=baseline -j$NIX_BUILD_CORES
    runHook postBuild
  '';

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    zig build test -j$NIX_BUILD_CORES
    python3 tests/integration.py
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 zig-out/bin/direnv "$out/bin/direnv"
    install -Dm644 LICENSE "$out/share/licenses/direnv.nix/LICENSE"
    runHook postInstall
  '';

  meta = {
    description = "Small cached Nix environment loader for Bash, Zsh, Fish and Elvish";
    homepage = "https://github.com/aca/direnv.nix";
    mainProgram = "direnv";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
