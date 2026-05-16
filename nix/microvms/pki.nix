{
  pkgs,
  nebulaLib,
  nebulaCertPkg,
}:

let
  caName = "nebula-test-ca";
  lh = nebulaLib.roles.lighthouse;
  edge = nebulaLib.roles.edge;
in
pkgs.runCommand "nebula-test-pki"
  {
    nativeBuildInputs = [ nebulaCertPkg ];
  }
  ''
    mkdir -p $out
    cd $out

    nebula-cert ca -name "${caName}" -duration 87600h

    nebula-cert sign \
      -name "lighthouse" \
      -networks "${lh.network.overlayIp}/${nebulaLib.overlay.netmask}" \
      -out-crt lighthouse.crt \
      -out-key lighthouse.key

    nebula-cert sign \
      -name "edge" \
      -networks "${edge.network.overlayIp}/${nebulaLib.overlay.netmask}" \
      -out-crt edge.crt \
      -out-key edge.key

    chmod 0644 *.crt *.key
  ''
