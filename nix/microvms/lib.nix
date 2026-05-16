{
  pkgs,
  nebulaLib,
  system,
}:

let
  timeouts = nebulaLib.getTimeouts system;

  mkPollingScript =
    {
      name,
      description,
      checkCmd,
      successMsg,
      failMsg,
      timeout,
      runtimeInputs ? [ pkgs.coreutils ],
      preCheck ? "",
      postSuccess ? "",
    }:
    pkgs.writeShellApplication {
      inherit name runtimeInputs;
      text = ''
        TIMEOUT=${toString timeout}
        POLL_INTERVAL=${toString nebulaLib.pollInterval}

        echo "=== ${description} ==="
        echo "Timeout: $TIMEOUT s (polling every $POLL_INTERVAL s)"

        ${preCheck}

        WAITED=0
        while ! ${checkCmd}; do
          sleep "$POLL_INTERVAL"
          WAITED=$((WAITED + POLL_INTERVAL))
          if [ "$WAITED" -ge "$TIMEOUT" ]; then
            echo "FAIL: ${failMsg} after $TIMEOUT seconds"
            exit 1
          fi
        done

        echo "PASS: ${successMsg} (after $WAITED s)"
        ${postSuccess}
        exit 0
      '';
    };

  mkSerialConnect =
    role:
    pkgs.writeShellApplication {
      name = "nebula-vm-console-${role}";
      runtimeInputs = [ pkgs.netcat-gnu ];
      text =
        let
          port = nebulaLib.roles.${role}.ports.serial;
        in
        ''
          echo "Connecting to ${role} serial console on port ${toString port}"
          echo "Press Ctrl+C to disconnect"
          nc 127.0.0.1 ${toString port}
        '';
    };

in
{
  inherit mkPollingScript mkSerialConnect timeouts;
}
