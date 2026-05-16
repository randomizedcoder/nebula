{
  pkgs,
  lib,
  nebula,
  nebula-cert,
}:

let
  nebulaLib = import ../lib.nix { inherit lib; };
  mkNebulaImage = import ./nebula.nix { inherit pkgs nebulaLib; };
  mkNebulaCertImage = import ./nebula-cert.nix { inherit pkgs nebulaLib; };
in
{
  nebula-image = mkNebulaImage nebula;
  nebula-cert-image = mkNebulaCertImage nebula-cert;
}
