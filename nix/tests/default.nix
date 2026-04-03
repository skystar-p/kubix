{
  self,
  pkgs,
  ...
}:
let
  buildManifests = self.lib.buildManifests pkgs.stdenv.hostPlatform.system;
  helmValue = self.lib.helmValue;
  helmValueToJson = self.lib.helmValueToJson;
  helmTemplate = self.lib.helmTemplate;
  fixturesDir = ./fixtures;
  mkManifestCheck =
    {
      name,
      result,
      manifestName,
      fixture,
    }:
    pkgs.runCommand "check-${name}"
      {
        nativeBuildInputs = [
          pkgs.diffutils
          pkgs.jq
        ];
      }
      ''
        set -euo pipefail
        test -f ${result}/${manifestName}.json
        jq -S . ${fixture} > "$TMPDIR/expected.json"
        jq -S . ${result}/${manifestName}.json > "$TMPDIR/actual.json"
        diff -u "$TMPDIR/expected.json" "$TMPDIR/actual.json"
        touch $out
      '';
  mkHelmTemplateCheck =
    {
      name,
      result,
      values,
      expectedFixtures,
    }:
    let
      valuesFile = pkgs.writeText "values.json" (builtins.toJSON values);
    in
    pkgs.runCommand "check-${name}"
      {
        nativeBuildInputs = [
          pkgs.diffutils
          pkgs.jq
          pkgs.kubernetes-helm
          pkgs.yq-go
        ];
      }
      ''
        set -euo pipefail
        helm template example-chart ${result} -f ${valuesFile} \
          | yq --output-format=json --split-exp='"\(env(TMPDIR))/\(.apiVersion)-\(.kind)-\(.metadata.namespace)-\(.metadata.name).json"'
        shopt -s nullglob
        for actual in "$TMPDIR"/*.json; do
          base="$(basename "$actual")"
          expected="${expectedFixtures}/$base"
          if [ ! -f "$expected" ]; then
            echo "missing expected fixture: $expected" >&2
            exit 1
          fi
          diff -u <(jq -S . "$expected") <(jq -S . "$actual")
        done
        for expected in ${expectedFixtures}/*.json; do
          base="$(basename "$expected")"
          if [ ! -f "$TMPDIR/$base" ]; then
            echo "missing actual render: $base" >&2
            exit 1
          fi
        done
        touch $out
      '';
in
rec {
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
          annotations = helmValueToJson [ "test" "annotations" ] {
            foo = "bar";
            bar = "baz";
          };
        };
        data = {
          "example.property.1" = "value1";
          "example.property.2" = "value2";
          "example.property.3" = helmValue [ "test" "property" ] "defaultValue";
          "example.property.4" = helmTemplate [
            (helmValue [
              "test"
              "property"
            ] "defaultValue")
            "-"
            (helmValue [
              "another"
              "property"
            ] "anotherDefault")
          ];
          # nested helm template
          "example.property.5" = helmTemplate [
            (helmTemplate [
              (helmValue [ "test" "property" ] "defaultValue")
              "-"
              (helmValue [ "test" "property" ] "anotherDefault")
            ])
            "-"
            (helmValue [
              "another"
              "property"
            ] "anotherDefault")
          ];
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

  parseCrdOfMultipleDocuments = buildManifests {
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
        };
      };
    };

    crds = [
      {
        path = pkgs.writeText "crd.yaml" ''
          apiVersion: apiextensions.k8s.io/v1
          kind: CustomResourceDefinition
          metadata:
            name: a
          ---
          apiVersion: apiextensions.k8s.io/v1
          kind: CustomResourceDefinition
          metadata:
            name: b
        '';
      }
    ];
  };

  simpleConfigMapCheck = mkManifestCheck {
    name = "simple-configmap";
    result = simpleConfigMap;
    manifestName = "example-configmap";
    fixture = "${fixturesDir}/simple-configmap.json";
  };

  certManagerCertificateCheck = mkManifestCheck {
    name = "cert-manager-certificate";
    result = certManagerCertificate;
    manifestName = "example-certificate";
    fixture = "${fixturesDir}/cert-manager-certificate.json";
  };

  simpleConfigMapWithHelmValueCheck = mkHelmTemplateCheck {
    name = "simple-configmap-helm";
    result = simpleConfigMapWithHelmValue;
    values = {
      test = {
        property = "customValue";
        annotations = {
          foo = "from-helm";
          bar = "baz";
        };
      };
      another.property = "otherValue";
    };
    expectedFixtures = "${fixturesDir}/simple-configmap-helm/";
  };
}
