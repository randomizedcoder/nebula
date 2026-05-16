{
  pkgs,
  nebulaLib,
}:

nebulaPkg:
pkgs.dockerTools.buildLayeredImage {
  name = "${nebulaLib.oci.registry}/${nebulaLib.oci.nebulaImageName}";
  tag = nebulaLib.oci.tag;

  contents = [
    pkgs.cacert
    nebulaPkg
  ];

  config = {
    Entrypoint = [ "/bin/nebula" ];
    Cmd = [
      "-config"
      "/config/config.yml"
    ];
    Volumes = {
      "/config" = { };
    };
    Labels = {
      "org.opencontainers.image.title" = "nebula";
      "org.opencontainers.image.description" = "Nebula overlay VPN daemon";
      "org.opencontainers.image.source" = "https://github.com/slackhq/nebula";
    };
  };
}
