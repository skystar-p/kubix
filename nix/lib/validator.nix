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
      name = "${k}.json";
      path = pkgs.writeText k (builtins.toJSON v);
    }) config.kubix.manifests
  );

  predefinedSchemas =
    if builtins.pathExists ../lib/schemas/${config.kubix.kubernetesVersion}.nix then
      import ../lib/schemas/${config.kubix.kubernetesVersion}.nix
    else
      builtins.trace (
        "warning: no predefined schemas found for Kubernetes version ${config.kubix.kubernetesVersion}. please make sure to define all required schemas in config.kubix.schemas."
      ) [ ];

  userManifestTypes = lib.unique (
    lib.mapAttrsToList (_: manifest: { inherit (manifest) apiVersion kind; }) config.kubix.manifests
  );

  userSchemaTypes = lib.map (schema: {
    apiVersion = schema.apiVersion;
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
      apiVersion = schema.apiVersion;
      kind = schema.kind;
      url = schema.url;
      hash = schema.hash;
    }) filteredPredefinedSchemas)
  ];

  schemaDir = pkgs.runCommand "schema-dir" { } (
    lib.concatStringsSep "\n" (
      [ "mkdir -p $out" ]
      ++ lib.map (
        v:
        let
          normalizedApiVersion = lib.replaceStrings [ "/" ] [ "_" ] v.apiVersion;
        in
        ''
          mkdir -p "$out/${normalizedApiVersion}"
          cp "${fetch v}" "$out/${normalizedApiVersion}/${v.kind}.json"
        ''
      ) allSchemas
    )
  );

  crdDir = pkgs.runCommand "crd-dir" { nativeBuildInputs = [ pkgs.yq-go ]; } (
    lib.concatStringsSep "\n" (
      [ "mkdir -p $out" ]
      ++ lib.imap0 (i: v: ''
        yq -o=json '.' "${fetch v}" > "$out/crd-${toString i}.json"
      '') config.kubix.crds
    )
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
