{
  lib,
  rustPlatform,
  clippy,
}:
rustPlatform.buildRustPackage {
  pname = "kiss-cache";
  version = (lib.importTOML ./Cargo.toml).package.version;
  src = lib.cleanSource ./.;
  cargoLock.lockFile = ./Cargo.lock;
  nativeCheckInputs = [ clippy ];
  # Benches are not built or linted in CI: criterion is only useful
  # interactively, and building it doubles the dependency closure.
  cargoTestFlags = [
    "--lib"
    "--bins"
    "--tests"
  ];
  postCheck = ''
    cargo clippy --lib --bins --tests -- \
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
