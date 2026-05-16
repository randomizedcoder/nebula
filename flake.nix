{
  description = "nebula - scalable overlay VPN (modular nix flake)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    microvm = {
      url = "github:astro/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      microvm,
      ...
    }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        inherit (pkgs) lib;

        nebulaLib = import ./nix/lib.nix { inherit lib; };

        packagesAttrs = import ./nix/packages {
          inherit pkgs lib;
          src = ./.;
        };

        containersAttrs = import ./nix/containers {
          inherit pkgs lib;
          inherit (packagesAttrs) nebula nebula-cert;
        };

        scriptsAttrs = import ./nix/scripts {
          inherit pkgs lib nebulaLib;
        };

        microvmAttrs = import ./nix/microvms {
          inherit
            pkgs
            lib
            nixpkgs
            microvm
            system
            ;
          inherit (packagesAttrs) nebula nebula-cert;
        };

        checksAttrs = import ./nix/checks.nix {
          inherit pkgs;
          src = ./.;
          nebulaPkg = packagesAttrs.nebula;
        };

        appsAttrs = import ./nix/apps {
          inherit lib;
          packages = packagesAttrs;
          microvm = microvmAttrs;
          scripts = scriptsAttrs;
          checks = checksAttrs;
        };
      in
      {
        packages =
          packagesAttrs
          // containersAttrs
          // microvmAttrs.packages
          // scriptsAttrs
          // {
            default = packagesAttrs.nebula;
          };

        apps = appsAttrs;

        checks = (lib.filterAttrs (n: _: n != "govulncheck-app") checksAttrs) // microvmAttrs.checks;

        devShells.default = import ./nix/shell.nix { inherit pkgs; };

        lib = nebulaLib;
      }
    );
}
