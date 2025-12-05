{
  pkgs,
  lib,
  flake,
  ...
}:
let
  mkModuleTest =
    testConfig:
    let
      eval = lib.evalModules {
        modules = [
          ../modules/kubix.nix
          {
            _module.args = {
              inherit pkgs lib flake;
              config = { };
            };
          }
          {
            kubix = (
              {
                enable = true;
              }
              // testConfig
            );
          }
        ];
      };
    in
    eval.config.kubix.result;
in
{
  manifestTest = mkModuleTest {
    schemas = [
      {
        apiVersion = "v1";
        kind = "ConfigMap";
        url = "https://raw.githubusercontent.com/yannh/kubernetes-json-schema/refs/heads/master/master-standalone/configmap-v1.json";
        hash = "";
      }
    ];
    manifests = {
      example-configmap = {
        apiVersion = "v1";
        kind = "ConfigMap";
        metadata = {
          name = "example-configmap";
          namespace = "default";
        };
        stringData = {
          "example.property.1" = "value1";
          "example.property.2" = "value2";
        };
      };
    };
  };
}
