{
  pkgs,
  lib,
  config,
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
in
{

  output =
    pkgs.runCommand "validator"
      {
        env = { inherit manifestDir crdDir schemaDir; };
        nativeBuildInputs = [ ];
      }
      ''
        TODO
      '';
}
