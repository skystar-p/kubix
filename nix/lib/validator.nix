{
  pkgs,
  lib,
  config,
  flake,
  ...
}:
let
  fetch = { url, hash, ... }: pkgs.fetchurl { inherit url hash; };

  manifestDir = pkgs.linkFarm "manifest-dir" (
    lib.mapAttrsToList (k: v: {
      name = k;
      path = pkgs.writeText k (builtins.toJSON v);
    }) config.kubix.manifests
  );

  schemaDir = pkgs.runCommand "schema-dir" { } (
    lib.concatStringsSep "\n" (
      [ "mkdir -p $out" ] ++
      lib.map (v: ''
        mkdir -p "$out/${v.resolvedApiVersion}"
        cp "${fetch v}" "$out/${v.resolvedApiVersion}/${v.kind}.json"
      '') config.kubix.schemas
    )
  );

  crdDir = pkgs.linkFarm "crd-dir" (
    lib.mapAttrsToList (k: v: {
      name = k;
      path = fetch v;
    }) config.kubix.crds
  );

  validatorPkg = flake.packages.${pkgs.system}.kubix-validator;
in
{

  output =
    pkgs.runCommand "validator"
      {
        env = { inherit manifestDir crdDir schemaDir; };
        nativeBuildInputs = [ validatorPkg ];
      }
      ''
        set -euo pipefail
        mkdir -p $out/{manifests,crds,schemas}
        cp -r $manifestDir/. $out/manifests/
        cp -r $schemaDir/. $out/schemas/
        cp -r $crdDir/. $out/crds/

        kubix-validator \
          --manifest-dir $out/manifests \
          --schema-dir $out/schemas \
          --crd-dir $out/crds
      '';
}
