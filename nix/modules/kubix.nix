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
      lib.types.submodule (
        { name, config, ... }:
        let
          cfg = config;
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
              type = lib.types.addCheck lib.types.str (s: s != "");
              description = "kind of the schema";
            };

            resolvedApiVersion = lib.mkOption {
              type = lib.types.str;
              readOnly = true;
              default = if cfg.apiVersion != null then cfg.apiVersion else "${cfg.group}/${cfg.version}";
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
        }
      )
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
    kubix.result =
      let
        validateSchemas = lib.imap0 (
          i: schema:
          let
            hasApiVersion = schema.apiVersion != null;
            hasGroup = schema.group != null;
            hasVersion = schema.version != null;
          in
          lib.throwIf (!(hasApiVersion != (hasGroup || hasVersion)))
            "Schema ${toString i}: Either 'apiVersion' OR 'group'/'version' must be specified, not both"
            (
              lib.throwIf (!(hasGroup == hasVersion))
                "Schema ${toString i}: 'group' and 'version' must be specified together"
                (
                  lib.throwIf (
                    !(hasApiVersion || (hasGroup && hasVersion))
                  ) "Schema ${toString i}: Must specify either 'apiVersion' or both 'group' and 'version'" schema
                )
            )
        ) cfg.schemas;
      in
      builtins.seq (builtins.deepSeq validateSchemas null) validatorLib.output;
  };
}
