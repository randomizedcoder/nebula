{
  pkgs,
  lib,
  nebulaLib,
}:

let
  mkConsole =
    role:
    pkgs.writeShellApplication {
      name = "vm-console-${role}";
      runtimeInputs = [ pkgs.netcat-gnu ];
      text =
        let
          port = nebulaLib.roles.${role}.ports.serial;
        in
        ''
          echo "Connecting to ${role} serial console (port ${toString port})"
          echo "Press Ctrl+C to disconnect"
          nc 127.0.0.1 ${toString port}
        '';
    };

  vm-status = pkgs.writeShellApplication {
    name = "vm-status";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.procps
      pkgs.netcat-gnu
    ];
    text = ''
      echo "=== microvm status ==="
      ${lib.concatStringsSep "\n" (
        lib.mapAttrsToList (name: role: ''
          if pgrep -f "nebula-${name}" >/dev/null 2>&1; then
            STATE="running (pid: $(pgrep -f "nebula-${name}" | tr '\n' ' '))"
          else
            STATE="stopped"
          fi
          SERIAL="closed"
          if nc -z 127.0.0.1 ${toString role.ports.serial} 2>/dev/null; then
            SERIAL="listening"
          fi
          printf "  %-12s %-30s serial:%s\n" "${name}" "$STATE" "$SERIAL"
        '') nebulaLib.roles
      )}
    '';
  };

  vm-stop = pkgs.writeShellApplication {
    name = "vm-stop";
    runtimeInputs = [
      pkgs.procps
      pkgs.coreutils
    ];
    text = ''
      echo "=== stopping all microvms ==="
      ${lib.concatStringsSep "\n" (
        lib.mapAttrsToList (name: _: ''
          if pgrep -f "nebula-${name}" >/dev/null 2>&1; then
            pkill -TERM -f "nebula-${name}" || true
            echo "  sent SIGTERM to nebula-${name}"
          fi
        '') nebulaLib.roles
      )}
      sleep 2
      ${lib.concatStringsSep "\n" (
        lib.mapAttrsToList (name: _: ''
          if pgrep -f "nebula-${name}" >/dev/null 2>&1; then
            pkill -KILL -f "nebula-${name}" || true
            echo "  sent SIGKILL to nebula-${name}"
          fi
        '') nebulaLib.roles
      )}
      rm -rf /tmp/nebula-vm-test
    '';
  };

in
{
  vm-status = vm-status;
  vm-stop = vm-stop;
}
// (lib.mapAttrs' (name: _: {
  name = "vm-console-${name}";
  value = mkConsole name;
}) nebulaLib.roles)
