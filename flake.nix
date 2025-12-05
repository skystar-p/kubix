{
  description = "kubix, the Kubernetes manifest generator";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      flake-parts,
      fenix,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      flake = {
        nixosModules.kubix = ./nix/modules/kubix.nix;
      };

      systems = [
        "x86_64-linux"
        "x86_64-darwin"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      perSystem =
        {
          pkgs,
          lib,
          system,
          ...
        }:
        let
          rust-toolchain = fenix.packages.${system}.fromToolchainFile {
            file = ./validator/rust-toolchain.toml;
            sha256 = "sha256-SDu4snEWjuZU475PERvu+iO50Mi39KVjqCeJeNvpguU=";
          };

          rustPlatform = pkgs.makeRustPlatform {
            cargo = rust-toolchain;
            rustc = rust-toolchain;
          };
        in
        {
          _module.args.flake = self;
          packages = {
            kubix-validator = pkgs.callPackage ./nix/pkgs/kubix-validator.nix { inherit rustPlatform; };
          };

          devShells.default = pkgs.mkShell {
            nativeBuildInputs = [
              rust-toolchain
            ];
          };

          checks = import ./nix/tests {
            inherit pkgs lib;
            flake = self;
          };
        };
    };
}
