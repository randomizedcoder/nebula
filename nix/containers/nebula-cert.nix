{
  pkgs,
  nebulaLib,
}:

nebulaCertPkg:
pkgs.dockerTools.buildLayeredImage {
  name = "${nebulaLib.oci.registry}/${nebulaLib.oci.nebulaCertImageName}";
  tag = nebulaLib.oci.tag;

  contents = [
    pkgs.cacert
    nebulaCertPkg
  ];

  config = {
    Entrypoint = [ "/bin/nebula-cert" ];
    Cmd = [ "--help" ];
    Labels = {
      "org.opencontainers.image.title" = "nebula-cert";
      "org.opencontainers.image.description" = "Nebula CA / certificate signing tool";
      "org.opencontainers.image.source" = "https://github.com/slackhq/nebula";
    };
  };
}
