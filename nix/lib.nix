{ lib }:

let
  constants = import ./constants.nix;
  c = constants;

  validateRole =
    name: role:
    assert lib.assertMsg (role ? index) "Role '${name}' missing required field 'index'";
    assert lib.assertMsg (role ? shortName) "Role '${name}' missing required field 'shortName'";
    assert lib.assertMsg (
      role.index >= 1 && role.index <= 254
    ) "Role '${name}' has invalid index ${toString role.index} (must be 1-254)";
    role;

  validatedRoles = lib.mapAttrs validateRole c.roles;

  indexList = lib.mapAttrsToList (_: r: r.index) validatedRoles;
  uniqueIndexes = lib.unique indexList;
  indexValidation =
    assert lib.assertMsg (
      builtins.length indexList == builtins.length uniqueIndexes
    ) "Duplicate role indexes detected in nix/constants.nix roles. Each role must have a unique index.";
    null;

  lighthousePresent =
    assert lib.assertMsg (builtins.hasAttr "lighthouse" validatedRoles)
      "A role named 'lighthouse' is required (it is the well-known peer for mesh discovery).";
    null;

  toHex2 =
    n:
    let
      hexChars = "0123456789abcdef";
      high = n / 16;
      low = n - (high * 16);
    in
    "${builtins.substring high 1 hexChars}${builtins.substring low 1 hexChars}";

  mkRoleNetwork = role: {
    tap = "nebtap-${role.shortName}";
    bridge = c.underlay.bridge;
    underlayIp = "${c.underlay.subnetPrefix}.${toString role.index}";
    underlayCidr = "${c.underlay.subnetPrefix}.${toString role.index}/${c.underlay.netmask}";
    overlayIp = "${c.overlay.subnetPrefix}.${toString role.index}";
    overlayCidr = "${c.overlay.subnetPrefix}.${toString role.index}/${c.overlay.netmask}";
    mac = "02:00:00:42:${toHex2 role.index}:02";
  };

  mkRolePorts = role: {
    serial = c.ports.serialBase + role.index;
    virtio = c.ports.virtioBase + role.index;
  };

  roles = lib.mapAttrs (
    name: role:
    role
    // {
      network = mkRoleNetwork role;
      ports = mkRolePorts role;
      vmName = "nebula-${name}";
    }
  ) validatedRoles;

  roleNames = builtins.attrNames roles;

  lighthouseOverlayIp = roles.lighthouse.network.overlayIp;
  lighthouseUnderlayIp = roles.lighthouse.network.underlayIp;

  getTimeouts =
    system:
    if lib.hasPrefix "x86_64" system then
      c.timeouts.x86_64
    else if lib.hasPrefix "aarch64" system then
      c.timeouts.aarch64
    else
      c.timeouts.aarch64;

in
{
  inherit roles roleNames;
  inherit lighthouseOverlayIp lighthouseUnderlayIp;
  inherit getTimeouts;
  inherit (constants)
    underlay
    overlay
    ports
    vm
    nebula
    go
    oci
    pollInterval
    ;

  _indexValidation = indexValidation;
  _lighthousePresent = lighthousePresent;
}
