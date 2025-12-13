{
  pkgs,
  lib,
  config,
  ...
}:

let
  generator = import ./generator.nix { inherit pkgs lib config; };
  inherit (generator)
    crdDir
    schemaDir
    allManifests
    helmOutput
    ;

  useHelmOutput = config.kubix.outputType.type == "helm";
  useHelmTarball = useHelmOutput && config.kubix.outputType.helmOptions.tarball or false;
  validatorPkg = pkgs.callPackage ../pkgs/kubix-validator { };
in
{
  output =
    pkgs.runCommand "kubix-manifests"
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

        ${
          if useHelmOutput then
            if useHelmTarball then
              ''
                cp ${helmOutput} $out
              ''
            else
              ''
                mkdir -p $out
                cp -r ${helmOutput}/. $out
              ''
          else
            ''
              mkdir -p $out
              cp -r $manifestDir/. $out/
            ''
        }
      '';
}
