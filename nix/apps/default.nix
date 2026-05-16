{
  lib,
  packages,
  microvm,
  scripts,
  checks ? null,
}:

let
  mkApp = drv: program: {
    type = "app";
    program = "${drv}/bin/${program}";
  };

  packageApps = {
    nebula = mkApp packages.nebula "nebula";
    nebula-cert = mkApp packages.nebula-cert "nebula-cert";
    nebula-service = mkApp packages.nebula-service "nebula-service";
  };

  vmApps = {
    vm-test-mesh = mkApp microvm.packages.vm-test-mesh "vm-test-mesh";
    vm-lifecycle-0-build = mkApp microvm.packages.vm-lifecycle-0-build "vm-lifecycle-0-build";
    vm-lifecycle-1-start = mkApp microvm.packages.vm-lifecycle-1-start "vm-lifecycle-1-start";
    vm-lifecycle-2-serial-ready = mkApp microvm.packages.vm-lifecycle-2-serial-ready "vm-lifecycle-2-serial-ready";
    vm-lifecycle-3-virtio-ready = mkApp microvm.packages.vm-lifecycle-3-virtio-ready "vm-lifecycle-3-virtio-ready";
    vm-lifecycle-4-service-active = mkApp microvm.packages.vm-lifecycle-4-service-active "vm-lifecycle-4-service-active";
    vm-lifecycle-5-ping-overlay = mkApp microvm.packages.vm-lifecycle-5-ping-overlay "vm-lifecycle-5-ping-overlay";
    vm-lifecycle-6-shutdown = mkApp microvm.packages.vm-lifecycle-6-shutdown "vm-lifecycle-6-shutdown";
    vm-lifecycle-7-wait-exit = mkApp microvm.packages.vm-lifecycle-7-wait-exit "vm-lifecycle-7-wait-exit";
  };

  scriptApps = {
    vm-network-setup-privileged = mkApp scripts.vm-network-setup-privileged "vm-network-setup-privileged";
    vm-network-teardown-privileged = mkApp scripts.vm-network-teardown-privileged "vm-network-teardown-privileged";
    vm-status = mkApp scripts.vm-status "vm-status";
    vm-stop = mkApp scripts.vm-stop "vm-stop";
    vm-console-lighthouse = mkApp scripts.vm-console-lighthouse "vm-console-lighthouse";
    vm-console-edge = mkApp scripts.vm-console-edge "vm-console-edge";
  };

  auditApps = lib.optionalAttrs (checks != null && checks ? govulncheck-app) {
    govulncheck-nebula = mkApp checks.govulncheck-app "govulncheck-nebula";
  };

in
packageApps
// vmApps
// scriptApps
// auditApps
// {
  default = packageApps.nebula;
}
