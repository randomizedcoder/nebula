{
  lib,
  src,
  nebulaLib,
  buildGoModule,
}:

let
  build =
    variant:
    buildGoModule rec {
      pname = "nebula";
      version = nebulaLib.nebula.version;
      inherit src;

      vendorHash = "sha256-ouYVuRpxErEjkQrCkMdsD+MU3fCz6wtlrCQ5y/FdHJE=";

      subPackages = [ "cmd/nebula" ];

      env =
        lib.optionalAttrs (variant.goExperiment != null) {
          GOEXPERIMENT = variant.goExperiment;
        }
        // {
          CGO_ENABLED = if variant.cgo then "1" else "0";
        };

      inherit (variant) tags;

      ldflags = nebulaLib.nebula.ldflags ++ [ "-X main.Build=${version}" ] ++ variant.extraLdflags;

      doCheck = false;

      meta = with lib; {
        description = "A scalable overlay networking tool with a focus on performance, simplicity and security";
        homepage = "https://github.com/slackhq/nebula";
        license = licenses.mit;
        mainProgram = "nebula";
      };
    };
in
{
  basePname = "nebula";
  inherit build;
}
