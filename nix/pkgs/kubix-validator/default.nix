{
  rustPlatform,
  nix-gitignore,
}:

rustPlatform.buildRustPackage {
  pname = "kubix-validator";
  version = "1.0.0";
  src = nix-gitignore.gitignoreSource [ ] ../../../validator;

  cargoLock = {
    lockFile = ../../../validator/Cargo.lock;
  };
}
