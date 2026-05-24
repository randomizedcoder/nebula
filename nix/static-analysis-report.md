# Nebula Static Analysis Baseline Report

A baseline snapshot of every check the nix flake exposes, run against the
current `nix` branch with no prior cleanup. The intent is to (a) prove the
pipeline is producing real signal and (b) give a triage starting point.

## Run metadata

| Field | Value |
|---|---|
| Date (UTC) | 2026-05-16 |
| Branch | `nix` |
| Working tree | dirty (this report itself + tooling tweaks) |
| Go toolchain | `go1.26.2 linux/amd64` (from `pkgs.go_1_26`) |
| nixpkgs lock | `d233902339c02a9c334e7e593de68855ad26c4cb` (nixos-unstable, 2026-05-15) |
| golangci-lint | 2.12.2 |
| staticcheck | 2026.1 (v0.7.0) |
| gosec | 2.26.1 |
| govulncheck | 1.3.0, DB `https://vuln.go.dev` |
| nixfmt | 1.2.0 |
| deadnix | 1.3.1 |
| statix | (no `--version`) |
| expect | 5.45.4 |

Reproduction: `for c in nix-fmt statix deadnix go-vet staticcheck gosec proto-fresh go-test-short golangci-lint-quick golangci-lint golangci-lint-comprehensive; do nix build -L .#checks.x86_64-linux.$c; done` and `nix run .#govulncheck-nebula`.

## Executive summary

| Check | Status | Issues | Wall-clock |
|---|---|---|---|
| `nix-fmt` | PASS | 0 | 1 s |
| `statix` | PASS | 0 | 1 s |
| `deadnix` | PASS | 0 | 1 s |
| `go-vet` | PASS | 0 | 11 s |
| `staticcheck` | FAIL | 137 | 15 s |
| `gosec` | FAIL | **57** (7 HIGH, 2 MED, 48 LOW) | 33 s |
| `proto-fresh` | FAIL | drift in `cert/cert_v1.pb.go` from upstream protoc-gen-go version | 8 s |
| `go-test-short` | PASS | 15 pkgs green | 16 s |
| `golangci-lint-quick` (Tier 0) | FAIL | 143 | 15 s |
| `golangci-lint` (Tier 1) | FAIL | 255 | 17 s |
| `golangci-lint-comprehensive` (Tier 2) | FAIL | 422 | 16 s |
| `govulncheck-nebula` (audit app) | FAIL | 8 stdlib CVEs | ~50 s |

The nix-side checks (`nix-fmt`, `statix`, `deadnix`) are clean by construction — the flake's own files pass every nix-level linter. The Go-side checks fail because they surface pre-existing findings in nebula's source; this is the intended "pedantic" behavior. See `nix/findings-nilerr-and-gosec.md` for the deep-dive on `nilerr` + `gosec` HIGH findings.

`proto-fresh` currently flags drift in `cert/cert_v1.pb.go` — the committed file was generated with `protoc-gen-go v1.34.2`/`protoc v3.21.5` (per its header comment), while the locked nixpkgs ships `protoc-gen-go v1.36.11`/`protoc v34.1`. The drift is real but version-driven, not "you forgot to regenerate". Regenerating with `nix develop -c bash -c 'cd cert && protoc --go_out=. --go_opt=paths=source_relative cert_v1.proto'` is a one-line behavioral change (newer protoc-gen-go emits the `protogen:"open.v1"` struct tags) and is best handled separately from this flake addition.

## Detailed findings

### golangci-lint tier 0 — quick (143 issues)

The cheapest tier and the recommended PR gate. Every issue here is something `staticcheck` or basic correctness linters can statically prove.

| Linter | Issues |
|---|---:|
| `errcheck` | 50 |
| `staticcheck` | 50 |
| `ineffassign` | 22 |
| `unused` | 12 |
| `intrange` | 6 |
| `copyloopvar` | 1 |
| `gofmt` | 1 |
| `govet` | 1 |

**Representative samples**

```
cmd/nebula-cert/ca.go:201:17    Error return value of `errOut.Write` is not checked (errcheck)
cmd/nebula-cert/ca.go:358:11    Error return value of `out.Write` is not checked (errcheck)
overlay/route.go:312:6          func ipWithin is unused (unused)
overlay/tun.go:85-119           prefixToMask / flipBytes / orBytes / getBroadcast / selectGateway all unused
scheduler_test.go:71:3          The copy of the 'for' variable "i" can be deleted (Go 1.22+) (copyloopvar)
test/assert.go:75:7             inline: Constant reflect.Ptr should be inlined (govet)
```

### golangci-lint tier 1 — standard (255 issues, CI gating recommended)

Adds correctness-and-style linters on top of tier 0.

| Linter | Issues |
|---|---:|
| (tier-0 linters above) | 142 |
| `revive` | 30 |
| `unparam` | 23 |
| `gocritic` | 18 |
| `perfsprint` | 14 |
| `contextcheck` | 9 |
| `gosec` | 7 |
| `nilerr` | 6 |
| `wastedassign` | 4 |
| `unconvert` | 3 |

**Representative `nilerr` findings (these are real bugs — code observes a non-nil error then returns `nil`):**

```
config/config.go:334:3   error is not nil (line 332) but it returns nil (nilerr)
ssh.go:463:4             error is not nil (line 461) but it returns nil (nilerr)
ssh.go:513:4             error is not nil (line 511) but it returns nil (nilerr)
ssh.go:871:4             error is not nil (line 869) but it returns nil (nilerr)
ssh.go:879:5             error is not nil (line 876) but it returns nil (nilerr)
```

### golangci-lint tier 2 — comprehensive (422 issues, nightly)

Adds style/complexity linters intended to surface long-term tech debt.

| New in tier 2 | Issues |
|---|---:|
| `goconst` | 50 |
| `nestif` | 40 |
| `exhaustive` | 16 |
| `dupl` | 11 |
| `errorlint` | 10 |
| `gocyclo` | 10 |
| `prealloc` | 10 |
| `whitespace` | 6 |
| `noctx` | 5 |
| `funlen` | 4 |
| `nakedret` | 2 |
| `misspell` | 1 |

**Representative `gocyclo` findings (functions above complexity 25):**

```
cmd/nebula-cert/sign.go:65       signCert                       complexity 86
cmd/nebula-cert/ca.go:84         ca                             complexity 67
lighthouse.go:171                (*LightHouse).reload           complexity 59
main.go:23                       Main                           complexity 36
overlay/route.go:149             parseUnsafeRoutes              complexity 36
outside.go:25                    (*Interface).readOutsidePackets complexity 31
cert/cert_v2.go:641              unmarshalDetails               complexity 29
firewall.go:319                  AddFirewallRulesFromConfig     complexity 29
```

**`funlen` findings** (4 — three tests above 100 stmts, one runtime function):

```
ssh.go:201                       attachCommands  231 lines (limit 200)
cmd/nebula-cert/sign_test.go:64  Test_signCert   259 stmts  (limit 100)
outside_test.go:98               Test_newPacket_v6 133 stmts (limit 100)
cmd/nebula-cert/ca_test.go:68    Test_ca         126 stmts  (limit 100)
```

### staticcheck (standalone) — 137 issues

| Rule | Count | Meaning |
|---|---:|---|
| SA4006 | 47 | value of an assignment is never used |
| S1019 | 19 | simpler `make` form available |
| S1002 | 18 | unneeded comparison with bool constant |
| U1000 | 16 | unused functions / fields |
| SA1019 | 9 | use of deprecated API |
| SA4003 | 8 | comparison never produces the desired result |
| S1039 | 8 | unnecessary `fmt.Sprintf` |
| S1023 | 7 | redundant return statement |
| S1001 | 5 | use `copy()` instead of explicit loop |
| S1011 | 4 | use `append(a, b...)` instead of loop |

There is substantial overlap with the `staticcheck` linter inside golangci-lint
(both show 50 issues there). The standalone derivation surfaces more because
golangci-lint's `staticcheck` integration disables some rules by default.

### gosec — 57 issues

The check now correctly exits non-zero on findings (the earlier `|| true`
shim was removed). With 57 issues across the codebase, `nix flake check`
fails until they are triaged — that is the intended pedantic behavior.

**HIGH severity (7) — by site:**

```
cert/crypto.go:74                G407 Use of hardcoded IV/nonce for encryption
cmd/nebula/notify_linux.go:22    G704 SSRF via taint analysis
cmd/nebula-cert/stdio.go:110     G703 Path traversal via taint analysis
firewall.go:1071                 G109 strconv.Atoi → int16/32 overflow (2x)
firewall.go:1092                 G109 strconv.Atoi → int16/32 overflow
firewall.go:1093                 G109 strconv.Atoi → int16/32 overflow
```

**MEDIUM (2)** — `G112` HTTP `ReadHeaderTimeout` not set on `stats.go:304`; `G301` directory perms wider than 0750 in `overlay/tun_linux.go:257`.

**LOW (48)** — 36 × G104 (unchecked error from `Write`/`Printf`-style calls), 12 × G103 (audited unsafe calls in `udp/`, `overlay/`). Several G103 sites are intentional — they're the OS-specific zero-copy paths.

> Many of these (notably the G109 strconv→int16 conversions and the G407 hardcoded-nonce path) likely have justified explanations in the code's design, but they should be reviewed and either annotated with `//nolint:gosec` or refactored to make the intent unambiguous.

### govulncheck (audit, app) — 8 stdlib CVEs

All 8 vulnerabilities are in the Go standard library and **all are `Fixed in: go1.26.3`**. The locked nixpkgs ships Go 1.26.2; one `nix flake update` after 1.26.3 lands in nixos-unstable should clear every entry.

| ID | Affects | Symbol surface |
|---|---|---|
| GO-2026-4918 | `net/http` HTTP/2 SETTINGS_MAX_FRAME_SIZE | `http.Client.{Do,Get,Head,Post,...}` |
| GO-2026-4971 | `net` Dial/LookupPort on Windows NUL | `net.{Dial,DialTimeout,Listen,...}` |
| GO-2026-4976 | `net/http/httputil` ReverseProxy | `httputil.ReverseProxy.ServeHTTP` |
| GO-2026-4977 | `net/mail` |  |
| GO-2026-4980 | `html/template` |  |
| GO-2026-4981 | `net` |  |
| GO-2026-4982 | `html/template` |  |
| GO-2026-4986 | `net/mail` |  |

No third-party module CVEs were found.

### statix / deadnix — clean

The flake's own .nix files pass `statix check .` and `deadnix --fail` with
no findings. Repeated-key warnings were resolved by consolidating
`networking.*` and `environment.*` into single attribute sets in
`nix/microvms/base.nix`; the assignment-vs-inherit warnings were converted
to `inherit` forms throughout.

### go-vet — clean

Runs across all packages including `cmd/nebula{,cert,-service}`, `service`,
`examples/go_service`. No issues.

### go-test-short — clean (15 packages)

`go test -short -count=1 ./...` passes in the sandbox with the staged
vendor directory. Packages exercised:

```
cert (cert_v1/v2/test), config, firewall, handshake, header, iputil,
logging, noiseutil, overlay, routing, service, util
```

### nix-fmt — clean

Every `.nix` file in the tree round-trips through `nixfmt`.

### proto-fresh — now hermetic, flagging real drift

`protoc-gen-gogofaster` is now built as a shared derivation
(`nix/protoc-gen-gogofaster.nix`) and consumed by both `nix/shell.nix` and
the `proto-fresh` check, so the regeneration runs entirely inside the nix
sandbox (no `proxy.golang.org` fetches). The check correctly diffs the
regenerated `.pb.go` against the committed copy and exits non-zero on drift.

Current drift: `cert/cert_v1.pb.go` was generated with an older
`protoc-gen-go` than what nixpkgs ships. See the executive summary above for
the regeneration command.

## Triage recommendation

Suggested order of work, biggest-leverage first:

1. **`nilerr` (6) — real bugs.** Functions in `config/config.go` and `ssh.go`
   observe a non-nil error then return `nil`. Each one risks masking a real
   failure path. Fix or annotate.

2. **`gosec` HIGH (7) — security audit.** Especially `G407` hardcoded
   nonce in `cert/crypto.go:74` and `G703` path traversal in
   `cmd/nebula-cert/stdio.go:110`. Most are likely safe by construction; annotate with `//nolint:gosec` + reason.

3. **`errcheck` (50)** — many are intentional (`*.Write` after format failures,
   `defer file.Close()`). Decide per-package whether to fix or annotate
   with `//nolint:errcheck`. Establishing a "no new errcheck violations"
   gate on Tier 0 is realistic.

4. **`unused` (12) + staticcheck `U1000` (16)** — net of overlap, roughly
   20 unique dead-code sites including `overlay/tun.go:85-119` IPv4-mask
   helpers and `pkclient/pkclient.go:53,61` EC-key helpers. Either delete
   or wire them up.

5. **Tier 0 cleanup overall (143 issues)** — once `errcheck` and `unused`
   are triaged, the rest is mechanical: `ineffassign` (22) and `intrange` (6)
   and `staticcheck` simplifications.

6. **Tier 2 only after Tier 1 is clean.** `goconst`/`nestif`/`gocyclo`
   findings are largely stylistic in a codebase this size; they're useful
   as nightly tripwires rather than PR gates.

## Upstream submission status (as of 2026-05-23)

The triage above has begun landing as upstream PRs. Counts in the executive summary are still pinned to the 2026-05-16 snapshot; this section tracks what has moved against that baseline.

### Merged

| PR | Title | Findings closed |
|---|---|---|
| [slackhq/nebula#1724](https://github.com/slackhq/nebula/pull/1724) | Reject port numbers outside [0, 65535] in firewall rule parsing | 3 × `gosec` G109 (firewall.go:1071, 1092, 1093) |

### Open (split-by-subsystem, after upstream review feedback)

The first round (two cross-subsystem PRs, #1725 + #1726) was closed in favor of three smaller subsystem PRs after @JackDoan asked for "separate PRs for config, ssh, and DNS improvements". For the `ssh.go` swallow sites originally proposed with `fmt.Errorf("...: %w", err)` propagation, the rewrite uses log+meter at the swallow site instead, since the dispatcher at `sshd/session.go:171` discards the return.

| PR | Title | Findings closed |
|---|---|---|
| [slackhq/nebula#1737](https://github.com/slackhq/nebula/pull/1737) | Surface previously-swallowed errors from config path resolution | 1 × `nilerr` (config/config.go:334) + 1 × `errcheck` (`addFile` return discarded) |
| [slackhq/nebula#1738](https://github.com/slackhq/nebula/pull/1738) | Log and meter previously-swallowed dns_server WriteMsg failures | 1 × `errcheck` G104 (`dns_server.go` `w.WriteMsg`) |
| [slackhq/nebula#1739](https://github.com/slackhq/nebula/pull/1739) | Log and meter previously-swallowed SSH protocol and output-encode failures | 5 × `nilerr` (all swallow sites in `ssh.go`) + 3 × `errcheck` G104 (`sshd/session.go` reply/send-request sites) |

### Closed (superseded)

| PR | Why |
|---|---|
| [slackhq/nebula#1725](https://github.com/slackhq/nebula/pull/1725) | Closed in favor of #1737 + #1739; per-subsystem split with `ssh.go` reworked to log+meter |
| [slackhq/nebula#1726](https://github.com/slackhq/nebula/pull/1726) | Closed in favor of #1737 + #1738 + #1739; per-subsystem split |

### Cumulative coverage against the 2026-05-16 baseline

- **`nilerr`**: all 6 sites are now covered by #1737 (1 site) and #1739 (5 sites). Both PRs are open, not yet merged.
- **`gosec` HIGH**: 3 of 7 closed by merged #1724. Remaining 4 (G407, G704, G703, one G109) are untouched.
- **`errcheck` G104**: 4 of 50 covered by the three open PRs (sshd/session × 3, dns_server × 1).

## Repro one-liner

```sh
# All checks in parallel (mostly cached after first run)
nix flake check -L

# Or one at a time
nix build -L .#checks.x86_64-linux.golangci-lint-quick     # ~15s, 143 issues
nix build -L .#checks.x86_64-linux.golangci-lint           # ~17s, 255 issues
nix build -L .#checks.x86_64-linux.golangci-lint-comprehensive   # ~16s, 422 issues
nix build -L .#checks.x86_64-linux.staticcheck             # ~15s, 137 issues
nix build -L .#checks.x86_64-linux.gosec                   # ~33s, 57 issues (currently exits 0)
nix run .#govulncheck-nebula                               # ~50s online, 8 stdlib CVEs
```
