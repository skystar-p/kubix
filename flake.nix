{
  description = "kubix, the Kubernetes manifest generator";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs =
    {
      self,
      nixpkgs,
      ...
    }:
    let
      forAllSystems =
        function:
        nixpkgs.lib.genAttrs [
          "x86_64-linux"
          "x86_64-darwin"
          "aarch64-linux"
          "aarch64-darwin"
        ] (system: function nixpkgs.legacyPackages.${system});
    in
    {
      nixosModules = {
        kubix = import ./nix/modules/kubix.nix;
      };

      packages = forAllSystems (pkgs: {
        kubix-validator = pkgs.callPackage ./nix/pkgs/kubix-validator { };
      });

      lib.buildManifests =
        system: kubixConfig:
        let
          pkgs = import nixpkgs { inherit system; };
          eval = pkgs.lib.evalModules {
            modules = [
              { _module.args = { inherit pkgs; }; }
              self.nixosModules.kubix
              {
                kubix = {
                  enable = true;
                }
                // kubixConfig;
              }
            ];
          };
        in
        eval.config.kubix.result;

      lib.evalModules =
        { system, modules }:
        let
          pkgs = import nixpkgs { inherit system; };
          eval = pkgs.lib.evalModules {
            specialArgs = {
              inherit pkgs;
              kubix = self;
            };
            modules = [
              {
                kubix = {
                  enable = true;
                };
              }
              self.nixosModules.kubix
            ]
            ++ modules;
          };
        in
        eval.config.kubix.result;

      lib.helmValue = path: default: { __kubixHelmValue = { inherit path default; }; };
      lib.helmTemplate = parts: { __kubixHelmTemplate = { inherit parts; }; };
      lib.helmType =
        let
          lib = nixpkgs.lib;
        in
        lib.mkOptionType {
          name = "kubixHelm";
          check = self.lib.isHelmType;
          merge = lib.mergeEqualOption;
        };
      lib.helmTypeOr = type: nixpkgs.lib.types.either self.lib.helmType type;
      lib.isHelmType =
        let
          isHelmValue =
            value:
            let
              helmValue = value.__kubixHelmValue;
            in
            builtins.isAttrs value
            && builtins.hasAttr "__kubixHelmValue" value
            && builtins.isAttrs helmValue
            && builtins.hasAttr "path" helmValue
            && builtins.isList helmValue.path
            && builtins.all builtins.isString helmValue.path
            && builtins.hasAttr "default" helmValue;
          isHelmTemplate =
            value:
            let
              helmTemplate = value.__kubixHelmTemplate;
            in
            builtins.isAttrs value
            && builtins.hasAttr "__kubixHelmTemplate" value
            && builtins.isAttrs helmTemplate
            && builtins.hasAttr "parts" helmTemplate
            && builtins.isList helmTemplate.parts
            && builtins.all (part: (builtins.isString part) || isHelmValue part) helmTemplate.parts;
        in
        value: isHelmValue value || isHelmTemplate value;

      checks = forAllSystems (pkgs: (import ./nix/tests { inherit self pkgs; }));
    };

}
