{
  self,
  pkgs,
  ...
}:
let
  buildManifests = self.lib.buildManifests pkgs.system;
  helmValue = self.lib.helmValue;
in
{
  simpleConfigMap = buildManifests {
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

  certManagerCertificate = buildManifests {
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

  certManagerCertificateWithCrd = buildManifests {
    crds = [
      {
        url = "https://raw.githubusercontent.com/cert-manager/cert-manager/02d1e1985e5c94059c5a2c3653b3d98c27a9c8f9/deploy/crds/cert-manager.io_certificates.yaml";
        hash = "sha256-c73XIW4DLjSCF5aKb02E6FqOdwkGEklWgGFpHXljHxA=";
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

  simpleHelmChart = buildManifests {
    helmCharts = {
      cert-manager = {
        repo = "https://charts.jetstack.io";
        chartName = "cert-manager";
        chartVersion = "v1.19.1";
        hash = "sha256-fs14wuKK+blC0l+pRfa//oBV2X+Dr3nNX+Z94nrQVrA=";

        namespace = "cert-manager";
        values = {
          crds.enabled = true;
        };
      };
    };

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

  simpleConfigMapWithHelmValue = buildManifests {
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
          "example.property.3" = helmValue [ "test" "property" ] "defaultValue";
        };
      };
    };

    outputType = {
      type = "helm";

      helmOptions = {
        name = "example-chart";
      };
    };
  };
}
