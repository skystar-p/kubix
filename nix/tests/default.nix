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
