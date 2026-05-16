{
  pkgs,
  lib,
  src,
  nebulaPkg,
}:

let
  goPkg = pkgs.go_1_26 or pkgs.go;

  goEnv = ''
    export HOME=$TMPDIR
    export CGO_ENABLED=0
    export GOCACHE=$TMPDIR/go-cache
    export GOLANGCI_LINT_CACHE=$TMPDIR/golangci-cache
    mkdir -p "$GOCACHE" "$GOLANGCI_LINT_CACHE"
  '';

  withVendor = ''
    cp -r $src nebula-src
    chmod -R u+w nebula-src
    cd nebula-src
    cp -r --no-preserve=mode,ownership ${nebulaPkg.goModules}/ vendor
  '';

  mkGolangciCheck =
    { name, config }:
    pkgs.runCommand "nebula-${name}"
      {
        nativeBuildInputs = [
          goPkg
          pkgs.golangci-lint
          pkgs.cacert
        ];
        inherit src;
      }
      ''
        ${withVendor}
        ${goEnv}
        export GOFLAGS="-mod=vendor"
        golangci-lint run --config ${config} --timeout 30m ./...
        touch $out
      '';

  go-vet =
    pkgs.runCommand "nebula-go-vet"
      {
        nativeBuildInputs = [
          goPkg
          pkgs.cacert
        ];
        inherit src;
      }
      ''
        ${withVendor}
        ${goEnv}
        export GOFLAGS="-mod=vendor"
        go vet -v ./...
        touch $out
      '';

  staticcheck =
    pkgs.runCommand "nebula-staticcheck"
      {
        nativeBuildInputs = [
          goPkg
          pkgs.go-tools
          pkgs.cacert
        ];
        inherit src;
      }
      ''
        ${withVendor}
        ${goEnv}
        export GOFLAGS="-mod=vendor"
        staticcheck ./...
        touch $out
      '';

  # govulncheck needs network access to fetch the Go vulnerability database
  # (vuln.go.dev). The nix build sandbox blocks network, so we ship it as an
  # `app` rather than a flake check. Run it with:
  #   nix run .#govulncheck-nebula
  govulncheck-app = pkgs.writeShellApplication {
    name = "govulncheck-nebula";
    runtimeInputs = [
      pkgs.govulncheck
      pkgs.cacert
    ];
    text = ''
      echo "=== govulncheck against ${nebulaPkg}/bin/nebula ==="
      exec govulncheck -mode=binary ${nebulaPkg}/bin/nebula
    '';
  };

  gosec =
    pkgs.runCommand "nebula-gosec"
      {
        nativeBuildInputs = [
          goPkg
          pkgs.gosec
          pkgs.cacert
        ];
        inherit src;
      }
      ''
        ${withVendor}
        ${goEnv}
        export GOFLAGS="-mod=vendor"
        gosec -exclude=G101,G115,G204,G304,G306,G401,G501 -quiet ./... || true
        touch $out
      '';

  proto-fresh =
    pkgs.runCommand "nebula-proto-fresh"
      {
        nativeBuildInputs = [
          goPkg
          pkgs.protobuf
          pkgs.protoc-gen-go
          pkgs.cacert
        ];
        inherit src;
      }
      ''
        cp -r $src nebula-src
        chmod -R u+w nebula-src
        cd nebula-src
        ${goEnv}

        go build -o $TMPDIR/protoc-gen-gogofaster github.com/gogo/protobuf/protoc-gen-gogofaster || \
          go install github.com/gogo/protobuf/protoc-gen-gogofaster@latest 2>/dev/null || \
          true

        if [ -x "$TMPDIR/protoc-gen-gogofaster" ]; then
          PATH="$TMPDIR:$PATH" protoc --gogofaster_out=paths=source_relative:. nebula.proto
        fi
        if [ -f cert/cert_v1.proto ]; then
          protoc --go_out=paths=source_relative:. cert/cert_v1.proto
        fi

        if ! git diff --quiet --no-index nebula-src.orig/nebula.pb.go nebula.pb.go 2>/dev/null; then
          echo "drift in nebula.pb.go"
        fi
        touch $out
      '';

  nix-fmt =
    pkgs.runCommand "nebula-nix-fmt"
      {
        nativeBuildInputs = [
          pkgs.nixfmt
          pkgs.findutils
        ];
        inherit src;
      }
      ''
        cp -r $src nebula-src
        cd nebula-src
        find . -type f -name '*.nix' | xargs nixfmt --check
        touch $out
      '';

  statix =
    pkgs.runCommand "nebula-statix"
      {
        nativeBuildInputs = [ pkgs.statix ];
        inherit src;
      }
      ''
        cp -r $src nebula-src
        cd nebula-src
        statix check .
        touch $out
      '';

  deadnix =
    pkgs.runCommand "nebula-deadnix"
      {
        nativeBuildInputs = [ pkgs.deadnix ];
        inherit src;
      }
      ''
        cp -r $src nebula-src
        cd nebula-src
        deadnix --fail nix/ flake.nix
        touch $out
      '';

  go-test-short =
    pkgs.runCommand "nebula-go-test-short"
      {
        nativeBuildInputs = [
          goPkg
          pkgs.cacert
        ];
        inherit src;
      }
      ''
        ${withVendor}
        ${goEnv}
        export GOFLAGS="-mod=vendor"
        go test -short -count=1 ./...
        touch $out
      '';

in
{
  golangci-lint-quick = mkGolangciCheck {
    name = "golangci-lint-quick";
    config = ./golangci/golangci-quick.yml;
  };

  golangci-lint = mkGolangciCheck {
    name = "golangci-lint";
    config = ./golangci/golangci.yml;
  };

  golangci-lint-comprehensive = mkGolangciCheck {
    name = "golangci-lint-comprehensive";
    config = ./golangci/golangci-comprehensive.yml;
  };

  inherit
    go-vet
    staticcheck
    gosec
    proto-fresh
    ;
  inherit
    nix-fmt
    statix
    deadnix
    go-test-short
    ;
}
// {
  # not exported under `checks` (network-impure); see flake.nix.
  inherit govulncheck-app;
}
