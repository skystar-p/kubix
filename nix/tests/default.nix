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
  configMapTest = mkModuleTest {
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

  certManagerCertificate = mkModuleTest {
    schemas = [
      {
        apiVersion = "cert-manager.io/v1";
        kind = "Certificate";
        url = "https://raw.githubusercontent.com/datreeio/CRDs-catalog/6f4f838cdf656cef2fbc1792361f28af2740f705/cert-manager.io/certificate_v1.json";
        hash = "sha256-P7hXYDA7zqstFpIjcMW1E1AyINiWVnbz4qE44MIY8Ac=";
      }
    ];
    manifests = {
      example-certificate = {
        apiVersion = "cert-manager.io/v1";
        kind = "Certificate";
        metadata = {
          name = "example-com-tls";
          namespace = "default";
        };
        spec = {
          secretName = "example-com-tls";
          dnsNames = [ "example.com" ];
          issuerRef = {
            name = "letsencrypt-prod";
            kind = "ClusterIssuer";
          };
        };
      };
    };
  };
}
