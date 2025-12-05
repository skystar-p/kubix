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
      lib.types.submodule ({
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
            description = "url to the crd file";
          };

          hash = lib.mkOption {
            type = lib.types.str;
            description = "hash of the crd file";
          };
        };
      })
    );
    description = "list of schemas to fetch and include";
    default = [ ];
  };

  crdOptions = {
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

    crds = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule crdOptions);
      description = "list of crds to fetch and include";
      default = { };
    };

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

    result = lib.mkOption {
      type = lib.types.package;
      description = "validated manifest result";
    };
  };

  config = lib.mkIf cfg.enable {
    kubix.result = validatorLib.output;
  };
}
