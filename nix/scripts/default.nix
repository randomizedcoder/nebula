{
  pkgs,
  lib,
  nebulaLib,
}:

let
  network = import ./vm-network.nix { inherit pkgs lib nebulaLib; };
  management = import ./vm-management.nix { inherit pkgs lib nebulaLib; };
in
network // management
