{
  pkgs,
  lib,
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
              inherit pkgs lib;
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
        url = "https://raw.githubusercontent.com/yannh/kubernetes-json-schema/refs/heads/master/master-standalone-strict/configmap-v1.json";
        hash = "sha256-4Ord69Z3wIqgkrLaImTYasT8NO7RErn6wpRbPwDB6bE=";
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
        data = {
          "example.property.1" = "value1";
          "example.property.2" = "value2";
        };
      };
    };
  };
}
