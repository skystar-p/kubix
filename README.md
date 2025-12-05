# kubix

A Kubernetes manifest generator using Nix.

## Basic Usage

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

## Validating your manifests

All of your given manifests are strictly verified with JSON Schema. See this example.

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
      "wrong-property" = 12345; # This value should be a string, but it is a number!
    };
  };
}
```

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

What will happen when you build this?

```bash
nix build

# error: Cannot build '/nix/store/2djixn2avimz4g802mih2s628xkyymn0-validator.drv'.
#        Reason: builder failed with exit code 1.
#        Output paths:
#          /nix/store/140xlyahm4cr3m0bb0aid1wiznqh27cn-validator
#        Last 2 log lines:
#        > Error: "example-configmap.json": validation error at /data/wrong-property: 12345 is not of types "null", "string"
#        > Error: validation failed with 1 errors
#        For full logs, run:
#          nix log /nix/store/2djixn2avimz4g802mih2s628xkyymn0-validator.drv
```
