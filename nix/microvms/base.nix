{
  pkgs,
  lib,
  nixpkgs,
  microvm,
  system,
  nebulaLib,
  nebulaPkg,
}:

let
  mkConfig =
    role: roleData:
    let
      isLh = roleData.amLighthouse;
      lhIp = nebulaLib.lighthouseOverlayIp;
      lhUnderlay = nebulaLib.lighthouseUnderlayIp;
      lhPort = nebulaLib.overlay.lighthousePort;
    in
    pkgs.writeText "nebula-${role}-config.yml" ''
      pki:
        ca: /etc/nebula/ca.crt
        cert: /etc/nebula/${role}.crt
        key: /etc/nebula/${role}.key

      static_host_map:
        ${if isLh then "{}" else ''"${lhIp}": ["${lhUnderlay}:${toString lhPort}"]''}

      lighthouse:
        am_lighthouse: ${if isLh then "true" else "false"}
        interval: 60
        ${lib.optionalString (!isLh) ''
          hosts:
                  - "${lhIp}"''}

      listen:
        host: 0.0.0.0
        port: ${if isLh then toString lhPort else "0"}

      punchy:
        punch: true

      tun:
        dev: nebula1
        drop_local_broadcast: false
        drop_multicast: false
        tx_queue: 500
        mtu: 1300

      logging:
        level: info
        format: text

      firewall:
        conntrack:
          tcp_timeout: 12m
          udp_timeout: 3m
          default_timeout: 10m
        outbound:
          - port: any
            proto: any
            host: any
        inbound:
          - port: any
            proto: any
            host: any
    '';

  mkNebulaVm =
    {
      roleName,
      roleData,
      pki,
    }:
    let
      net = roleData.network;
      cfgFile = mkConfig roleName roleData;
    in
    (nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        microvm.nixosModules.microvm
        (
          { pkgs, ... }:
          {
            system.stateVersion = "24.11";

            networking = {
              hostName = "nebula-${roleName}";
              useNetworkd = true;
              useDHCP = false;
              firewall.enable = false;
            };

            microvm = {
              hypervisor = "qemu";
              mem = nebulaLib.vm.memoryMB;
              vcpu = nebulaLib.vm.vcpus;

              interfaces = [
                {
                  type = "tap";
                  inherit (net) mac;
                  id = net.tap;
                }
              ];

              shares = [
                {
                  source = "/nix/store";
                  mountPoint = "/nix/store";
                  tag = "nix-store";
                  proto = "9p";
                }
              ];

              qemu.extraArgs = [
                "-name"
                "nebula-${roleName},process=nebula-${roleName}"
                "-chardev"
                "socket,id=serialcon,host=127.0.0.1,port=${toString roleData.ports.serial},server=on,wait=off"
                "-serial"
                "chardev:serialcon"
                "-device"
                "virtio-serial-pci"
                "-chardev"
                "socket,id=virtcon,host=127.0.0.1,port=${toString roleData.ports.virtio},server=on,wait=off"
                "-device"
                "virtconsole,chardev=virtcon"
              ];
            };

            systemd = {
              network = {
                enable = true;
                networks."10-underlay" = {
                  matchConfig.Name = "eth*";
                  networkConfig = {
                    DHCP = "no";
                    Address = "${net.underlayIp}/${nebulaLib.underlay.netmask}";
                  };
                };
              };

              services.nebula = {
                description = "Nebula overlay VPN (${roleName})";
                after = [ "network-online.target" ];
                wants = [ "network-online.target" ];
                wantedBy = [ "multi-user.target" ];
                serviceConfig = {
                  Type = "simple";
                  ExecStart = "${nebulaPkg}/bin/nebula -config /etc/nebula/config.yml";
                  Restart = "on-failure";
                  RestartSec = 2;
                };
              };
            };

            environment = {
              etc = {
                "nebula/ca.crt".source = "${pki}/ca.crt";
                "nebula/${roleName}.crt".source = "${pki}/${roleName}.crt";
                "nebula/${roleName}.key".source = "${pki}/${roleName}.key";
                "nebula/config.yml".source = cfgFile;
              };

              systemPackages = [
                nebulaPkg
                pkgs.iproute2
                pkgs.iputils
                pkgs.netcat-gnu
                pkgs.curl
              ];
            };

            services.getty.autologinUser = "root";
            users.users.root.initialPassword = "nebula";

            documentation.enable = false;
            security.polkit.enable = false;
            fonts.fontconfig.enable = false;
            nix.enable = false;
          }
        )
      ];
    }).config.microvm.declaredRunner;

in
{
  inherit mkNebulaVm;
}
