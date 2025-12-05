{
  pkgs,
  lib,
  config,
  flake,
  ...
}:
let
  cfg = config.kubix;

  fetchableOptions = {
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

    crds = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule fetchableOptions);
      description = "list of crds to fetch and include";
      default = { };
    };

    schemas = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule fetchableOptions);
      description = "list of json schemas to fetch and include";
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

  config = {
    kubix = lib.mkIf cfg.enable {
      result = validatorLib.output;
    };
  };
}
