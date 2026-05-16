{
  pkgs,
  nebulaLib,
  system,
}:

let
  microvmLib = import ./lib.nix {
    inherit
      pkgs
      nebulaLib
      system
      ;
  };
  inherit (microvmLib) timeouts;

  expectScripts = pkgs.runCommand "nebula-vm-expect-scripts" { } ''
    mkdir -p $out/bin
    cp ${./scripts/vm-expect.exp}          $out/bin/nebula-vm-expect
    cp ${./scripts/vm-verify-service.exp}  $out/bin/nebula-vm-verify-service
    cp ${./scripts/vm-ping-overlay.exp}    $out/bin/nebula-vm-ping-overlay
    chmod +x $out/bin/*
  '';

  lh = nebulaLib.roles.lighthouse;
  edge = nebulaLib.roles.edge;

  lhSerial = lh.ports.serial;
  edgeSerial = edge.ports.serial;
  lhVirtio = lh.ports.virtio;
  edgeVirtio = edge.ports.virtio;
  lhHost = "nebula-lighthouse";
  edgeHost = "nebula-edge";

  commonRuntime = [
    pkgs.coreutils
    pkgs.netcat-gnu
    pkgs.procps
    pkgs.expect
    pkgs.gawk
    pkgs.gnugrep
    pkgs.gnused
    expectScripts
  ];

  phase0 = pkgs.writeShellApplication {
    name = "vm-lifecycle-0-build";
    runtimeInputs = [
      pkgs.nix
      pkgs.coreutils
    ];
    text = ''
      echo "=== Phase 0: build microvm runners ==="
      nix build -L --no-link \
        ".#lighthouse-vm" ".#edge-vm"
      echo "PASS: VM derivations built"
    '';
  };

  phase1 = pkgs.writeShellApplication {
    name = "vm-lifecycle-1-start";
    runtimeInputs = commonRuntime ++ [ pkgs.nix ];
    text = ''
      echo "=== Phase 1: start lighthouse + edge VMs ==="
      if ! ip link show ${nebulaLib.underlay.bridge} >/dev/null 2>&1; then
        echo "ERROR: bridge ${nebulaLib.underlay.bridge} is missing."
        echo "Run: sudo nix run .#vm-network-setup-privileged"
        exit 1
      fi

      LH_RUNNER=$(nix build --print-out-paths --no-link .#lighthouse-vm)
      EDGE_RUNNER=$(nix build --print-out-paths --no-link .#edge-vm)

      mkdir -p /tmp/nebula-vm-test
      "$LH_RUNNER/bin/microvm-run" > /tmp/nebula-vm-test/lighthouse.log 2>&1 &
      echo $! > /tmp/nebula-vm-test/lighthouse.pid
      "$EDGE_RUNNER/bin/microvm-run" > /tmp/nebula-vm-test/edge.log 2>&1 &
      echo $! > /tmp/nebula-vm-test/edge.pid

      sleep 1
      if ! kill -0 "$(cat /tmp/nebula-vm-test/lighthouse.pid)" 2>/dev/null; then
        echo "FAIL: lighthouse VM exited immediately"
        cat /tmp/nebula-vm-test/lighthouse.log
        exit 1
      fi
      if ! kill -0 "$(cat /tmp/nebula-vm-test/edge.pid)" 2>/dev/null; then
        echo "FAIL: edge VM exited immediately"
        cat /tmp/nebula-vm-test/edge.log
        exit 1
      fi

      echo "PASS: both VMs started"
    '';
  };

  phase2 = pkgs.writeShellApplication {
    name = "vm-lifecycle-2-serial-ready";
    runtimeInputs = commonRuntime;
    text = ''
      echo "=== Phase 2: serial console TCP listeners ready ==="
      TIMEOUT=${toString timeouts.serialReady}
      for PORT in ${toString lhSerial} ${toString edgeSerial}; do
        WAITED=0
        until nc -z 127.0.0.1 "$PORT" 2>/dev/null; do
          sleep ${toString nebulaLib.pollInterval}
          WAITED=$((WAITED + ${toString nebulaLib.pollInterval}))
          if [ "$WAITED" -ge "$TIMEOUT" ]; then
            echo "FAIL: serial port $PORT did not open after $TIMEOUT s"
            exit 1
          fi
        done
        echo "  serial port $PORT ready"
      done
      echo "PASS: both serial consoles listening"
    '';
  };

  phase3 = pkgs.writeShellApplication {
    name = "vm-lifecycle-3-virtio-ready";
    runtimeInputs = commonRuntime;
    text = ''
      echo "=== Phase 3: virtio console listeners ready ==="
      TIMEOUT=${toString timeouts.virtioReady}
      for PORT in ${toString lhVirtio} ${toString edgeVirtio}; do
        WAITED=0
        until nc -z 127.0.0.1 "$PORT" 2>/dev/null; do
          sleep ${toString nebulaLib.pollInterval}
          WAITED=$((WAITED + ${toString nebulaLib.pollInterval}))
          if [ "$WAITED" -ge "$TIMEOUT" ]; then
            echo "FAIL: virtio port $PORT did not open after $TIMEOUT s"
            exit 1
          fi
        done
        echo "  virtio port $PORT ready"
      done
      echo "PASS: both virtio consoles listening"
    '';
  };

  phase4 = pkgs.writeShellApplication {
    name = "vm-lifecycle-4-service-active";
    runtimeInputs = commonRuntime;
    text = ''
      echo "=== Phase 4: nebula.service active on both nodes ==="
      TO=${toString timeouts.serviceActive}
      nebula-vm-verify-service ${toString lhSerial}   ${lhHost}   nebula.service "$TO" 2 \
        || { echo "FAIL: lighthouse nebula.service not active"; exit 1; }
      nebula-vm-verify-service ${toString edgeSerial} ${edgeHost} nebula.service "$TO" 2 \
        || { echo "FAIL: edge nebula.service not active"; exit 1; }

      echo "Checking nebula1 interface on both nodes..."
      nebula-vm-expect ${toString lhSerial}   ${lhHost}   "ip -br link show nebula1" 10 \
        | grep -q nebula1 || { echo "FAIL: nebula1 missing on lighthouse"; exit 1; }
      nebula-vm-expect ${toString edgeSerial} ${edgeHost} "ip -br link show nebula1" 10 \
        | grep -q nebula1 || { echo "FAIL: nebula1 missing on edge"; exit 1; }
      echo "PASS: nebula service active and nebula1 up on both nodes"
    '';
  };

  phase5 = pkgs.writeShellApplication {
    name = "vm-lifecycle-5-ping-overlay";
    runtimeInputs = commonRuntime;
    text = ''
      echo "=== Phase 5: ping lighthouse overlay IP from edge ==="
      nebula-vm-ping-overlay ${toString edgeSerial} ${edgeHost} \
        ${nebulaLib.lighthouseOverlayIp} 5 ${toString timeouts.ping}
    '';
  };

  phase6 = pkgs.writeShellApplication {
    name = "vm-lifecycle-6-shutdown";
    runtimeInputs = commonRuntime;
    text = ''
      echo "=== Phase 6: shutdown both VMs ==="
      for entry in "${toString lhSerial}:${lhHost}" "${toString edgeSerial}:${edgeHost}"; do
        PORT="''${entry%%:*}"
        HOST="''${entry##*:}"
        nebula-vm-expect "$PORT" "$HOST" "systemctl poweroff" 5 || true
      done
      echo "PASS: poweroff sent"
    '';
  };

  phase7 = pkgs.writeShellApplication {
    name = "vm-lifecycle-7-wait-exit";
    runtimeInputs = commonRuntime;
    text = ''
      echo "=== Phase 7: wait for VM processes to exit ==="
      TO=${toString timeouts.waitExit}
      for PIDFILE in /tmp/nebula-vm-test/lighthouse.pid /tmp/nebula-vm-test/edge.pid; do
        [ -f "$PIDFILE" ] || continue
        PID=$(cat "$PIDFILE")
        WAITED=0
        while kill -0 "$PID" 2>/dev/null; do
          sleep 1
          WAITED=$((WAITED + 1))
          if [ "$WAITED" -ge "$TO" ]; then
            echo "  force-killing PID $PID"
            kill -TERM "$PID" 2>/dev/null || true
            sleep 2
            kill -KILL "$PID" 2>/dev/null || true
            break
          fi
        done
      done
      rm -rf /tmp/nebula-vm-test
      echo "PASS: VMs exited cleanly"
    '';
  };

  fullTest = pkgs.writeShellApplication {
    name = "vm-test-mesh";
    runtimeInputs = commonRuntime ++ [
      phase0
      phase1
      phase2
      phase3
      phase4
      phase5
      phase6
      phase7
    ];
    text = ''
      set +e
      cleanup() {
        echo "--- cleanup ---"
        vm-lifecycle-6-shutdown || true
        vm-lifecycle-7-wait-exit || true
      }
      trap cleanup EXIT INT TERM

      vm-lifecycle-0-build       || exit 1
      vm-lifecycle-1-start       || exit 1
      vm-lifecycle-2-serial-ready  || exit 1
      vm-lifecycle-3-virtio-ready  || exit 1
      vm-lifecycle-4-service-active || exit 1
      vm-lifecycle-5-ping-overlay  || exit 1

      trap - EXIT
      vm-lifecycle-6-shutdown
      vm-lifecycle-7-wait-exit
      echo ""
      echo "=========================================="
      echo "  vm-test-mesh: PASS"
      echo "=========================================="
    '';
  };

in
{
  inherit
    phase0
    phase1
    phase2
    phase3
    phase4
    phase5
    phase6
    phase7
    fullTest
    ;
  inherit expectScripts;
}
