{
  pkgs,
  lib,
  config,
  ...
}:
let
  generator = import ./generator.nix { inherit pkgs lib config; };
  crdDir = generator.crdDir;
  schemaDir = generator.schemaDir;
  allManifests = generator.allManifests;

  validatorPkg = pkgs.callPackage ../pkgs/kubix-validator { };
in
{
  output =
    pkgs.runCommand "validator"
      {
        env = {
          inherit crdDir schemaDir;
          manifestDir = allManifests;
        };
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
