{
  pkgs,
  lib,
  src,
  nebulaLib,
  buildGoModule,
}:

let
  build =
    variant:
    buildGoModule rec {
      pname = "nebula-cert";
      version = nebulaLib.nebula.version;
      inherit src;

      vendorHash = "sha256-ouYVuRpxErEjkQrCkMdsD+MU3fCz6wtlrCQ5y/FdHJE=";

      subPackages = [ "cmd/nebula-cert" ];

      env =
        lib.optionalAttrs (variant.goExperiment != null) {
          GOEXPERIMENT = variant.goExperiment;
        }
        // {
          CGO_ENABLED = if variant.cgo then "1" else "0";
        };

      tags = variant.tags;

      ldflags = nebulaLib.nebula.ldflags ++ [ "-X main.Build=${version}" ] ++ variant.extraLdflags;

      doCheck = false;

      meta = with lib; {
        description = "Nebula certificate authority and key management tool";
        homepage = "https://github.com/slackhq/nebula";
        license = licenses.mit;
        mainProgram = "nebula-cert";
      };
    };
in
{
  basePname = "nebula-cert";
  inherit build;
}
