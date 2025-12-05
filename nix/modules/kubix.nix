{
  pkgs,
  lib,
  config,
  flake,
  ...
}:
let
  cfg = config.kubix;

  schemaOptions = {
    options = {
      apiVersion = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "apiVersion of the schema";
      };

      group = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "group of the schema";
      };

      version = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "version of the schema";
      };

      kind = lib.mkOption {
        type = lib.types.str;
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
      flake
      ;
  };
in
{
  options.kubix = {
    enable = lib.mkEnableOption "Enable kubix module";

    schemas = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule schemaOptions);
      description = "list of json schemas to fetch and include";
      default = { };
    };

    crds = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule crdOptions);
      description = "list of crds to fetch and include";
      default = { };
    };

    manifests = lib.mkOption {
      type = lib.types.attrsOf lib.types.attrs;
      description = "manifests definition";
      default = { };
    };

    result = lib.mkOption {
      type = lib.types.package;
      description = "validated manifest result";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = (cfg.apiVersion != null) != (cfg.group != null || cfg.version != null);
        message = "Either 'apiVersion' OR both 'group' and 'version' must be specified, not both";
      }
      {
        assertion = (cfg.group != null) == (cfg.version != null);
        message = "'group' and 'version' must be specified together";
      }
      {
        assertion = cfg.apiVersion != null || (cfg.group != null && cfg.version != null);
        message = "Must specify either 'apiVersion' or both 'group' and 'version'";
      }
    ];

    kubix = {
      result = validatorLib.output;
    };
  };
}
