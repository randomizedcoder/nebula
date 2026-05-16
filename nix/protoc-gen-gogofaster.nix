{ pkgs }:

pkgs.buildGoModule rec {
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
}
