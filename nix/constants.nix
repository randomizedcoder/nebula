{
  nebula = {
    version = "dev";
    ldflags = [
      "-s"
      "-w"
    ];
  };

  go = {
    version = "1.26";
  };

  oci = {
    registry = "nebulaoss";
    nebulaImageName = "nebula";
    nebulaCertImageName = "nebula-cert";
    tag = "latest";
  };

  underlay = {
    subnetPrefix = "192.168.42";
    bridge = "nebbr0";
    hostIp = "192.168.42.254";
    netmask = "24";
  };

  overlay = {
    subnetPrefix = "10.42.0";
    netmask = "24";
    lighthousePort = 4242;
  };

  ports = {
    serialBase = 45000;
    virtioBase = 46000;
  };

  vm = {
    memoryMB = 1025;
    vcpus = 2;
  };

  roles = {
    lighthouse = {
      index = 1;
      shortName = "lh";
      description = "Nebula lighthouse";
      amLighthouse = true;
    };
    edge = {
      index = 2;
      shortName = "edge";
      description = "Nebula edge peer";
      amLighthouse = false;
    };
  };

  timeouts = {
    x86_64 = {
      build = 600;
      vmStart = 30;
      serialReady = 60;
      virtioReady = 60;
      serviceActive = 60;
      ping = 30;
      shutdown = 30;
      waitExit = 30;
    };
    aarch64 = {
      build = 1200;
      vmStart = 60;
      serialReady = 120;
      virtioReady = 120;
      serviceActive = 120;
      ping = 60;
      shutdown = 60;
      waitExit = 60;
    };
  };

  pollInterval = 1;
}
