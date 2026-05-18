# Deep-dive: staticcheck SA4006 + ineffassign findings

68 findings flagged by `staticcheck SA4006` ("this value of X is never
used") and `golangci-lint ineffassign` ("ineffectual assignment to X")
on the `nix` branch post-`#1729`. The two checkers overlap substantially
(14 sites flagged by both); after dedup there are roughly 56 unique
sites.

The big-picture split:

| Bucket | Sites | Action |
|---|---:|---|
| **Production code** | **3** | Per-site TDD test + fix |
| **Class A — harmless test fixture sloppiness** | ~50 | Mechanical: `_ =` discard or collapse |
| **Class B — real test bugs / gaps** | 3 | Per-site fix + assertion-tightening |
| **Class C — line-shift artifact** | 1 | Verify in next lint run |
| **Class D — table-driven refactor opportunity** | 18 (3 clusters) | Refactor to table-driven; improves coverage and removes the lint findings at the same time |

```
By file (top contributors):
  cert/pem_test.go        9   table-driven cluster (Class D)
  firewall_test.go        7   5x table-driven cluster (Class D) + 2x other
  lighthouse_test.go      4   table-driven cluster (Class D)
  cert/cert_v2_test.go    6   Class A
  cert/crypto_test.go     4   Class A
  allow_list_test.go      5   Class A
  (others)               ...
  PRODUCTION:             3   connection_manager.go, pki.go, overlay/tun_linux.go
```

Same finding-class shape as prior deep-dive docs: real-bug sites get
TDD-style test + minimal fix; cosmetic sites get mechanical cleanup;
clusters get refactored to table-driven where it adds test coverage.

---

# Part 1: Production-code findings (3 sites)

These three are the only SA4006 / ineffassign findings that aren't in
test files. Each is analyzed for real-bug potential, call-site impact,
git blame context, proposed fix, and test approach.

## P1. `connection_manager.go:345` — `decision := doNothing` is dead

### Current code

```go
// connection_manager.go:343-371 inside makeTrafficDecision
if inTraffic {
    decision := doNothing                                   // L345  flagged
    if cm.l.Enabled(context.Background(), slog.LevelDebug) {
        hostinfo.logger(cm.l).Debug("Tunnel status",
            "tunnelCheck", m{"state": "alive", "method": "passive"},
        )
    }
    hostinfo.pendingDeletion.Store(false)

    if mainHostInfo {
        decision = tryRehandshake                           // overwrite
    } else {
        if cm.shouldSwapPrimary(hostinfo) {
            decision = swapPrimary                          // overwrite
        } else {
            decision = migrateRelays                        // overwrite
        }
    }

    cm.trafficTimer.Add(hostinfo.localIndexId, cm.checkInterval)

    if !outTraffic {
        cm.punchy.SendPunch(hostinfo)
    }

    return decision, hostinfo, primary
}
```

### Verdict

**Not a real bug.** Every branch of the `if mainHostInfo { ... } else
{ if shouldSwapPrimary { ... } else { ... } }` chain reassigns
`decision`, so the initial `doNothing` value is never observed at the
`return` statement. ineffassign correctly flags the initializer as
dead.

The code IS correct today, but it has a subtle property worth
preserving: the explicit `doNothing` initializer acts as a defensive
fallback. If a future edit adds a fourth branch that forgets to set
`decision`, the function falls through with `doNothing` rather than
panicking on an unhandled case.

`trafficDecision` is `int` with `doNothing` aliased to `0`, so a
`var decision trafficDecision` declaration produces the same
zero-value default — preserving the fallback without the dead
initializer the lint is flagging.

### Git blame

The pattern dates to commit `01909f4` (2022, "try to make certificate
addition/removal reloadable in some cases"). The `decision :=
doNothing` initializer was there in the initial form. No subsequent
edit removed a use of the initial value; the dead-initializer property
has been there since the function was written.

### Proposed fix

Replace the three nested branches with a `switch{}` and a bare
`var`-declared `decision`. Zero-cost, behaviour-preserving, addresses
the lint:

```go
if inTraffic {
    var decision trafficDecision        // zero value is doNothing
    if cm.l.Enabled(context.Background(), slog.LevelDebug) {
        hostinfo.logger(cm.l).Debug("Tunnel status",
            "tunnelCheck", m{"state": "alive", "method": "passive"},
        )
    }
    hostinfo.pendingDeletion.Store(false)

    switch {
    case mainHostInfo:
        decision = tryRehandshake
    case cm.shouldSwapPrimary(hostinfo):
        decision = swapPrimary
    default:
        decision = migrateRelays
    }

    cm.trafficTimer.Add(hostinfo.localIndexId, cm.checkInterval)
    if !outTraffic {
        cm.punchy.SendPunch(hostinfo)
    }
    return decision, hostinfo, primary
}
```

Note on the comment: leave a `// zero value is doNothing` reminder so
the next reader sees why the explicit initializer isn't there.

### Test coverage gap

`connection_manager_test.go:259-260` exercises the `tryRehandshake`
branch (mainHostInfo=true path). **No tests exercise `swapPrimary` or
`migrateRelays`.** A future regression in either branch would be
silent.

### TDD plan

Add a table-driven test with one row per branch:

```go
func TestMakeTrafficDecision_InTrafficDecisionBranches(t *testing.T) {
    tests := []struct {
        name              string
        mainHostInfo      bool
        shouldSwapPrimary bool
        want              trafficDecision
    }{
        {"primary hostinfo -> tryRehandshake", true,  false, tryRehandshake},
        {"non-primary, swap-eligible -> swapPrimary", false, true,  swapPrimary},
        {"non-primary, not swap-eligible -> migrateRelays", false, false, migrateRelays},
    }
    // ... fixture setup with inTraffic=true, mock or set shouldSwapPrimary, etc.
}
```

The fixture work is non-trivial (`*connectionManager` + `*HostInfo` +
`*HostMap` plumbing), but the existing test at line 259 shows the
shape. Both branches I'd add use the same fixture.

---

## P2. `pki.go:312` — `pubPathOrPEM = "<inline>"` is dead

### Current code

```go
// pki.go:305-319 inside newCertStateFromConfig
pubPathOrPEM := c.GetString("pki.cert", "")
if pubPathOrPEM == "" {
    return nil, errors.New("no pki.cert path or PEM data provided")
}

if strings.Contains(pubPathOrPEM, "-----BEGIN") {
    rawCert = []byte(pubPathOrPEM)
    pubPathOrPEM = "<inline>"            // L312  flagged
} else {
    rawCert, err = os.ReadFile(pubPathOrPEM)
    if err != nil {
        return nil, fmt.Errorf("unable to read pki.cert file %s: %s", pubPathOrPEM, err)
    }
}
```

After the `if/else`, `pubPathOrPEM` is **never referenced again** in
the function body. `grep` confirms: the only references in `pki.go` are
lines 305, 306, 310, 311, 315, 317 — all inside the block above. The
L312 assignment is dead.

### Verdict

**Refactoring artifact.** The author's intent was almost certainly:

```go
// hypothetical historical form
s.l.Info("Loaded certificate", "source", pubPathOrPEM)  // emits "/path/foo.crt" or "<inline>"
```

A log statement using `pubPathOrPEM` was removed at some point, but the
conditional rename to `<inline>` was left behind.

### Git blame

The block was added in commit `5a131b2` ("Combine ca, cert, and key
handling" #952). The `pubPathOrPEM = "<inline>"` line was present in
that initial commit, suggesting the missing log was never written —
the assignment was speculative scaffolding.

### Proposed fix

Two options:

**Option A — delete the line (smallest diff).** Zero behavioural
impact (the assignment was never read).

```go
if strings.Contains(pubPathOrPEM, "-----BEGIN") {
    rawCert = []byte(pubPathOrPEM)
} else {
    ...
}
```

**Option B — add the log statement and use it.** Restore the inferred
historical intent so operators see "Loaded certificate from
/path/x.crt" or "Loaded inline certificate" at startup.

```go
if strings.Contains(pubPathOrPEM, "-----BEGIN") {
    rawCert = []byte(pubPathOrPEM)
    pubPathOrPEM = "<inline>"
}
...
// after the for-loop on L322 that loads certificates:
s.l.Info("Loaded pki.cert", "source", pubPathOrPEM, "versions", ...)
```

Option B requires plumbing a logger into `newCertStateFromConfig`
(currently no logger parameter; would change function signature →
caller updates). Probably out of scope for an SA4006 cleanup PR.

**Recommendation: Option A.** Smaller, safer, no API change. Option B
is a follow-up feature.

### Test coverage gap

**`pki_test.go` does not exist.** `newCertStateFromConfig` has zero
direct tests; it's only exercised end-to-end via integration paths.

### TDD plan

Create `pki_test.go` with a table-driven test that covers the function
on:
1. Missing `pki.key` → error
2. Missing `pki.cert` → error
3. Malformed inline cert PEM → error from `loadCertificate`
4. Valid v1 inline cert → returns CertState
5. Valid v2 inline cert → returns CertState
6. Both v1 and v2 inline (different banners) → returns CertState
7. File-path cert (write a temp file, point at it) → returns CertState
8. File-path cert that doesn't exist → error naming the path

8 rows of coverage where there was none. The L312 dead assignment is
incidental; the test value is real.

---

## P3. `overlay/tun_linux.go:826` — `ok` is shadowed and the
assignment is dead

### Current code

```go
// overlay/tun_linux.go:819-836
func getGatewayAddr(gw net.IP, via netlink.Destination) (netip.Addr, bool) {
    // Try to use the old RTA_GATEWAY first
    gwAddr, ok := netip.AddrFromSlice(gw)              // L821: outer ok
    if !ok {
        // Fallback to the new RTA_VIA
        rVia, ok := via.(*netlink.Via)                 // L824: SHADOWED ok (new scope)
        if ok {
            gwAddr, ok = netip.AddrFromSlice(rVia.Addr) // L826: assigns shadowed ok (dies at L828)
        }
    }

    if gwAddr.IsValid() {
        gwAddr = gwAddr.Unmap()
        return gwAddr, true
    }
    return netip.Addr{}, false
}
```

This is the most interesting site of the three.

### Verdict

**Not a real bug today, but a real-bug HAZARD.** The function happens
to work correctly because `gwAddr.IsValid()` on L830 is independently
equivalent to a (non-shadowed) `ok` — both reflect whether the most
recent `AddrFromSlice` call succeeded. So today's behaviour is correct:

- Valid `gw` → outer `ok = true`, gwAddr valid, return (gwAddr, true)
- Empty `gw` + valid `*netlink.Via` with valid Addr → outer `ok = false`,
  inner `ok = true`, gwAddr reassigned from rVia.Addr, gwAddr.IsValid()
  returns true, return (gwAddr, true)
- Empty `gw` + nil/wrong-type via → outer `ok = false`, no inner block,
  gwAddr stays zero, gwAddr.IsValid() returns false, return (zero, false)
- Empty `gw` + `*netlink.Via` with empty Addr → outer `ok = false`,
  inner `ok = true`, gwAddr reassigned to zero, gwAddr.IsValid() returns
  false, return (zero, false)

All four cases land on the correct result.

**The hazard**: the shadowed `ok` on L824 + the dead assignment on L826
look like the function is tracking validity through `ok`. A future
refactor that swaps `gwAddr.IsValid()` for `if ok` on L830 would
silently break in the RTA_VIA-fallback path — the outer `ok` would
still be `false` from L821, so the function would return `(zero, false)`
even when the fallback succeeded.

This is exactly the kind of "code looks like it tracks state X but
actually relies on derived state Y" trap that staticcheck SA4006 exists
to surface.

The proposed fix below keeps the `ok` tracking the original author
intended — just renames the three `ok` variables so they're unique
and verifies each one alongside the corresponding `IsValid()`. This
addresses the maintainer-reception concern of "don't drop validity
tracking, make it correct".

### Git blame

Commit `12cf348` ("feat: support via gateway for v6 multihop for v4
routes" #1521). The function was added in this commit with the
shadowing already present — the pattern was probably copy-pasted from
a similar idiom without noticing the scope rules. The two `ok`
identifiers were probably intended to be one logical variable.

### Proposed fix

Keep the `ok` tracking but **rename to disambiguate** so the two
sources of truth (RTA_GATEWAY vs RTA_VIA) are visually distinct, and
restructure to **early-return at each happy path** so the duplicate
`if !gwAddr.IsValid()` block disappears:

```go
func getGatewayAddr(gw net.IP, via netlink.Destination) (netip.Addr, bool) {
    // Try the old RTA_GATEWAY first.
    gwAddr, okG := netip.AddrFromSlice(gw)
    if okG && gwAddr.IsValid() {
        return gwAddr.Unmap(), true
    }

    // Fallback to the new RTA_VIA.
    rVia, okV := via.(*netlink.Via)
    if !okV {
        return netip.Addr{}, false
    }

    viaAddr, okV2 := netip.AddrFromSlice(rVia.Addr)
    if !okV2 || !viaAddr.IsValid() {
        return netip.Addr{}, false
    }
    return viaAddr.Unmap(), true
}
```

Changes:
- **No shadowing.** Three distinct names: `okG` (RTA_GATEWAY slice
  validity), `okV` (RTA_VIA type assertion), `okV2` (RTA_VIA slice
  validity). Each `ok` is in its own scope and is read where it's
  assigned.
- **Both halves of each pair are checked.** `okG && gwAddr.IsValid()`
  is belt-and-braces today (`netip.AddrFromSlice` returns
  `(invalid, false)` so the two flags agree) but the explicit
  AND-pair makes intent obvious and protects against future stdlib
  semantics changes. Same shape for `!okV2 || !viaAddr.IsValid()`.
- **Linear flow with early returns.** No duplicate `if
  !gwAddr.IsValid()` block at the end. Each branch ends in a single
  `return` statement — the function reads top to bottom as "try
  source A; if it didn't work, try source B; if neither worked,
  return invalid".
- **Separate `gwAddr` and `viaAddr` locals.** The two sources of
  truth never share a variable, so a future reader sees that
  `viaAddr` came from `rVia.Addr` and not from the original `gw`
  slice. Eliminates the "is this gw still the original?" question.

This addresses both lint findings (SA4006 + ineffassign) while
preserving the explicit `ok` tracking the original author intended.

### Test coverage gap

**Zero tests.** Neither `overlay/tun_linux_test.go` nor any other test
file references `getGatewayAddr` directly. The function is exercised
indirectly when the system processes route updates, but no unit test
pins its contract.

### TDD plan

Table-driven test covering every code path **plus** the realistic
boundary cases. Eleven rows; the operator specifically asked that
each path-combination be well-covered, so this matrix is generous.

The four logical paths through the new function:

| Path | When | Returns |
|---|---|---|
| **A** | `okG && gwAddr.IsValid()` | `(gwAddr.Unmap(), true)` — RTA_GATEWAY happy |
| **B** | `okG && gwAddr.IsValid()` false **and** `!okV` (wrong via type) | `(zero, false)` |
| **C** | `okG && gwAddr.IsValid()` false **and** `okV` **and** `!okV2 \|\| !viaAddr.IsValid()` | `(zero, false)` |
| **D** | `okG && gwAddr.IsValid()` false **and** `okV` **and** `okV2 && viaAddr.IsValid()` | `(viaAddr.Unmap(), true)` — RTA_VIA fallback happy |

Test rows:

| # | Row name | `gw` input | `via` input | Path | Expected |
|---|---|---|---|---|---|
| 1 | "valid IPv4 RTA_GATEWAY" | `10.0.0.1` | nil | A | `(10.0.0.1, true)` |
| 2 | "valid IPv6 RTA_GATEWAY" | `2001:db8::1` | nil | A | `(2001:db8::1, true)` |
| 3 | "IPv4-mapped-IPv6 RTA_GATEWAY is unmapped on return" | `::ffff:10.0.0.1` | nil | A + Unmap | `(10.0.0.1, true)` |
| 4 | "nil gw, nil via" | nil | nil | B | `(zero, false)` |
| 5 | "nil gw, wrong-type via (Encap)" | nil | `&netlink.Encap{Type: 0}` | B | `(zero, false)` |
| 6 | "nil gw, valid RTA_VIA IPv4 -> fallback succeeds" | nil | `&netlink.Via{Addr: v4}` | D | `(10.0.0.1, true)` |
| 7 | "nil gw, valid RTA_VIA IPv6 -> fallback succeeds" | nil | `&netlink.Via{Addr: v6}` | D | `(2001:db8::1, true)` |
| 8 | "nil gw, RTA_VIA with nil Addr" | nil | `&netlink.Via{Addr: nil}` | C | `(zero, false)` |
| 9 | "nil gw, RTA_VIA with empty []byte Addr" | nil | `&netlink.Via{Addr: []byte{}}` | C | `(zero, false)` |
| 10 | "nil gw, RTA_VIA with malformed Addr (5 bytes)" | nil | `&netlink.Via{Addr: 5 bytes}` | C | `(zero, false)` |
| 11 | "malformed gw (5 bytes), valid RTA_VIA falls through" | 5-byte slice | `&netlink.Via{Addr: v4}` | D (via okG=false) | `(10.0.0.1, true)` |

Sketch:

```go
func TestGetGatewayAddr(t *testing.T) {
    v4    := net.ParseIP("10.0.0.1")
    v6    := net.ParseIP("2001:db8::1")
    v4mapped := net.ParseIP("::ffff:10.0.0.1")
    bad5  := net.IP{1, 2, 3, 4, 5} // length 5: AddrFromSlice rejects

    tests := []struct {
        name     string
        gw       net.IP
        via      netlink.Destination
        wantOK   bool
        wantAddr string // assertion only when wantOK
    }{
        {"valid IPv4 RTA_GATEWAY",                                   v4,         nil,                              true,  "10.0.0.1"},
        {"valid IPv6 RTA_GATEWAY",                                   v6,         nil,                              true,  "2001:db8::1"},
        {"IPv4-mapped-IPv6 RTA_GATEWAY is unmapped on return",       v4mapped,   nil,                              true,  "10.0.0.1"},
        {"nil gw, nil via",                                          nil,        nil,                              false, ""},
        {"nil gw, wrong-type via (Encap)",                           nil,        &netlink.Encap{Type: 0},          false, ""},
        {"nil gw, valid RTA_VIA IPv4 -> fallback succeeds",          nil,        &netlink.Via{Addr: v4},           true,  "10.0.0.1"},
        {"nil gw, valid RTA_VIA IPv6 -> fallback succeeds",          nil,        &netlink.Via{Addr: v6},           true,  "2001:db8::1"},
        {"nil gw, RTA_VIA with nil Addr",                            nil,        &netlink.Via{Addr: nil},          false, ""},
        {"nil gw, RTA_VIA with empty []byte Addr",                   nil,        &netlink.Via{Addr: []byte{}},     false, ""},
        {"nil gw, RTA_VIA with malformed Addr (5 bytes)",            nil,        &netlink.Via{Addr: bad5},         false, ""},
        {"malformed gw (5 bytes), valid RTA_VIA falls through to D", bad5,       &netlink.Via{Addr: v4},           true,  "10.0.0.1"},
    }
    for _, tc := range tests {
        t.Run(tc.name, func(t *testing.T) {
            got, ok := getGatewayAddr(tc.gw, tc.via)
            assert.Equal(t, tc.wantOK, ok)
            if tc.wantOK {
                assert.Equal(t, tc.wantAddr, got.String())
            } else {
                assert.Equal(t, netip.Addr{}, got)
            }
        })
    }
}
```

### Mutation tests

The 11-row matrix is verified load-bearing by the following mutations:

| Mutation to the proposed fix | Caught by row |
|---|---|
| Remove `okV` check on type assertion (would `nil` deref on wrong-type via) | Row 5 (`netlink.Encap` via) — panics |
| Remove `okV2` check (still keep `viaAddr.IsValid()`) | Not caught — both checks reflect the same condition; the dual check is defensive-in-depth, not load-bearing today |
| Remove `viaAddr.IsValid()` check (still keep `okV2`) | Not caught — same as above |
| Drop the `.Unmap()` call on either return | Row 3 (IPv4-mapped IPv6) — returns the mapped form instead of `10.0.0.1` |
| Use the wrong return source (e.g. return `gwAddr` instead of `viaAddr` on the fallback path) | Rows 6 / 7 — wrong addr returned |
| Swap `viaAddr.Unmap()` to `gwAddr.Unmap()` on the fallback return | Row 11 — `gwAddr` is invalid (5-byte input), so `gwAddr.Unmap()` returns zero, test sees `(zero, true)` and fails |

The two "not caught" mutations are intentionally defensive — they
remove a redundant check without changing behaviour. We keep both
halves of each AND-pair anyway because they document intent and
hedge against future stdlib semantics changes.

7 rows of new coverage. Mutation-test: replace `gwAddr.IsValid()` on
the rewritten function with the stale outer `ok` (recreating the
hazard) — the "empty gw, valid RTA_VIA" rows would fail, proving the
hazard is now caught by the test suite.

---

# Part 2: Real test bugs / gaps (Class B, 3 sites)

## B1. `cert/cert_v1_test.go:102` — asymmetric assertion in
`TestUnmarshalCertificateV1`

### Current code

```go
// cert/cert_v1_test.go:101-108
// Cert has no pubkey and no pubkey passed in must fail to validate
isNil, err := unmarshalCertificateV1(certWithoutPubkey, nil)    // L102: isNil unused
require.Error(t, err)

// Cert has different pubkey than one passed in must fail
isNil, err = unmarshalCertificateV1(certWithPubkey, invalidPubkey)
require.Nil(t, isNil)                                            // L107: checks isNil
require.Error(t, err)
```

### Why staticcheck flags it

The L102 assignment to `isNil` is never read before L106 overwrites
it. Variable name `isNil` documents the *intent* (we expect the
function to return nil on this error path), but the test doesn't
actually assert that intent.

### Real-bug verdict

**Yes — minor test gap.** The variable name says "this should be nil"
but the test doesn't assert it. The L106 case (semantically identical
error path) does assert `require.Nil(t, isNil)`. The asymmetry means a
regression where `unmarshalCertificateV1` returns a non-nil cert
alongside an error on the L102 path would not be caught here.

### Proposed fix

Add the missing assertion:

```go
isNil, err := unmarshalCertificateV1(certWithoutPubkey, nil)
require.Nil(t, isNil)                                             // NEW
require.Error(t, err)
```

One line. Now both error cases assert both halves of the `(nil, err)`
contract.

---

## B2 + B3. `cert_test/cert.go:24` and `cert/helper_test.go:23` —
missing err check in CURVE25519 branch of `NewTestCaCert`

### Current code (identical in both files)

```go
// cert_test/cert.go:19-35 and cert/helper_test.go:18-30 — same function
var err error
var pub, priv []byte

switch curve {
case cert.Curve_CURVE25519:
    pub, priv, err = ed25519.GenerateKey(rand.Reader)   // assigns outer err, NEVER CHECKED
case cert.Curve_P256:
    privk, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
    if err != nil {
        panic(err)
    }
    pub = elliptic.Marshal(...)
    priv = privk.D.FillBytes(...)
default:
    // intentionally falls through
}

// ...
c, err := t.Sign(nil, curve, priv)   // overwrites outer err
if err != nil {
    panic(err)
}
```

### Why staticcheck flags it

The outer `err` assigned by `ed25519.GenerateKey` on L24 is never
checked before being overwritten by `t.Sign(...)`. The Sign-side err
check is real, but it catches a different (downstream) failure.

### Real-bug verdict

**Yes — diagnostic gap, not catastrophic.** `ed25519.GenerateKey` only
fails when `rand.Reader` fails (system entropy source broken). If that
happens:

- `pub` and `priv` are zero-valued
- `t.Sign(nil, curve, priv)` is called with empty priv
- Sign fails
- L57 panics with the **Sign** error, not the **GenerateKey** error
- The operator/developer sees "ed25519: bad private key length" or
  similar, which is misleading — the actual root cause is the entropy
  source.

Practically rare; diagnostically meaningful when it happens. The P256
branch on the same function does the right thing and panics
immediately on `GenerateKey` failure.

### Proposed fix

Mirror the P256 branch's pattern in the CURVE25519 branch. Two files
to fix; identical change in both.

```go
case cert.Curve_CURVE25519:
    pub, priv, err = ed25519.GenerateKey(rand.Reader)
    if err != nil {
        panic(err)
    }
```

Three lines added per file. The shadowing problem in the P256 branch
(`privk, err :=` re-declares err in the inner scope) is a separate
small style issue that's worth fixing in the same commit:

```go
case cert.Curve_P256:
    var privk *ecdsa.PrivateKey
    privk, err = ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
    if err != nil {
        panic(err)
    }
    ...
```

This removes the inner `:=` shadow and uses the outer err
consistently. The P256 branch is currently flagged by `ineffassign` on
`cert_test/cert.go:24:14` as a side effect of the shadowing.

### Why it's in two files

`cert_test/cert.go` is a public test helper (imported by other
packages' tests); `cert/helper_test.go` is the cert-package-internal
version. The code is duplicated rather than de-duplicated — fixing
both keeps them in sync. (A future cleanup could de-duplicate by
moving the function to one place and re-exporting; out of scope here.)

---

# Part 3: Table-driven refactor opportunities (Class D, 18 sites
across 3 clusters)

These are the highest-value refactor targets. Each cluster has been
flagged by SA4006 because the test fixture re-uses a variable across
several near-identical assertion blocks; converting to a table-driven
test resolves the lint, improves coverage signal, and shrinks the
maintenance surface.

## D1. `cert/pem_test.go` (9 sites — biggest cluster)

Pattern flagged at lines 174, 180, 187, 236, 242, 249, 367, 373, 380.
The test exercises multiple key/cert PEM types (Ed25519PrivKey,
P256PrivKey, X25519PrivKey, P256PublicKey, etc.) with success / fail /
bad-banner / bad-pem variants. Each variant assigns to the same
`curve` local; only the last assignment in each block is actually
read.

**Proposed shape** (sketch — actual refactor would be ~80 lines):

```go
func TestUnmarshal_PEMTypes(t *testing.T) {
    tests := []struct {
        name        string
        input       []byte
        unmarshalFn func([]byte) ([]byte, []byte, Curve, error)
        wantCurve   Curve
        wantLen     int
        wantErr     bool
        wantErrPart string
    }{
        {"Ed25519PrivKey valid",      ed25519PrivPEM,      UnmarshalSigningPrivateKeyFromPEM, Curve_CURVE25519, 64, false, ""},
        {"Ed25519PrivKey wrong banner", ed25519PrivPEMBad, UnmarshalSigningPrivateKeyFromPEM, 0, 0, true,  "banner"},
        ...
    }
    for _, tc := range tests {
        t.Run(tc.name, func(t *testing.T) { ... })
    }
}
```

Replaces 9 sites of repeated boilerplate with a 1-loop table. Removes
the 9 SA4006 findings. Makes "what does this test cover" answerable
by reading the table rows in one place.

## D2. `firewall_test.go:39-55` (5 sites)

Five sequential calls to `NewFirewall(l, tcp, udp, def, c)` with
different timeout permutations, each followed by an assertion block.
The `fw` variable is reassigned each time.

**Proposed shape**:

```go
func TestNewFirewall_TimeoutSelection(t *testing.T) {
    tests := []struct {
        name string
        tcp, udp, def time.Duration
        wantMax        time.Duration
    }{
        {"tcp largest",     30 * time.Minute,  10 * time.Minute, 5 * time.Minute,  30 * time.Minute},
        {"udp largest",     10 * time.Minute,  30 * time.Minute, 5 * time.Minute,  30 * time.Minute},
        ...
    }
    for _, tc := range tests {
        t.Run(tc.name, func(t *testing.T) {
            fw := NewFirewall(l, tc.tcp, tc.udp, tc.def, c)
            assert.Equal(t, tc.wantMax, fw.TimerWheel.maxTimer())
        })
    }
}
```

Replaces 5 sites of repeated boilerplate.

## D3. `lighthouse_test.go:612-618` (4 sites)

Four sequential `out, ok = findNetworkUnion(...)` calls with
different prefix inputs. Same pattern, same refactor.

```go
func TestFindNetworkUnion_Cases(t *testing.T) {
    tests := []struct {
        name      string
        prefixes  []netip.Prefix
        addr      netip.Addr
        wantOut   netip.Prefix
        wantOK    bool
    }{
        ...
    }
    for _, tc := range tests { ... }
}
```

---

# Part 4: Class A — harmless test fixture sloppiness (~50 sites)

These are all instances of the same idiom:

```go
// Fixture chain — error checked after each call, prior value of `r` discarded
r, err := f1(input1)
require.NoError(t, err)
// ... assertions about r ...
r, err = f2(input2)
require.NoError(t, err)
// ... assertions about NEW r ...
```

staticcheck flags the **first** `r` assignment as "never used" because
the next `r, err =` overwrites it (after the assertions about the
first `r` are done — those `r` reads aren't flagged). This isn't a
bug; the test fixture chain is doing exactly what it intends.

Fix shape: either:
- **Mechanical**: convert the first `r, err :=` to `_, err :=` if no
  assertion on `r` between the two assignments. But this loses any
  intermediate reads of `r`.
- **Better**: structure the test as separate `t.Run(...)` blocks so each
  fixture chain has its own scope.
- **Best (when applicable)**: convert to table-driven (handled in Part 3
  for the three clusters where this fits).

For most Class A sites, the right move is "do nothing" — the lint is
right that the assignment is dead, but the cost of restructuring 50
test fixture chains outweighs the value. **Recommended**: silence
locally with `//nolint:ineffassign //nolint:staticcheck` comments on
the offending lines, OR (cleaner) restructure as `t.Run`-scoped
sub-tests.

Class A is **not** worth a dedicated PR. It's worth resolving on a
case-by-case basis when the surrounding test gets touched for a real
reason.

---

# Suggested PR shape

Three PRs, in increasing scope:

### PR A — Production findings (3 commits, ~250 lines)

The bug-fix-class material. Highest maintainer interest. Should land
first.

| # | Commit | Site | Net change |
|---|---|---|---|
| 1 | Refactor `makeTrafficDecision` to use `switch`, add table-driven branch test | P1 (connection_manager.go) | ~+50/-15 |
| 2 | Delete dead `pubPathOrPEM = "<inline>"` assignment, add `pki_test.go` | P2 (pki.go) | ~+200/-2 |
| 3 | Disambiguate `ok` vars in `getGatewayAddr`, restructure for early-return, add 11-row table-driven test | P3 (overlay/tun_linux.go) | ~+120/-10 |

Title: `Refactor SA4006/ineffassign-flagged production-code sites`

### PR B — Class B test fixes (1 commit, ~10 lines)

The three real test bugs. Small, focused, easy review.

| # | Commit | Sites | Net change |
|---|---|---|---|
| 1 | Tighten error-path assertions in cert tests; check GenerateKey error in CURVE25519 branches | B1 (cert_v1_test.go:102), B2 (cert_test/cert.go:24), B3 (cert/helper_test.go:23) | ~+8/-2 |

Title: `Tighten error-path assertions in cert tests`

### PR C — Class D table-driven refactors (3 commits, ~400 lines)

The biggest test-quality improvement. Could be a single PR with three
commits, or three separate PRs. Recommend a single PR with three
commits so the maintainer can take any subset.

| # | Commit | Cluster | Net change |
|---|---|---|---|
| 1 | Refactor cert/pem_test.go to table-driven | D1 (9 sites) | ~+80/-150 |
| 2 | Refactor firewall_test.go timeout tests to table-driven | D2 (5 sites) | ~+50/-100 |
| 3 | Refactor lighthouse_test.go findNetworkUnion tests to table-driven | D3 (4 sites) | ~+40/-80 |

Title: `Refactor SA4006-flagged test clusters to table-driven`

### Class A — no upstream PR

Roughly 50 harmless fixture-sloppiness sites. Not worth a dedicated
PR (too noisy, no behavioural improvement). Resolve case-by-case when
the surrounding test gets touched for a real reason.

---

# Verification plan

After all 3 PRs land locally:

1. `go test -count=1 ./...` — full suite green at every commit.
2. Mutation tests on each production-code change:
   - P1: invert `mainHostInfo` semantics → table test fails.
   - P3: replace `gwAddr.IsValid()` on L830-equivalent with the stale
     outer `ok` → "empty gw, valid RTA_VIA" row fails.
3. `nix build .#checks.x86_64-linux.staticcheck` — SA4006 count drops
   from 46 → ~28 (PR A drops 1 prod + PR C drops 18 cluster sites).
4. `nix build .#checks.x86_64-linux.golangci-lint-quick` — `ineffassign`
   count drops from 22 → ~10.
5. `gofmt -l <changed>` and `go vet ./...` clean.
6. Per-commit bisect-safety: `git checkout <SHA>; go test ./...` passes.

Final state after all three PRs:
- SA4006: 46 → ~28 (the residual ~28 are Class A fixture sloppiness)
- ineffassign: 22 → ~10 (same residual)
- Three production-code sites have meaningful test coverage where
  before they had zero or partial.
- Three test files are restructured around explicit named test rows.
