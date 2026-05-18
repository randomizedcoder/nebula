# Deep-dive: gosec MEDIUM + staticcheck SA4003 findings

Three small finding classes, captured from the post-`#1726` baseline on the
`nix` branch (run on 2026-05-17):

```
stats.go:304               G112  HTTP server has no ReadHeaderTimeout    (Severity: MEDIUM)
overlay/tun_linux.go:257   G301  Dir perms expected <=0750, got 0755     (Severity: MEDIUM)
cert/crypto.go:235         SA4003 no value of type int32 < math.MinInt32
cert/crypto.go:235         SA4003 no value of type int32 > math.MaxInt32
cert/crypto.go:238         SA4003 no value of type uint32 > math.MaxUint32
cert/crypto.go:244         SA4003 no value of type uint32 > math.MaxUint32
message_metrics.go:22      SA4003 every value of type uint8 is >= 0       (twice on same line)
message_metrics.go:31      SA4003 every value of type uint8 is >= 0       (twice on same line)
```

The G112 finding is the most consequential — it's the only externally-reachable
defensive gap of the three, and the fix is non-trivial because nebula's
Prometheus listener can be exposed cross-host. The other two are either a
likely false-positive (`G301` on `/dev/net`) or dead defensive code
(`SA4003`). This doc walks each in turn.

## Summary

| Class | Sites | Class of fix |
|---|---:|---|
| **G112** — HTTP server has no `ReadHeaderTimeout` | 1 | Add `http.Server` timeouts + (optionally) per-request `http.TimeoutHandler` wrap. Make values configurable. |
| **G301** — `/dev/net` directory perms 0755 | 1 | False positive (matches OS convention, doesn't affect tun-device security which is gated by the 0600 device-node perms). Annotate `//nosec G301` with rationale. |
| **SA4003** — dead bounds-check comparisons | 8 | Remove the always-false halves of the OR clauses; keep the real guard half. |

---

# Part 1: G112 — `stats.go:304` Prometheus listener has no timeouts

## Current code

```go
// stats.go:302-304 — inside (statsServer).buildRuntime, "prometheus" case
mux := http.NewServeMux()
mux.Handle(cfg.prom.path, promhttp.HandlerFor(pr, promhttp.HandlerOpts{ErrorLog: errLog}))
return captureFns, &http.Server{Addr: cfg.prom.listen, Handler: mux}
```

That's the entire `http.Server` construction. The `ReadHeaderTimeout`,
`ReadTimeout`, `WriteTimeout`, and `IdleTimeout` fields are all the zero
value, which Go interprets as "no limit". The listener is started by
`serveListener` (line 211) via `ListenAndServe` and is gracefully drained
via `Shutdown(ctx)` on `s.ctx.Done()` or `Stop()`.

## What gosec is actually warning about

> G112: Potential Slowloris Attack because ReadHeaderTimeout is not
> configured in the http.Server

Slowloris is a low-bandwidth denial-of-service technique:

1. The attacker opens a normal TCP connection to the HTTP listener.
2. The attacker writes the request line (`GET /metrics HTTP/1.1\r\n`).
3. The attacker writes **one header byte** every 30 seconds, never
   completing the request.
4. The Go HTTP server's read loop sits in `bufio.Reader.ReadLine` waiting
   for `\r\n` that never arrives. Because the server has no
   `ReadHeaderTimeout`, the connection's read goroutine is parked forever.
5. The attacker repeats from 1 across thousands of connections. Each one
   costs near-zero on the attacker side (tens of bytes per minute) but
   ties up one FD + one goroutine on the server side.

The defense is straightforward: bound the time spent in the "read headers"
phase. After `ReadHeaderTimeout` elapses, the Go HTTP server tears down
the connection and reclaims the FD.

## Threat model for nebula's prom endpoint

Three deployment shapes worth thinking about:

1. **Localhost-only** — `cfg.prom.listen = "127.0.0.1:8080"`. The only
   processes that can hit the endpoint are local ones. Slowloris from
   localhost is functionally a self-DoS — if you trust the local node
   enough to run nebula on it, you trust it not to slowloris itself.
   Risk: minimal. But the localhost-only deployment shape is **not**
   what nebula's docs assume.
2. **Bound to a Nebula overlay address** — `cfg.prom.listen = "10.42.0.1:8080"`.
   Only overlay peers (authenticated by certs) can hit it. Trust boundary
   is the overlay membership — usually significantly smaller than the
   internet but still a multi-tenant trust surface. Risk: small but real.
3. **Bound to a public interface** — `cfg.prom.listen = "0.0.0.0:8080"`,
   either deliberately (central Prometheus scraping multiple nodes via
   internet) or accidentally (the operator typed `0.0.0.0` instead of
   `10.42.0.1`). Risk: significant. Anyone on the internet can park
   sockets on the listener.

The fix must protect deployment shape 3 without breaking shape 1 or 2.
Setting modest server-level timeouts achieves exactly that.

## Where Go contexts fit in

Your instinct that "ideally this would be handled using go contexts with
timeouts" is the right direction — and the Go HTTP server already does
this. The bridge between "server timeout" and "context timeout" is worth
making explicit, because they sit at different layers:

### Layer 1 — server-level timeouts on `http.Server`

```go
&http.Server{
    Addr:              cfg.prom.listen,
    Handler:           mux,
    ReadHeaderTimeout: 5 * time.Second,   // headers must arrive within this
    ReadTimeout:       10 * time.Second,  // entire request (headers + body)
    WriteTimeout:      30 * time.Second,  // first byte read to last byte written
    IdleTimeout:       120 * time.Second, // keep-alive idle before close
}
```

These four fields are framework-level — they apply to **every** request
before any application code runs. `ReadHeaderTimeout` in particular is
the only one that fires before `Handler.ServeHTTP` is called, which is
exactly why it's the slowloris defense: the application doesn't get
`r.Context()` until headers are fully read.

### Layer 2 — `r.Context()` inside the handler

```go
func myHandler(w http.ResponseWriter, r *http.Request) {
    // r.Context() is the request context. It is cancelled when:
    //   - the client closes the TCP connection
    //   - WriteTimeout fires (HTTP/1.1 closes the conn; HTTP/2 cancels via context)
    //   - the server is being shut down (Shutdown / Close)
    ctx, cancel := context.WithTimeout(r.Context(), 5 * time.Second)
    defer cancel()
    upstream.DoSomething(ctx, ...) // honored by the upstream call
}
```

The handler gets a context that already encodes the server-level
deadlines, plus the client's own "I disconnected" signal. Deriving a
child context with a tighter deadline is the standard way to bound
upstream calls from within a handler.

### Layer 3 — `http.TimeoutHandler` middleware

```go
prom := promhttp.HandlerFor(pr, promhttp.HandlerOpts{ErrorLog: errLog})
mux.Handle(cfg.prom.path,
    http.TimeoutHandler(prom, 30*time.Second, "prometheus scrape timeout"))
```

`http.TimeoutHandler` wraps a handler and substitutes a custom
`ResponseWriter` that watches the request context. If the wrapped handler
hasn't returned by the deadline, the middleware writes the canned
message and stops accepting further writes. It's strictly stronger than
`WriteTimeout` for cases where you want to surface a clean error rather
than abruptly close the connection — and crucially, it does it via the
**request context**, which is the pattern you have in mind.

### How the three layers interact

For nebula's prom endpoint specifically:

- **Layer 1 (server timeouts) is mandatory** — it protects the
  pre-handler phase that Layer 2 and 3 cannot. Slowloris attacks live
  here.
- **Layer 2 (`r.Context()` inside the handler)** is academically the
  cleanest but largely irrelevant here, because the handler is
  `promhttp.HandlerFor` (third-party). We don't write its body, and
  promhttp does already honor request-context cancellation when
  iterating gatherers.
- **Layer 3 (`http.TimeoutHandler`)** is the bridge: a single middleware
  wrap turns Layer 1's "abrupt connection close" into a clean HTTP 503
  response with a configurable message. This is what most production
  Go services do for endpoints that can be slow on the legitimate path
  (a Prometheus scrape against a large registry can take seconds).

The recommendation in this doc is to apply all three layers.

## What good values look like for nebula

Order of magnitude, based on realistic Prometheus scrape characteristics:

| Field | Suggested default | Reasoning |
|---|---|---|
| `ReadHeaderTimeout` | **5s** | Slowloris defense. Real clients send all headers in <100ms; 5s is loose enough to survive bad networks, tight enough to deny attackers. |
| `ReadTimeout` | **10s** | Bounds the entire request read. Prom scrapes are body-less GETs so this rarely matters, but it adds a cheap second layer for slowpost-style attacks. |
| `WriteTimeout` | **30s** | A large registry (10k metrics × keep-alive) can take seconds to serialize. 30s gives headroom for a 500MB/s pipe → 15GB max payload, which is well beyond any plausible scrape size. |
| `IdleTimeout` | **120s** | Default Prometheus scrape interval is ~15s; keep-alive across multiple scrapes saves TCP/TLS setup. 120s comfortably spans 8 scrapes. |
| `TimeoutHandler` budget | **30s** | Matches `WriteTimeout`; the middleware surfaces 503 if a single scrape exceeds budget rather than the connection just dropping. |

These should be **configurable** — different operators have different
scrape sizes and network shapes. But the gosec finding is satisfied as
soon as `ReadHeaderTimeout` is non-zero; the other three are
defense-in-depth.

## Why not just set `Server.ReadHeaderTimeout` and ignore the rest?

Setting only `ReadHeaderTimeout` would silence gosec but leave open:

- **Slowpost** (slowloris's body-write cousin) — partially defended by
  `ReadTimeout`.
- **Slow client during response write** — when the client reads bytes
  one per second, the server's write goroutine sits in
  `(*net.TCPConn).Write` blocked on the TCP send buffer. `WriteTimeout`
  bounds this.
- **Idle-connection FD exhaustion** — keep-alive connections held open
  with no traffic accumulate FDs. `IdleTimeout` bounds this.

A complete fix sets all four. The G112 lint only checks the one, but
that's a floor, not a ceiling.

## Configurability decision

Nebula's stats config already supports `stats.listen`, `stats.path`,
`stats.namespace`, etc. The right shape for these new knobs:

```yaml
stats:
  type: prometheus
  listen: 127.0.0.1:8080
  path: /metrics
  interval: 10s

  # New, all optional with the defaults shown
  read_header_timeout: 5s
  read_timeout: 10s
  write_timeout: 30s
  idle_timeout: 120s
  handler_timeout: 30s   # 0 disables the per-request middleware wrap
```

The five existing scalar fields in `statsConfig.prom` get five sibling
duration fields. `loadStatsConfig` parses + validates: each must be
non-negative; if `handler_timeout` > `write_timeout`, the per-request
middleware would never fire (since `WriteTimeout` would close the conn
first) — that's a useful Warn but not an error.

## Recommended fix

Two-line change at the `http.Server` literal plus one config wiring:

```go
// stats.go:302-305
mux := http.NewServeMux()
prom := promhttp.HandlerFor(pr, promhttp.HandlerOpts{ErrorLog: errLog})
if cfg.prom.handlerTimeout > 0 {
    prom = http.TimeoutHandler(prom, cfg.prom.handlerTimeout, "prometheus scrape timeout")
}
mux.Handle(cfg.prom.path, prom)
return captureFns, &http.Server{
    Addr:              cfg.prom.listen,
    Handler:           mux,
    ReadHeaderTimeout: cfg.prom.readHeaderTimeout,
    ReadTimeout:       cfg.prom.readTimeout,
    WriteTimeout:      cfg.prom.writeTimeout,
    IdleTimeout:       cfg.prom.idleTimeout,
}
```

Plus the config-side changes in `loadStatsConfig` (around stats.go:340)
to read and validate the five new keys with the defaults from the table
above.

## TDD test plan

Three rows in a table-driven test, plus one slowloris-style integration
test:

1. **Server-level timeouts forward into the constructed `http.Server`.**
   Build a `statsConfig` with non-default timeouts, call `buildRuntime`,
   assert the returned `*http.Server`'s four duration fields match. This
   is a pure unit test, no listener needed.

2. **TimeoutHandler fires when the underlying handler exceeds its budget.**
   Replace `promhttp.HandlerFor` in a small wrapper test with a handler
   that does `time.Sleep(2 * timeout)`; start the server on `:0`,
   `http.Get` the endpoint, assert the response is 503 and the body is
   the configured timeout message.

3. **TimeoutHandler is a noop when `handler_timeout = 0`.** Same
   wrapper, `handler_timeout=0`. Assert the response is 200 (or
   whatever the underlying handler returns) and the body is the
   real response body.

4. **Slowloris-class integration test** (one site, gated by `testing.Short()`):
   ```go
   // Open a connection, write a partial header, then sleep beyond
   // ReadHeaderTimeout. Assert the server closes the connection by
   // reading and getting io.EOF before the slowloris client has
   // finished its slow write.
   conn, _ := net.Dial("tcp", srv.Addr)
   conn.Write([]byte("GET /metrics HTTP/1.1\r\nHost: localhost"))
   // ... sleep > ReadHeaderTimeout ...
   _, err := conn.Read(buf)
   require.Error(t, err, "server must close the slowloris connection")
   ```

   Run with `ReadHeaderTimeout: 200*time.Millisecond` so the test is
   fast. The mutation check is: if we reset the literal back to no
   timeout, the slowloris test hangs (caught by `t.Deadline` or
   `t.Parallel`-style guard).

## Mutation testing

Two mutations to confirm tests catch reverts:

1. Strip the four `*Timeout` fields from the `http.Server` literal →
   slowloris test should fail (no FIN within budget).
2. Set `cfg.prom.handlerTimeout = 0` while leaving the wrap conditional
   intact, then exercise the "TimeoutHandler fires" test → must fail
   because the conditional removes the wrap.

---

# Part 2: G301 — `overlay/tun_linux.go:257` `/dev/net` perms

## Current code

```go
// tun_linux.go:252-264 — inside newTun, fallback when /dev/net/tun missing
fd, err := unix.Open("/dev/net/tun", os.O_RDWR, 0)
if err != nil {
    if os.IsNotExist(err) {
        err = os.MkdirAll("/dev/net", 0755)
        if err != nil {
            return nil, fmt.Errorf("/dev/net/tun doesn't exist, failed to mkdir -p /dev/net: %w", err)
        }
        err = unix.Mknod("/dev/net/tun", unix.S_IFCHR|0600, int(unix.Mkdev(10, 200)))
        ...
```

## Why this is (likely) a false positive

Three facts make this finding not actionable as gosec wants:

1. **`/dev/net` is canonically `0755`.** On every standard Linux
   distribution, `/dev/net` (when the `/dev/net/tun` module is loaded
   and udev creates the path) is `drwxr-xr-x`. Diverging to `0750`
   would create a path with non-standard perms that doesn't match what
   udev produces on a normal system.
2. **The directory perms don't gate access to the tun device.** Access
   to `/dev/net/tun` is gated by the device node's own `0600` + ownership
   (set on the very next line, `unix.Mknod`). Even if `/dev/net` were
   `0700`, a non-root user could still hit `EACCES` opening the device
   itself — the actual security boundary is the device node, not its
   parent directory.
3. **This code path only fires inside containers without `/dev/net`
   pre-mounted.** Production hosts have `/dev/net` already; the
   `MkdirAll` is a no-op there. Inside a container, the container's own
   PID namespace and root filesystem are the security boundary, not the
   `/dev/net` directory perms.

## Recommended action

Annotate with `//nosec G301` and a one-line rationale. The repo already
uses this pattern for `cert/crypto.go` G407 (hardcoded-nonce, where the
nonce is derived from the password) and `cmd/nebula-cert/stdio.go` G703
(path traversal, where the path is operator-supplied). Same shape:

```go
//nosec G301 // /dev/net is canonically 0755 on Linux; the device node
// itself is created 0600 on the next line. Tightening here would
// diverge from udev convention without adding real defense.
err = os.MkdirAll("/dev/net", 0755)
```

Done. No upstream PR needed — this is a nix-branch-only annotation, same
class as the existing `//nosec G407/G703/G704` markers added in
`39a6ed8 Document G407/G703/G704 false positives with // #nosec rationale`.

---

# Part 3: SA4003 — eight dead bounds-check comparisons

## What staticcheck is flagging

A type-narrowing comparison whose result is provable at compile time.
Eight sites, all in defensive bounds-check guards:

### Cluster A — `cert/crypto.go` (4 sites in `unmarshalArgon2Parameters`)

```go
func unmarshalArgon2Parameters(params *RawNebulaArgon2Parameters) (*Argon2Parameters, error) {
    if params.Version < math.MinInt32 || params.Version > math.MaxInt32 {       // L235
        return nil, fmt.Errorf("...Version must be at least %d and no more than %d", ...)
    }
    if params.Memory <= 0 || params.Memory > math.MaxUint32 {                   // L238
        return nil, fmt.Errorf("...Memory must be be greater than 0 and no more than %d KiB", ...)
    }
    if params.Parallelism <= 0 || params.Parallelism > math.MaxUint8 {          // (no flag — see below)
        return nil, fmt.Errorf("...Parallelism must be be greater than 0 and no more than %d", ...)
    }
    if params.Iterations <= 0 || params.Iterations > math.MaxUint32 {           // L244
        return nil, fmt.Errorf("-argon-iterations must be be greater than 0 and no more than %d", ...)
    }
    ...
}
```

The proto-generated types are:

```
// cert/cert_v1.proto
message RawNebulaArgon2Parameters {
    int32 version = 1;       // → params.Version  int32
    uint32 memory = 2;       // → params.Memory   uint32
    uint32 parallelism = 4;  // → params.Parallelism uint32 (uint8 in Go's Argon2Parameters)
    uint32 iterations = 3;   // → params.Iterations uint32
    bytes salt = 5;
}
```

Walking each clause:

- **L235** — `params.Version < math.MinInt32 || params.Version > math.MaxInt32`. `Version` is `int32`. By definition, no `int32` value satisfies either clause. **Both halves dead.** staticcheck flagged both halves separately, hence two findings on the same line.
- **L238** — `params.Memory <= 0 || params.Memory > math.MaxUint32`. `Memory` is `uint32`. The `<= 0` half is meaningful (`uint32 == 0` is reachable; it rejects zero memory). The `> math.MaxUint32` half is always false. **One half dead.**
- **L241** *(not flagged)* — `params.Parallelism <= 0 || params.Parallelism > math.MaxUint8`. `Parallelism` is `uint32` in the proto, `uint8` in the Argon2Parameters Go struct. The `> math.MaxUint8` check IS meaningful here — a proto-encoded value > 255 would overflow the eventual `uint8` cast on L251. staticcheck correctly leaves this alone.
- **L244** — `params.Iterations <= 0 || params.Iterations > math.MaxUint32`. Same shape as L238. **One half dead.**

So the cluster represents four dead halves out of six bounds clauses across three lines. The author was writing belt-and-braces validation; staticcheck has identified the braces that can't ever tighten.

### Cluster B — `message_metrics.go` (4 sites at L22 and L31)

```go
// L20-28
func (m *MessageMetrics) Rx(t header.MessageType, s header.MessageSubType, i int64) {
    if m != nil {
        if t >= 0 && int(t) < len(m.rx) && s >= 0 && int(s) < len(m.rx[t]) {     // L22
            m.rx[t][s].Inc(i)
        } else if m.rxUnknown != nil {
            m.rxUnknown.Inc(i)
        }
    }
}

// L29-37 — Tx is the same shape
```

Types: `header.MessageType` and `header.MessageSubType` are both
`uint8` (see `header/header.go:29-30`). Every `uint8` is `>= 0`. So
both `t >= 0` and `s >= 0` are always true, twice each (once in `Rx`,
once in `Tx`) — four dead clauses.

The remaining halves (`int(t) < len(m.rx)` and `int(s) < len(m.rx[t])`)
are the actual bounds checks and do real work. The `>= 0` halves are
likely vestigial from an earlier version where the types were signed,
or pattern-copied from a tutorial.

## Recommended fix

Two commits, one per cluster:

### Commit 1 — `cert/crypto.go`

```diff
- if params.Version < math.MinInt32 || params.Version > math.MaxInt32 {
-     return nil, fmt.Errorf("Argon2Parameters Version must be at least %d and no more than %d", math.MinInt32, math.MaxInt32)
- }
- if params.Memory <= 0 || params.Memory > math.MaxUint32 {
-     return nil, fmt.Errorf("Argon2Parameters Memory must be be greater than 0 and no more than %d KiB", uint32(math.MaxUint32))
+ if params.Memory == 0 {
+     return nil, fmt.Errorf("Argon2Parameters Memory must be greater than 0")
  }
  if params.Parallelism <= 0 || params.Parallelism > math.MaxUint8 {
      return nil, fmt.Errorf("Argon2Parameters Parallelism must be be greater than 0 and no more than %d", math.MaxUint8)
  }
- if params.Iterations <= 0 || params.Iterations > math.MaxUint32 {
-     return nil, fmt.Errorf("-argon-iterations must be be greater than 0 and no more than %d", uint32(math.MaxUint32))
+ if params.Iterations == 0 {
+     return nil, fmt.Errorf("-argon-iterations must be greater than 0")
  }
```

Net change: drop the L235 block entirely (whole check is dead), and
simplify L238 + L244 to just the meaningful `== 0` rejection. Also
fix the doubled "be be" typo while touching the lines.

### Commit 2 — `message_metrics.go`

```diff
- if t >= 0 && int(t) < len(m.rx) && s >= 0 && int(s) < len(m.rx[t]) {
+ if int(t) < len(m.rx) && int(s) < len(m.rx[t]) {
      m.rx[t][s].Inc(i)
```

Same edit in `Tx` (L31). Two-line change per function.

## Why two commits not one

`cert/crypto.go` is on the cert-format hot path (key decrypt). The
`message_metrics.go` change is in a per-packet metric increment. They
have different review audiences and different risk profiles —
maintainers may want to look at the cert changes more carefully than
the metrics changes. Separating them keeps the cert-format reviewer
from getting distracted by the metrics edit.

## TDD test plan

Both clusters are unusual in that **no current behavior changes** —
the dead code never fires, so removing it doesn't change runtime
output. The tests therefore need to assert two things:

1. The remaining bounds check **still rejects the values it always
   rejected**. For Argon2: `Memory == 0` must still return an error.
   For message_metrics: `t > len(m.rx)` must still go to the unknown
   counter rather than panicking.
2. **No previously-accepted values are now rejected.** This is a
   trivial smoke pass — any existing happy-path test that survives
   the diff is evidence enough.

Existing tests in `cert/crypto_test.go` and `message_metrics_test.go`
(if present) likely cover both. If not, add a table-driven test row
asserting `Memory == 0` returns the expected error, and a row
asserting `MessageType == 255` (or `> len(m.rx)`) hits the unknown
path.

## Mutation testing

For commit 1: revert one of the `== 0` checks → corresponding error-path
test should fail.

For commit 2: revert `int(t) < len(m.rx)` (the *real* bounds check, not
the dead `t >= 0` we removed) → the out-of-range test should `panic:
index out of range` rather than incrementing the unknown counter.

---

# Suggested PR shape

Three commits worth of upstream work, fitting cleanly in **one** PR if
upstream prefers thematic grouping ("static-analysis cleanup"), or in
**two** PRs if upstream prefers grouping by severity (G112 vs. rest).

| Commit | Scope | Files | Diff size |
|---|---|---|---|
| 1 | **G112**: add server-level timeouts + optional TimeoutHandler middleware + config knobs | `stats.go`, `stats_test.go`, `examples/config.yml` (docs) | ~+150/-3 |
| 2 | **SA4003 cert**: drop dead Version bounds, simplify Memory/Iterations to `== 0` rejection | `cert/crypto.go`, `cert/crypto_test.go` | ~+15/-12 |
| 3 | **SA4003 metrics**: drop dead `>= 0` checks in Rx/Tx | `message_metrics.go`, `message_metrics_test.go` | ~+5/-3 |

G301 is **not** in this PR — it's a `//nolint:gosec` annotation that
lives only on the local `nix` branch (same approach as the existing
G407/G703/G704 annotations), since the finding is a false positive
specific to nebula's threat model and isn't worth an upstream PR.

Recommendation: one PR with all three commits, titled
"Set Prometheus listener timeouts and drop dead bounds-check
comparisons" or similar. The G112 commit is the headline; the two
SA4003 commits ride along as smaller cleanups in the same lint-driven
spirit. Bisect-safe by construction (each commit fixes only its own
finding).

If upstream pushes back, split: one PR for G112 (the security fix),
one PR for the SA4003 cleanup.

---

# Verification plan

Once each commit lands locally:

1. `go test -count=1 ./...` — full suite green at every commit.
2. Mutation tests per commit (per section above).
3. `nix build .#checks.x86_64-linux.gosec` — `G112` count drops from
   1 → 0 in the report.
4. `nix build .#checks.x86_64-linux.staticcheck` — `SA4003` count drops
   from 8 → 0.
5. `nix build .#checks.x86_64-linux.golangci-lint-quick` — tier 0
   issue count drops by the SA4003 portion (8 out of the staticcheck
   tier-0 50).
6. `gofmt -l <changed files>` and `go vet ./...` clean.
7. The slowloris integration test runs in `-short` mode in <500ms;
   confirm it passes on a `go test -race` run as well, since
   `http.Server` Shutdown + ListenAndServe is a known race surface.
