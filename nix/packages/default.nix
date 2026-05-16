{
  pkgs,
  lib,
  src,
}:

let
  nebulaLib = import ../lib.nix { inherit lib; };

  # Pin to go_1_26 (whatever the locked nixpkgs ships, currently 1.26.2)
  goPkg = pkgs.go_1_26 or pkgs.go;
  buildGoModule = pkgs.buildGoModule.override { go = goPkg; };

  mkNebula = import ./nebula.nix {
    inherit
      lib
      src
      nebulaLib
      buildGoModule
      ;
  };
  mkNebulaCert = import ./nebula-cert.nix {
    inherit
      lib
      src
      nebulaLib
      buildGoModule
      ;
  };
  mkNebulaService = import ./nebula-service.nix {
    inherit
      lib
      src
      nebulaLib
      buildGoModule
      ;
  };

  variants = {
    standard = {
      tags = [ ];
      cgo = false;
      goExperiment = null;
      extraLdflags = [ ];
    };
    boringcrypto = {
      tags = [ ];
      cgo = true;
      goExperiment = "boringcrypto";
      extraLdflags = [ "-checklinkname=0" ];
    };
    pkcs11 = {
      tags = [ "pkcs11" ];
      cgo = true;
      goExperiment = null;
      extraLdflags = [ ];
    };
  };

  forEachVariant =
    builder:
    lib.mapAttrs' (variantName: variant: {
      name =
        if variantName == "standard" then builder.basePname else "${builder.basePname}-${variantName}";
      value = builder.build variant;
    }) variants;
in
(forEachVariant mkNebula) // (forEachVariant mkNebulaCert) // (forEachVariant mkNebulaService)
