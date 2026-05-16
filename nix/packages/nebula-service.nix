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
      pname = "nebula-service";
      version = nebulaLib.nebula.version;
      inherit src;

      vendorHash = "sha256-ouYVuRpxErEjkQrCkMdsD+MU3fCz6wtlrCQ5y/FdHJE=";

      subPackages = [ "cmd/nebula-service" ];

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
        description = "Nebula service wrapper (systemd / windows-service)";
        homepage = "https://github.com/slackhq/nebula";
        license = licenses.mit;
        mainProgram = "nebula-service";
      };
    };
in
{
  basePname = "nebula-service";
  inherit build;
}
