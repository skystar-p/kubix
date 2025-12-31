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

      checks = forAllSystems (pkgs: (import ./nix/tests { inherit self pkgs; }));
    };

}
