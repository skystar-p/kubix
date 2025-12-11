{
  description = "kubix, the Kubernetes manifest generator";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs@{
      nixpkgs,
      flake-parts,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      flake = {
        nixosModules.kubix = ./nix/modules/kubix.nix;

        lib.buildManifests =
          system: kubixConfig:
          let
            pkgs = import nixpkgs { inherit system; };
            lib = pkgs.lib;
            eval = lib.evalModules {
              modules = [
                ./nix/modules/kubix.nix
                {
                  _module.args = {
                    inherit pkgs lib;
                  };
                }
                {
                  kubix = {
                    enable = true;
                  }
                  // kubixConfig;
                }
              ];
            };
          in
          eval.config.kubix.result;
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
        {
          packages = {
            kubix-validator = pkgs.callPackage ./nix/pkgs/kubix-validator { };
          };

          checks = import ./nix/tests {
            inherit pkgs lib;
          };
        };
    };
}
