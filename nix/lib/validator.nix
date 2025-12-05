{
  pkgs,
  lib,
  config,
  flake,
  ...
}:
let
  fetchSchema = { url, hash }: pkgs.fetchurl { inherit url hash; };

  manifestDir = pkgs.linkFarm "manifest-dir" (
    lib.mapAttrsToList (k: v: {
      name = k;
      path = pkgs.writeText k (builtins.toJSON v);
    }) config.kubix.manifests
  );

  crdDir = pkgs.linkFarm "crd-dir" (
    lib.mapAttrsToList (k: v: {
      name = k;
      path = fetchSchema v;
    }) config.kubix.crds
  );

  schemaDir = pkgs.linkFarm "schema-dir" (
    lib.mapAttrsToList (k: v: {
      name = k;
      path = fetchSchema v;
    }) config.kubix.schemas
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
        cp -r $crdDir/. $out/crds/
        cp -r $schemaDir/. $out/schemas/

        kubix-validator \
          --manifest-dir $out/manifests \
          --crd-dir $out/crds
      '';
}
