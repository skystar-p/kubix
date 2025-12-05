{
  pkgs,
  lib,
  config,
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
      [ "mkdir -p $out" ]
      ++ lib.map (v: ''
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

  validatorPkg = pkgs.callPackage ../pkgs/kubix-validator { };
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
        tempDir=$(mktemp -d)
        mkdir -p $tempDir/{manifests,crds,schemas}
        cp -r $manifestDir/. $tempDir/manifests/
        cp -r $schemaDir/. $tempDir/schemas/
        cp -r $crdDir/. $tempDir/crds/

        kubix-validator \
          --manifest-dir $tempDir/manifests \
          --schema-dir $tempDir/schemas \
          --crd-dir $tempDir/crds

        mkdir -p $out
        cp -r $manifestDir/. $out/
      '';
}
