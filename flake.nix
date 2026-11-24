{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flakever.url = "github:numinit/flakever";
    treefmt-nix.url = "github:numtide/treefmt-nix";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-parts,
      flakever,
      treefmt-nix,
      ...
    }@inputs:
    let
      inherit (nixpkgs) lib;

      manifestVersion =
        let
          matched = builtins.match ".*\n[ ]*\\.version = \"([^\"]+)\",.*" (builtins.readFile ./build.zig.zon);
        in
        if matched == null then throw "build.zig.zon has no .version to read" else builtins.head matched;

      flakeverConfig = flakever.lib.mkFlakever {
        inherit inputs;

        digits = [
          1
          2
          2
        ];
      };
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.flake-parts.flakeModules.easyOverlay
        inputs.treefmt-nix.flakeModule
      ];

      # Only `-unstable` is stamped. A release candidate is named by a person
      # and cut once, so `0.1.0-rc1` must come out exactly as written.
      flake.versionTemplate =
        if lib.hasSuffix "-unstable" manifestVersion then
          "${manifestVersion}-<lastModifiedDate>-<rev>"
        else
          manifestVersion;

      systems = [
        "aarch64-linux"
        "x86_64-linux"
      ];

      perSystem =
        {
          system,
          pkgs,
          ...
        }:
        let
          inherit (pkgs) lib;
        in
        {
          _module.args.pkgs = import inputs.nixpkgs {
            inherit system;
            overlays = [
              self.overlays.default
            ];
          };

          treefmt.programs = {
            nixfmt.enable = true;
            zig = {
              enable = true;
              package = pkgs.zig_0_17;
            };
          };

          overlayAttrs = {
            flakever = flakeverConfig;
            weir = pkgs.callPackage ./pkgs/weir { };
          };

          packages.default = pkgs.weir;
          devShells.default = pkgs.weir.shell;

          checks = {
            inherit (pkgs) weir;
          };
        };
    };
}
