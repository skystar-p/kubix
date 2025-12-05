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

  predefinedSchemas = import ../lib/schemas/${config.kubix.kubernetesVersion}.nix;

  userManifestTypes = lib.unique (
    lib.mapAttrsToList (_: manifest: { inherit (manifest) apiVersion kind; }) config.kubix.manifests
  );

  userSchemaTypes = lib.map (schema: {
    apiVersion = schema.resolvedApiVersion;
    kind = schema.kind;
  }) config.kubix.schemas;

  filteredPredefinedSchemas = lib.filter (
    schema:
    (
      # filter schemas that are actually used in manifests
      builtins.any (
        manifestType: schema.apiVersion == manifestType.apiVersion && schema.kind == manifestType.kind
      ) userManifestTypes
      # and not overridden by user-defined schemas
      && !builtins.any (
        schemaType: schema.apiVersion == schemaType.apiVersion && schema.kind == schemaType.kind
      ) userSchemaTypes
    )
  ) predefinedSchemas;

  allSchemas = lib.concatLists [
    config.kubix.schemas
    (lib.map (schema: {
      apiVersion = schema.resolvedApiVersion;
      resolvedApiVersion = schema.apiVersion;
      kind = schema.kind;
      url = schema.url;
      hash = schema.hash;
    }) filteredPredefinedSchemas)
  ];

  schemaDir = pkgs.runCommand "schema-dir" { } (
    lib.concatStringsSep "\n" (
      [ "mkdir -p $out" ]
      ++ lib.map (v: ''
        mkdir -p "$out/${v.resolvedApiVersion}"
        cp "${fetch v}" "$out/${v.resolvedApiVersion}/${v.kind}.json"
      '') allSchemas
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
