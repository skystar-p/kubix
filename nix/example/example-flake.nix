{
  description = "sample flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    kubix.url = "github:skystar-p/kubix";
  };

  outputs =
    inputs@{
      nixpkgs,
      flake-parts,
      kubix,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ ];

      systems = [
        "x86_64-linux"
        "x86_64-darwin"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      perSystem =
        { pkgs, lib, ... }:
        {
          packages.default = kubix.lib.buildManifests pkgs {
            schemas = [
              {
                apiVersion = "v1";
                kind = "ConfigMap";
                url = "https://raw.githubusercontent.com/yannh/kubernetes-json-schema/refs/heads/master/master-standalone-strict/configmap-v1.json";
                hash = "sha256-4Ord69Z3wIqgkrLaImTYasT8NO7RErn6wpRbPwDB6bE=";
              }
            ];
            manifests = {
              example-configmap = {
                apiVersion = "v1";
                kind = "ConfigMap";
                metadata = {
                  name = "example-configmap";
                  namespace = "default";
                };
                data = {
                  "example.property.1" = "value1";
                  "example.property.2" = "value2";
                };
              };
            };
          };
        };
    };
}
