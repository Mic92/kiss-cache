{
  lib,
  rustPlatform,
  clippy,
}:
rustPlatform.buildRustPackage {
  pname = "kiss-cache";
  version = (lib.importTOML ./Cargo.toml).package.version;
  # Only the Rust sources affect the binary; pruning README/nixos/etc.
  # means doc and test changes do not invalidate the build cache.
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Cargo.toml
      ./Cargo.lock
      ./src
      ./tests
      ./benches
    ];
  };
  cargoLock.lockFile = ./Cargo.lock;
  nativeCheckInputs = [ clippy ];
  # Build only the kiss-cache package: the benches workspace member pulls
  # in criterion, which is only useful interactively.
  cargoBuildFlags = [
    "-p"
    "kiss-cache"
  ];
  cargoTestFlags = [
    "-p"
    "kiss-cache"
  ];
  postCheck = ''
    cargo clippy -p kiss-cache --all-targets -- \
      -D clippy::pedantic \
      -D warnings \
      -A clippy::module-name-repetitions \
      -A clippy::too-many-lines \
      -A clippy::cast-possible-wrap \
      -A clippy::cast-possible-truncation
  '';
  meta = {
    description = "Trim Nix binary caches according to GC roots";
    license = lib.licenses.mit;
    mainProgram = "kiss-cache";
  };
}
