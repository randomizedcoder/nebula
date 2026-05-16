{
  pkgs,
  lib,
  nebulaLib,
}:

let
  bridge = nebulaLib.underlay.bridge;
  hostIp = nebulaLib.underlay.hostIp;
  netmask = nebulaLib.underlay.netmask;
  taps = lib.mapAttrsToList (_: role: role.network.tap) nebulaLib.roles;

  tapList = lib.concatStringsSep " " taps;

  runtimeInputs = [
    pkgs.iproute2
    pkgs.coreutils
  ];

  vm-network-setup-privileged = pkgs.writeShellApplication {
    name = "vm-network-setup-privileged";
    inherit runtimeInputs;
    text = ''
      if [ "$EUID" -ne 0 ]; then
        echo "ERROR: must run as root (creating bridge + TAPs)" >&2
        exit 1
      fi

      echo "=== creating bridge ${bridge} and TAPs ==="
      if ! ip link show ${bridge} >/dev/null 2>&1; then
        ip link add name ${bridge} type bridge
        ip addr add ${hostIp}/${netmask} dev ${bridge}
        ip link set ${bridge} up
        echo "  bridge ${bridge} created with ${hostIp}/${netmask}"
      else
        echo "  bridge ${bridge} already exists"
      fi

      for TAP in ${tapList}; do
        if ! ip link show "$TAP" >/dev/null 2>&1; then
          ip tuntap add dev "$TAP" mode tap
          ip link set "$TAP" master ${bridge}
          ip link set "$TAP" up
          echo "  TAP $TAP created and attached to ${bridge}"
        else
          echo "  TAP $TAP already exists"
        fi
      done

      echo "PASS: underlay ready"
    '';
  };

  vm-network-teardown-privileged = pkgs.writeShellApplication {
    name = "vm-network-teardown-privileged";
    inherit runtimeInputs;
    text = ''
      if [ "$EUID" -ne 0 ]; then
        echo "ERROR: must run as root" >&2
        exit 1
      fi

      echo "=== tearing down TAPs and bridge ${bridge} ==="
      for TAP in ${tapList}; do
        if ip link show "$TAP" >/dev/null 2>&1; then
          ip link set "$TAP" down || true
          ip tuntap del dev "$TAP" mode tap || true
          echo "  TAP $TAP removed"
        fi
      done
      if ip link show ${bridge} >/dev/null 2>&1; then
        ip link set ${bridge} down || true
        ip link del ${bridge} || true
        echo "  bridge ${bridge} removed"
      fi
      echo "PASS: underlay cleaned up"
    '';
  };
in
{
  inherit vm-network-setup-privileged vm-network-teardown-privileged;
}
