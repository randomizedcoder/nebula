{
  pkgs,
  src,
  nebulaPkg,
}:

let
  goPkg = pkgs.go_1_26 or pkgs.go;
  protocGenGogofaster = import ./protoc-gen-gogofaster.nix { inherit pkgs; };

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

  # gosec exclusions:
  #   G101  - hardcoded credentials false-positives in test fixtures
  #   G115  - integer conversion overflow false-positives we accept
  #   G204  - subprocess execution in test helpers and CLI commands
  #   G304  - file path includes in test fixtures and config loaders
  #   G306  - file write permissions in tests and tooling
  #   G401  - SHA1 use in legacy interop helpers
  #   G501  - md5 import for compatibility shims
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
        gosec -exclude=G101,G115,G204,G304,G306,G401,G501 -quiet ./...
        touch $out
      '';

  # Regenerates nebula.pb.go and cert/cert_v1.pb.go from their .proto sources
  # and asserts that the committed files match. Runs hermetically because the
  # protoc plugins come in as derivations on PATH — no network fetching.
  proto-fresh =
    pkgs.runCommand "nebula-proto-fresh"
      {
        nativeBuildInputs = [
          goPkg
          pkgs.protobuf
          pkgs.protoc-gen-go
          protocGenGogofaster
          pkgs.diffutils
        ];
        inherit src;
      }
      ''
        cp -r $src nebula-src-orig
        cp -r $src nebula-src
        chmod -R u+w nebula-src
        cd nebula-src

        # Top-level nebula.proto: run from repo root to match `make proto`
        protoc --gogofaster_out=paths=source_relative:. nebula.proto

        # cert/cert_v1.proto: run from cert/ to match `cert/Makefile`'s
        # invocation, so generated symbols carry the file_cert_v1_proto_*
        # prefix rather than file_cert_cert_v1_proto_*.
        ( cd cert && protoc --go_out=. --go_opt=paths=source_relative cert_v1.proto )

        if ! diff -u ../nebula-src-orig/nebula.pb.go nebula.pb.go; then
          echo "FAIL: nebula.pb.go is stale; regenerate with 'make proto'" >&2
          exit 1
        fi
        if ! diff -u ../nebula-src-orig/cert/cert_v1.pb.go cert/cert_v1.pb.go; then
          echo "FAIL: cert/cert_v1.pb.go is stale; regenerate with 'make proto'" >&2
          exit 1
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
