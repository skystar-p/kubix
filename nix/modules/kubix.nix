{
  pkgs,
  lib,
  config,
  flake,
  ...
}:
let
  cfg = config.kubix;

  schemasOption = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, config, ... }:
        let
          cfg = config;
          hasApiVersion = cfg.apiVersion != null;
          hasGroup = cfg.group != null;
          hasVersion = cfg.version != null;
        in
        {
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

          config = {
            assertions = [
              {
                assertion = hasApiVersion != (hasGroup || hasVersion);
                message = "Resource '${name}': Either 'apiVersion' OR 'group'/'version' must be specified, not both";
              }
              {
                assertion = hasGroup == hasVersion;
                message = "Resource '${name}': 'group' and 'version' must be specified together";
              }
              {
                assertion = hasApiVersion || (hasGroup && hasVersion);
                message = "Resource '${name}': Must specify either 'apiVersion' or both 'group' and 'version'";
              }
            ];
          };
        }
      )
    );
    description = "list of schemas to fetch and include";
    default = { };
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

    schemas = schemasOption;

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
    kubix = {
      result = validatorLib.output;
    };
  };
}
