{ pkgs }:

let
  goPkg = pkgs.go_1_26 or pkgs.go;

  protocGenGogofaster = pkgs.buildGoModule rec {
    pname = "protoc-gen-gogofaster";
    version = "1.3.2";
    src = pkgs.fetchFromGitHub {
      owner = "gogo";
      repo = "protobuf";
      rev = "v${version}";
      hash = "sha256-CoUqgLFnLNCS9OxKFS7XwjE17SlH6iL1Kgv+0uEK2zU=";
    };
    proxyVendor = true;
    vendorHash = "sha256-dkRF+iigR91AgH8GAnddaBOkbjGFgRyVRuxNNV/AWes=";
    subPackages = [ "protoc-gen-gogofaster" ];
    doCheck = false;
  };
in
pkgs.mkShell {
  name = "nebula-dev";

  packages = [
    goPkg
    pkgs.gopls
    pkgs.gotools
    pkgs.delve
    pkgs.golangci-lint
    pkgs.gosec
    pkgs.govulncheck
    pkgs.go-tools

    pkgs.protobuf
    pkgs.protoc-gen-go
    protocGenGogofaster

    pkgs.qemu_kvm
    pkgs.expect
    pkgs.socat
    pkgs.netcat-gnu
    pkgs.iproute2
    pkgs.tcpdump
    pkgs.bridge-utils

    pkgs.nixfmt
    pkgs.statix
    pkgs.deadnix

    pkgs.gnumake
    pkgs.jq
    pkgs.git
  ];

  env = {
    CGO_ENABLED = "0";
    GOTOOLCHAIN = "local";
  };

  shellHook = ''
    echo "nebula dev shell"
    echo "  go:            $(go version)"
    echo "  golangci-lint: $(golangci-lint version --short 2>/dev/null || golangci-lint --version)"
    echo "  protoc:        $(protoc --version)"
    echo "  qemu:          $(qemu-system-x86_64 --version | head -n1)"
    echo ""
    echo "Common commands:"
    echo "  nix build .#nebula                 build the nebula binary"
    echo "  nix flake check                    run all checks (linters + tests)"
    echo "  nix run .#vm-test-mesh             run the two-node microvm lifecycle test"
    echo "  make nix-lint-quick                tier-0 lint (~30s)"
  '';
}
