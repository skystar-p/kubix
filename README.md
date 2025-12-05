# kubix

A Kubernetes manifest generator using Nix.

## Usage

Write your Kubernetes manifest with your familiar Nix language, like this.

```nix
# manifest.nix
{
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
}
```

and use it in your flake.
```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    kubix.url = "github:skystar-p/kubix";
  };

  outputs = inputs@{ nixpkgs, flake-parts, kubix, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "x86_64-darwin" "aarch64-linux" "aarch64-darwin" ];

      perSystem = { pkgs, lib, ... }: {
        # use `kubix.lib.buildManifests` to verify the manifest and produce output!
        packages.default = kubix.lib.buildManifests pkgs {
          manifests = import ./manifest.nix;
        };
      };
    };
}
```

...and build.

```bash
nix build
# during build process, all manifests are strictly checked with JSON schema.

ls -al ./result
# lrwxrwxrwx - root  1 Jan  1970 example-configmap.json -> /nix/store/wcz3zsj4r22hsk7ip32w9d89aa38lahc-example-configmap

# you can safely apply the output.
cd ./result
kubectl apply -f .
```
