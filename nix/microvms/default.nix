{
  pkgs,
  lib,
  nixpkgs,
  microvm,
  system,
  nebula,
  nebula-cert,
}:

let
  nebulaLib = import ../lib.nix { inherit lib; };

  base = import ./base.nix {
    inherit
      pkgs
      lib
      nixpkgs
      microvm
      system
      nebulaLib
      ;
    nebulaPkg = nebula;
  };

  pki = import ./pki.nix {
    inherit pkgs nebulaLib;
    nebulaCertPkg = nebula-cert;
  };

  mkVm =
    roleName:
    base.mkNebulaVm {
      inherit roleName;
      roleData = nebulaLib.roles.${roleName};
      inherit pki;
    };

  lighthouse-vm = mkVm "lighthouse";
  edge-vm = mkVm "edge";

  lifecycle = import ./lifecycle.nix {
    inherit
      pkgs
      nebulaLib
      system
      ;
  };
in
{
  packages = {
    inherit lighthouse-vm edge-vm;
    nebula-test-pki = pki;
    vm-test-mesh = lifecycle.fullTest;
    vm-lifecycle-0-build = lifecycle.phase0;
    vm-lifecycle-1-start = lifecycle.phase1;
    vm-lifecycle-2-serial-ready = lifecycle.phase2;
    vm-lifecycle-3-virtio-ready = lifecycle.phase3;
    vm-lifecycle-4-service-active = lifecycle.phase4;
    vm-lifecycle-5-ping-overlay = lifecycle.phase5;
    vm-lifecycle-6-shutdown = lifecycle.phase6;
    vm-lifecycle-7-wait-exit = lifecycle.phase7;
  };

  checks = { };

  inherit lifecycle pki;
}
