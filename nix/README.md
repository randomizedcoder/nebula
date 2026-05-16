# Nebula — Nix Flake Development Environment

This directory holds the modular Nix flake for the nebula fork. The root
`flake.nix` is a thin wiring layer; almost everything is implemented in
per-concern files under `nix/` so each layer (packages, containers, microVMs,
checks) can be read, modified, and tested in isolation.

The design takes its modular structure and per-system data flow from
[gosrt](https://github.com/das/gosrt) and the QEMU lifecycle harness from
[xdp2](https://github.com/das/xdp2). Most files are copy-and-adapted from
those two projects, not greenfield.

## Goals

- **Reproducible builds** — `nix build .#nebula` produces the same binary on
  every machine, regardless of the user's distro, Go version, or toolchain
  state. CGO and `GOEXPERIMENT` are handled per build variant, not in shell
  environment.
- **Easy onboarding** — `nix develop` provides Go 1.25, golangci-lint, gosec,
  govulncheck, protoc, expect, qemu, and the rest of the toolchain. No
  per-OS install instructions.
- **Pedantic static analysis** — three-tier `nix flake check` (quick /
  standard / comprehensive) runs golangci-lint with progressively stricter
  configs, plus `go vet`, `staticcheck`, `govulncheck`, `gosec`, nix-side
  `nixfmt`, `statix`, `deadnix`, and a `proto-fresh` drift check.
- **Production-shaped OCI containers** — `nix build .#nebula-image` produces
  a distroless-style layered image that matches the existing `Dockerfile`
  entrypoint/volume contract.
- **End-to-end mesh testing** — `nix run .#vm-test-mesh` boots two QEMU
  microVMs (lighthouse + edge), waits for `nebula.service` to come up on
  both, and asserts that the edge can `ping` the lighthouse over the nebula
  overlay (`10.42.0.0/24`).

The upstream `Makefile` is left untouched; everything here is opt-in.

## Table of Contents

- [Quick Start](#quick-start)
- [Building and Testing](#building-and-testing)
- [OCI Containers](#oci-containers)
- [MicroVM Integration Testing](#microvm-integration-testing)
- [Static Analysis](#static-analysis)
- [Debugging](#debugging)
- [Understanding the Environment](#understanding-the-environment)
- [File Map](#file-map)

## Quick Start

### 1. Install Nix

If you don't have Nix yet, use the
[Determinate Nix installer](https://determinate.systems/posts/determinate-nix-installer):

```sh
curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install
```

Make sure flakes are enabled (the Determinate installer enables them by
default). Otherwise:

```sh
mkdir -p ~/.config/nix
echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
```

### 2. Enter the dev shell

```sh
nix develop
```

You should see a banner with the active Go, golangci-lint, protoc, and qemu
versions. Inside the shell:

```sh
go version
golangci-lint version
qemu-system-x86_64 --version
```

### 3. First build — pin the vendor hash

The package derivations use `lib.fakeHash` as a placeholder for `vendorHash`.
The first time you run `nix build .#nebula`, nix will fail with a message
like:

```
got:    sha256-XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX=
```

Copy that sha256 into `nix/packages/nebula.nix`, `nix/packages/nebula-cert.nix`,
and `nix/packages/nebula-service.nix` (replacing `lib.fakeHash`). Re-run; the
build now succeeds. Repeat whenever `go.mod` / `go.sum` changes.

## Building and Testing

### Binaries

```sh
nix build .#nebula            # cmd/nebula
nix build .#nebula-cert       # cmd/nebula-cert
nix build .#nebula-service    # cmd/nebula-service

./result/bin/nebula -version
```

### Variants

| Attribute | Build flags | Matches `Makefile` target |
|---|---|---|
| `nebula`, `nebula-cert`, `nebula-service` | `CGO_ENABLED=0` | default `bin` |
| `nebula-boringcrypto`, ... | `GOEXPERIMENT=boringcrypto`, `CGO=1`, `-checklinkname=0` | `bin-boringcrypto` |
| `nebula-pkcs11`, ... | `CGO=1`, `-tags pkcs11` | `bin-pkcs11` |

### Tests via Nix

```sh
nix flake check -L                                       # all tiers
nix build .#checks.x86_64-linux.golangci-lint-quick      # tier 0 (~30s)
nix build .#checks.x86_64-linux.golangci-lint            # tier 1 (~2 min)
nix build .#checks.x86_64-linux.golangci-lint-comprehensive  # tier 2 (~10 min)
nix build .#checks.x86_64-linux.go-test-short
```

### Makefile passthroughs

The root Makefile gained a handful of Nix shims so non-Nix devs don't have
to learn the CLI:

```sh
make nix-shell          # nix develop
make nix-build          # nix build .#nebula .#nebula-cert .#nebula-service
make nix-image          # nix build .#nebula-image .#nebula-cert-image
make nix-check          # nix flake check -L
make nix-lint-quick     # tier-0 golangci-lint
make nix-vm-test        # nix run .#vm-test-mesh
```

## OCI Containers

```sh
nix build .#nebula-image
docker load < result
docker run --rm -v $(pwd)/config:/config nebulaoss/nebula:latest -test
```

The image is produced by `dockerTools.buildLayeredImage` and contains only
`cacert` + the nebula binary — a near-equivalent of the existing
`gcr.io/distroless/static` base. The entrypoint, `Cmd`, and `/config` volume
match the upstream `Dockerfile` exactly, so a `docker run` swap is
transparent.

`.#nebula-cert-image` is a separate image for offline CA / signing
operations.

## MicroVM Integration Testing

### Overview

The `vm-test-mesh` target boots two QEMU microVMs:

| Role | Hostname | Underlay IP | Overlay IP | Function |
|---|---|---|---|---|
| `lighthouse` | `nebula-lighthouse` | `192.168.42.1/24` | `10.42.0.1/24` | `am_lighthouse: true`, listens on UDP 4242 |
| `edge` | `nebula-edge` | `192.168.42.2/24` | `10.42.0.2/24` | static_host_map points at the lighthouse |

Both VMs share the host's `/nix/store` via a read-only 9P mount (xdp2's
pattern — no rootfs copying needed). They reach each other over the host
bridge `nebbr0` and use the standard nebula handshake to bring up the
`nebula1` overlay TUN.

The Nebula CA + role certs are generated in `nix/microvms/pki.nix` as a
single derivation consumed by both VMs through `environment.etc."nebula/*"`.

> Private keys for the test PKI live in `/nix/store` (world-readable). This
> is fine for the ephemeral test mesh — the keys never leave the test VMs —
> but do not adapt this exact pattern for a production PKI.

### Lifecycle phases

Each phase is its own `writeShellApplication`, so you can run any one in
isolation when triaging:

| # | Attr | Asserts |
|---|---|---|
| 0 | `vm-lifecycle-0-build` | `lighthouse-vm` + `edge-vm` derivations build |
| 1 | `vm-lifecycle-1-start` | both QEMU processes started, PIDs captured |
| 2 | `vm-lifecycle-2-serial-ready` | TCP serial console listeners up |
| 3 | `vm-lifecycle-3-virtio-ready` | virtio console listeners up |
| 4 | `vm-lifecycle-4-service-active` | `systemctl is-active nebula` on both nodes + `nebula1` link present |
| 5 | `vm-lifecycle-5-ping-overlay` | edge can `ping -c 5 10.42.0.1` (≥1 reply) |
| 6 | `vm-lifecycle-6-shutdown` | both VMs poweroff via console |
| 7 | `vm-lifecycle-7-wait-exit` | QEMU PIDs exit cleanly (SIGTERM/SIGKILL fallback) |

### Running the test

The two VMs talk over a Linux bridge on the host — `nebbr0` plus one TAP per
VM. Creating these requires root; the helper does it once per boot:

```sh
sudo nix run .#vm-network-setup-privileged    # one-time per host reboot
nix run .#vm-test-mesh                        # run the full mesh test
```

When you're done:

```sh
sudo nix run .#vm-network-teardown-privileged
```

### Phase-isolation triage

If `vm-test-mesh` fails, run the failing phase by itself with extra logs:

```sh
nix run .#vm-lifecycle-2-serial-ready
nix run .#vm-lifecycle-4-service-active
nix run .#vm-console-lighthouse              # attach to the live serial console
```

The per-VM logs are at `/tmp/nebula-vm-test/{lighthouse,edge}.log`.

### Expect-based automation

`nix/microvms/scripts/` contains three Expect scripts adapted from xdp2:

- `vm-expect.exp` — generic command runner with ANSI stripping and
  line-by-line buffering (avoids overflow on large outputs).
- `vm-verify-service.exp` — checks `systemctl is-active <service>`, then
  falls back to `journalctl -fu <service>` stream monitoring for slow
  starters. Parameterized so the same script verifies any unit.
- `vm-ping-overlay.exp` — runs `ping -c N -W 2 <target>` from the VM and
  asserts at least one reply was received.

## Static Analysis

Three tiers are configured. Repo's existing `.golangci.yaml` is left alone;
the Nix checks pass `--config nix/golangci/*.yml` explicitly, so IDE
workflows don't change.

| Tier | Attr | Runtime | Linters |
|---|---|---|---|
| 0 quick | `golangci-lint-quick` | ~30 s | gofmt, goimports, govet, errcheck, ineffassign, staticcheck, unused, copyloopvar, intrange |
| 1 standard (CI gating) | `golangci-lint` | ~2 min | tier 0 + gosec, gocritic, revive, contextcheck, sloglint, testifylint, unconvert, unparam, wastedassign, nilerr, perfsprint |
| 2 comprehensive (nightly) | `golangci-lint-comprehensive` | ~10 min | tier 1 + exhaustive, prealloc, gocyclo, funlen, goconst, dupl, bodyclose, errorlint, misspell, nakedret, nestif, noctx, rowserrcheck, sqlclosecheck, whitespace |

Standalone derivations alongside the tiers:

- `go-vet` — matches the existing `make vet`
- `staticcheck` — Dominik Honnef's checker stand-alone
- `govulncheck` — Go vulnerability scanner against the built `nebula` binary
- `gosec` — security scanner with documented exclusions
- `proto-fresh` — regenerates `nebula.pb.go` and `cert/cert_v1.pb.go` from
  source and fails on drift
- `nix-fmt` — `nixfmt --check` on every `.nix` file
- `statix` — Nix anti-pattern lint
- `deadnix` — unused bindings in Nix
- `go-test-short` — `go test -short ./...`

## Debugging

### Inspect a failing flake

```sh
nix flake show              # list every output
nix flake check --show-trace
```

### Inspect a derivation's build

```sh
nix build -L .#nebula                 # -L streams logs
nix build .#nebula --keep-failed      # leave $out/ for inspection
nix-store --read-log $(nix path-info --derivation .#nebula)
```

### Attach to a running VM

```sh
nix run .#vm-console-lighthouse       # serial console (nc 127.0.0.1 45001)
nix run .#vm-console-edge             # nc 127.0.0.1 45002
nix run .#vm-status                   # list which VMs are running
```

### Inspect generated nebula configs

The per-VM `config.yml` is rendered by `nix/microvms/base.nix:mkConfig`. To
see what each node ends up running:

```sh
nix build .#lighthouse-vm
find result -name 'config.yml' -exec cat {} \;
```

## Understanding the Environment

### Source of truth

All facts that vary per role live in `nix/constants.nix`:

```nix
roles = {
  lighthouse = { index = 1; shortName = "lh";   amLighthouse = true;  };
  edge       = { index = 2; shortName = "edge"; amLighthouse = false; };
};
```

`nix/lib.nix` derives MAC addresses, TAP names, underlay/overlay IPs,
console TCP ports, and per-arch timeouts from those indexes. Adding a third
node ("relay", say) is a single attrset entry in `constants.nix` — every
downstream derivation picks it up.

`nix/lib.nix` also runs **eval-time assertions**: it fails the build
immediately if two roles share an index, or if no role is named
`lighthouse`. This catches misconfiguration before any binary is built.

### Vendor hash workflow

`buildGoModule` requires a `vendorHash` because nebula does not check in a
`vendor/` directory. We use `lib.fakeHash` as the placeholder. The build
fails on first run with the correct sha256 in the error — paste it into the
three package files and rerun.

If you'd rather avoid that loop entirely, switch to
[gomod2nix](https://github.com/nix-community/gomod2nix) (commit
`gomod2nix.toml`). The current design opted for the lighter checked-in
surface.

## File Map

```
flake.nix                       # inputs + eachSystem wiring
nix/
  README.md                     # this file
  constants.nix                 # source of truth (versions, roles, networks)
  lib.nix                       # derived values + eval-time assertions
  shell.nix                     # dev shell
  checks.nix                    # tiered static analysis + standalone checks
  golangci/
    golangci-quick.yml          # tier 0
    golangci.yml                # tier 1
    golangci-comprehensive.yml  # tier 2
  packages/
    default.nix                 # variant matrix
    nebula.nix
    nebula-cert.nix
    nebula-service.nix
  containers/
    default.nix
    nebula.nix
    nebula-cert.nix
  microvms/
    default.nix
    base.nix                    # NixOS module per VM
    pki.nix                     # CA + role certs derivation
    lib.nix                     # polling/console helpers
    lifecycle.nix               # phases 0-7 + fullTest aggregate
    scripts/
      vm-expect.exp
      vm-verify-service.exp
      vm-ping-overlay.exp
  scripts/
    default.nix
    vm-network.nix              # bridge + TAP setup/teardown (privileged)
    vm-management.nix           # status, stop, console-{role}
  apps/
    default.nix                 # everything `nix run` can invoke
```
