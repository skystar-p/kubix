{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.kubix;

  schemasOption = lib.mkOption {
    type = lib.types.listOf (
      lib.types.submodule {
        options = {
          apiVersion = lib.mkOption {
            type = lib.types.str;
            default = null;
            description = "apiVersion of the schema";
          };

          kind = lib.mkOption {
            type = lib.types.addCheck lib.types.str (s: s != "");
            description = "kind of the schema";
          };

          url = lib.mkOption {
            type = lib.types.str;
            description = "url to the json schema file";
          };

          hash = lib.mkOption {
            type = lib.types.str;
            description = "hash of the json schema file";
          };
        };
      }
    );
    description = "list of schemas to fetch and include";
    default = [ ];
  };

  crdsOption = lib.mkOption {
    type = lib.types.listOf (
      lib.types.submodule {
        options = {
          url = lib.mkOption {
            type = lib.types.str;
            description = "url to the crd file";
          };
          hash = lib.mkOption {
            type = lib.types.str;
            description = "hash of the crd file";
          };
        };
      }
    );
    description = "list of crds to fetch and include";
    default = [ ];
  };

  helmChartsOption = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          repo = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            description = "helm repo url";
          };

          chartName = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            description = "helm chart name";
          };

          chartVersion = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            description = "helm chart version";
          };

          hash = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            description = "helm chart package hash";
          };

          pullExtraArgs = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description = "extra arguments to pass to helm pull command";
            default = [ ];
          };

          localChartPath = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            description = "optional local path to helm chart. if set, repo, chartName, chartVersion and hash are ignored.";
          };

          namespace = lib.mkOption {
            type = lib.types.str;
            description = "kubernetes namespace to deploy the helm chart into";
          };

          values = lib.mkOption {
            type = lib.types.attrs;
            description = "helm chart values";
            default = { };
          };

          includeCRDs = lib.mkOption {
            type = lib.types.bool;
            description = "whether to include CRDs from the chart";
            default = false;
          };

          kubeVersion = lib.mkOption {
            type = lib.types.str;
            description = "target kubernetes version for the helm chart";
            default = cfg.kubernetesVersion;
          };

          apiVersions = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description = "list of apiVersions to enable in the helm chart";
            default = [ ];
          };

          extraArgs = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description = "extra arguments to pass to helm template command";
            default = [ ];
          };
        };
      }
    );
    description = "helm charts definition";
    default = { };
  };

  validatorLib = import ../lib/validator.nix {
    inherit
      pkgs
      lib
      config
      ;
  };
in
{
  options.kubix = {
    enable = lib.mkEnableOption "Enable kubix module";

    kubernetesVersion = lib.mkOption {
      type = lib.types.str;
      description = "kubernetes version to target. used for selecting appropriate predefined schemas.";
      default = "1.34";
    };

    schemas = schemasOption;

    crds = crdsOption;

    manifests = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          freeformType = lib.types.attrs;
          options = {
            apiVersion = lib.mkOption {
              type = lib.types.str;
              description = "apiVersion of the manifest";
            };
            kind = lib.mkOption {
              type = lib.types.str;
              description = "kind of the manifest";
            };
          };
        }
      );
      description = "manifests definition";
      default = { };
    };

    helmCharts = helmChartsOption;

    result = lib.mkOption {
      type = lib.types.package;
      description = "validated manifest result";
    };
  };

  config = lib.mkIf cfg.enable {
    kubix.result = validatorLib.output;
  };
}
