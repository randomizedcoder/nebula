# Design notes — Part 1 real-bug fixes (E1–E5)

Companion to `nix/findings-errcheck.md`. The triage doc identified five
silent-failure sites; this doc works through the production-readiness
questions before any code is written. The questions came from the
review of the triage:

- Should we add retry / exponential backoff / jitter?
- Configurable via `config.C`?
- Prometheus metrics on each failure?
- Rate-limit the `Warn` to avoid self-DOSing under flood?
- What rate limit makes sense — 100/min? per second / minute / hour?
- Will the maintainers push back, and how do we minimize that risk?

The codebase inventory turned up a few facts that change every answer
below. Stated upfront so the rest of the doc has clear footing:

## Codebase facts (verified)

| What | Found | Where |
|---|---|---|
| Metrics library | `github.com/rcrowley/go-metrics` (NOT `prometheus/client_golang` directly) | `go.mod`, every existing `metrics.GetOrRegister*` call |
| Metric naming | dot-separated, lowercase, hierarchical | e.g. `firewall.incoming.dropped.no_rule`, `handshake_manager.initiated` |
| Metric lifecycle | struct-scoped fields initialized in constructor | `firewallMetrics`, `cachedPacketMetrics`, etc. |
| Retry pattern | hand-rolled linear backoff, no jitter | `handshake_manager.go:238-244`, `tryInterval * counter` |
| Retry config | `c.GetDuration("handshakes.try_interval", default)` + `c.GetInt("handshakes.retries", default)` | `main.go`, idiomatic |
| Rate-limited logs | **does not exist anywhere in nebula** | confirmed: no `*rate.Limiter`, no helper package |
| `golang.org/x/time/rate` | **not a dependency** | not in `go.mod` |
| Log-flood guard idiom in use | `if l.Enabled(ctx, slog.LevelDebug)` to cheap-check before string format | `dns_server.go:383`, `handshake_manager.go:98` |
| DNS subsystem metrics | **none exist today** | grep `metrics` in `dns_server.go` returns no hits |
| sshd package metrics | **none exist today** | grep `metrics` in `sshd/*.go` returns no hits |
| sshd config plumbing | sshd `*session` has **no `*config.C` reference** | only `*slog.Logger` and `*ssh.ServerConn` |

These constrain the design: anything we propose either reuses an
existing pattern, or has to introduce a new one (which costs review
budget with the maintainers).

---

## Per-site recommendation summary

| ID | Site | Retry? | Metric? | Rate-limit log? | Config knob? |
|---|---|---|---|---|---|
| E1 | `dns_server.go:439` WriteMsg | **No** (see §1) | **Yes** (1 counter) | **Yes** (sampled — see §3) | No |
| E2 | `config/config.go:338` addFile | No | No | No | No |
| E3 | `sshd/session.go:85` Reply(false) | No | **Yes** (1 counter, new sshd metric block) | No (low natural rate) | No |
| E4 | `sshd/session.go:89` Reply(true) | No | Yes (same counter as E3) | No | No |
| E5 | `sshd/session.go:93` SendRequest exit-status | No | Yes (separate counter, fires after dispatch) | No | No |

Each "No" below has reasoning, not just opinion. Let me walk through.

---

## §1 — Why no retry on E1 (and why none on E3–E5)

The user's instinct was to add an exponential backoff with jitter, the
idea being "if the lighthouse and tens of thousands of clients all
share a network blip, don't synchronized-retry into a thundering
herd." That instinct is correct *for outbound calls to remote
services*. It does not apply to E1–E5 because:

**E1 — `dns.ResponseWriter.WriteMsg`** writes a UDP response into our
*own* listening socket. The failure modes are:

- the client's UDP socket already closed (TTL expired, resolver gave
  up). Retrying our write doesn't bring their socket back.
- our own socket is in a bad state (FD exhaustion, OS buffer pressure).
  Retrying immediately doesn't fix FD exhaustion.
- a transient `EAGAIN` on the kernel send buffer. The Go DNS library
  doesn't expose retry semantics here — `WriteMsg` already handles
  partial writes.

The DNS protocol expects clients to retry at the *resolver* layer
(UDP DNS retries are part of every stub resolver). Server-side retry
adds latency without changing outcomes; the client may have already
moved on. **Right answer: emit the response once, on failure log +
meter the failure, move to the next request.** The same logic that
makes WSGI's "send-and-forget" pattern sensible applies here.

**E3 / E4 / E5 — SSH protocol replies.** These are part of the SSH
session establishment. If `req.Reply` or `channel.SendRequest` fails,
the underlying TCP connection (or the SSH transport state) is
broken — there is no recovery state to retry into. Sending a
duplicate reply is a protocol violation. The client is gone. Bail
out, log, increment a counter, done.

**If retry were appropriate** (it's not here, but for future readers):
nebula's existing pattern is `tryInterval * counter` linear backoff
with no jitter. A first-class exponential-with-jitter helper would be
a new package and a new pattern for the maintainers to swallow. We
should not introduce that on the back of a bug-fix PR; if it comes up
later for a different feature, propose it then on its own merits.

---

## §2 — Configurable knobs: no, except where existing config already covers it

The user asked whether retry counts, sleep times, and jitter should be
configurable. Since we're not adding retry (§1), the question reduces
to: should the log rate-limit window be a `c.GetDuration` knob?

**Recommendation: no.** Reasons:

1. **The rate limit is an operator-protection mechanism, not a tunable
   policy.** Operators who want every single failure logged should
   raise `slog.LevelDebug`; operators who want fewer logs can already
   filter at the slog handler. Adding `dns.warn_rate_limit_seconds`
   creates a config key that's hard to advise on ("set it to what?")
   and harder to deprecate once anyone has it in their config.
2. **The maintainers' bar for new config keys is non-trivial.**
   `RegisterReloadCallback` is heavily used, but the keys themselves
   are added sparingly and tend to govern feature toggles, not
   internal logging behavior.
3. **The simplest defensible default is 1 log per 10 seconds with
   a count of suppressed entries.** That value works for the
   slow-network-blip case (~10s of failures get a single log line
   plus a count) and the catastrophic-broken-case (one Warn every
   10s rather than 1000 per second).

If a maintainer asks for the knob during review, we can add it then.
Going in without it is the smaller-PR posture.

---

## §3 — Rate-limited Warn: sketch a 12-line helper, scope to E1 only

nebula doesn't have a rate-limit helper today. Adding `golang.org/x/time/rate`
is a new dep, which adds review surface. The lightest-weight option is
a per-site helper using only the standard library:

```go
// dnsWriteWarnLimiter throttles dns_server's WriteMsg-failure Warn
// log so a broken downstream cannot flood the log.
//
// Semantics: first call after window elapsed → log; otherwise
// increment a counter and stay silent. On the next log emission the
// suppressed-count is included as a slog attr so operators can
// reconstruct the rate.
type dnsWriteWarnLimiter struct {
    suppressed atomic.Int64
    lastLogged atomic.Int64 // unix nanos
    windowNs   int64        // 10 * time.Second
}

// shouldLog returns (true, prevSuppressed) when the caller should
// emit, and (false, _) when the call must be suppressed and counted.
func (l *dnsWriteWarnLimiter) shouldLog(now int64) (bool, int64) {
    last := l.lastLogged.Load()
    if now-last >= l.windowNs {
        if l.lastLogged.CompareAndSwap(last, now) {
            return true, l.suppressed.Swap(0)
        }
    }
    l.suppressed.Add(1)
    return false, 0
}
```

About 20 lines including comments. Lives in `dns_server.go` (one file
scope, no new package). The CAS makes the "first caller after window
elapsed wins" race-free. Per-site rather than shared so the helper
doesn't grow into "the nebula rate-limit library" without a
deliberate decision to do so.

**Call site:**

```go
if err := w.WriteMsg(m); err != nil {
    d.metricWriteFailures.Inc(1)
    if log, suppressed := d.warnLimiter.shouldLog(time.Now().UnixNano()); log {
        d.l.Warn("dns: failed to write response",
            "error", err,
            "client", w.RemoteAddr().String(),
            "suppressed_since_last_log", suppressed)
    }
}
```

The suppressed-count goes in the *log* attrs, not just to telemetry —
operators reading the journal must be able to tell that the one Warn
line represents N failures, not 1.

### E3 / E4 / E5: no rate limit

SSH session events are naturally rare (a few connections per minute
on a busy lighthouse). The catastrophic failure mode where every
incoming SSH connection's reply fails simultaneously requires either
a kernel-level problem (which will be visible elsewhere) or
deliberate attacker action against the SSH endpoint (which is gated
by `sshd.authorized_users`). Spending review budget on rate-limited
SSH logs is poor leverage. **Plain `s.l.Warn` is right here.**

---

## §4 — Prometheus metrics: yes, via the existing `rcrowley/go-metrics`

The codebase uses `rcrowley/go-metrics` exclusively for instrumentation
(it's then exported to Prometheus via the existing
`nbrownus/go-metrics-prometheus` bridge — operators already see this
data on their dashboards).

### Proposed counters

| Metric | Type | Where lived | What it counts |
|---|---|---|---|
| `dns.responses.write_failures` | Counter | `*dnsServer` struct (new field) | E1 — WriteMsg errors |
| `sshd.reply.errors` | Counter | `sshd` package-level (NewSSHServer init) | E3 + E4 — `req.Reply` failures |
| `sshd.exit_status.errors` | Counter | same | E5 — `channel.SendRequest("exit-status")` failures |

**Why E3 + E4 share a counter:** both are `*ssh.Request.Reply`
failures during exec-request handling; an operator slicing
"SSH protocol misbehavior" doesn't gain by separating accept-fail
vs reject-fail. **E5 is separate** because the failure mode is
distinct (exit-status SendRequest happens *after* a successful
command dispatch and indicates a different breakage class:
"client disconnected during command output" vs "client never
saw the reply").

### Where the sshd metrics live

`sshd/session.go`'s `session` struct has no config and no metrics
today. The lightest plumbing: register the counters as package-level
vars in `sshd/session.go` itself (or a new `sshd/metrics.go`), with
the `metrics.GetOrRegister*` pattern matching `interface.go:200`.
No struct-field plumbing, no constructor changes.

```go
// sshd/metrics.go (new ~15-line file)
package sshd

import "github.com/rcrowley/go-metrics"

var (
    metricReplyErrors      = metrics.GetOrRegisterCounter("sshd.reply.errors", nil)
    metricExitStatusErrors = metrics.GetOrRegisterCounter("sshd.exit_status.errors", nil)
)
```

This matches how `handshake_manager.go:128-129` does it — top-of-file
metric vars, no constructor plumbing.

---

## §5 — Testing strategy

### E1 — `dns.ResponseWriter` mocking + table-driven limiter test

`dns.ResponseWriter` is an interface (from `miekg/dns`). Testing
WriteMsg failure is straightforward — embed and override:

```go
type failingDNSWriter struct {
    dns.ResponseWriter
    addr net.Addr
}
func (f *failingDNSWriter) WriteMsg(*dns.Msg) error { return errInjectedDNS }
func (f *failingDNSWriter) RemoteAddr() net.Addr    { return f.addr }
```

Two test functions:

```go
// 1. Failure path emits both Warn and metric increment.
func TestHandleDnsRequest_WriteMsgFailure_LogsAndMeters(t *testing.T) {
    var buf bytes.Buffer
    h := slog.NewTextHandler(&buf, nil)
    ds := newTestDNSServer(t, slog.New(h))

    before := ds.metricWriteFailures.Count()
    ds.handleDnsRequest(&failingDNSWriter{addr: udpAddr("1.2.3.4:5353")},
        new(dns.Msg).SetQuestion("a.b.c.", dns.TypeA))

    assert.Equal(t, before+1, ds.metricWriteFailures.Count())
    assert.Contains(t, buf.String(), "dns: failed to write response")
    assert.Contains(t, buf.String(), errInjectedDNS.Error())
}

// 2. The rate-limiter itself, table-driven against fake clock.
func TestDNSWriteWarnLimiter(t *testing.T) {
    tests := []struct {
        name        string
        windowNs    int64
        calls       []int64 // simulated `now` nanos for each call
        wantLogged  []bool  // expected shouldLog return value, per call
        wantPrevSup []int64 // expected suppressed counts, per call (where logged=true)
    }{
        {
            name:        "first call always logs with zero suppressed",
            windowNs:    10 * int64(time.Second),
            calls:       []int64{0},
            wantLogged:  []bool{true},
            wantPrevSup: []int64{0},
        },
        {
            name:        "second call inside window is suppressed",
            windowNs:    10 * int64(time.Second),
            calls:       []int64{0, 5_000_000_000}, // 5s later
            wantLogged:  []bool{true, false},
            wantPrevSup: []int64{0, 0},
        },
        {
            name:        "third call past window emits with accumulated count",
            windowNs:    10 * int64(time.Second),
            calls:       []int64{0, 5_000_000_000, 15_000_000_000},
            wantLogged:  []bool{true, false, true},
            wantPrevSup: []int64{0, 0, 1}, // one was suppressed in the middle
        },
        // ... boundary cases: tied exactly at window edge, monotonic clock
        //     decreasing (shouldn't happen but defensive), high contention
        //     (concurrent calls — CAS branch).
    }
    for _, tc := range tests { ... }
}
```

The limiter is what we test exhaustively because it has a state
machine and a race window (the CAS); the call-site test just checks
"does the wiring connect correctly." This is the same shape used
across the other PRs in this series.

### E3 / E4 / E5 — refactor for testability

`*ssh.Request` and `*ssh.Channel` from `golang.org/x/crypto/ssh` are
hard to mock — both have unexported fields. The pragmatic approach:

1. Extract a tiny helper: `replyAndLog(req replyer, ok bool, payload []byte, l *slog.Logger) error` where `replyer` is a 1-method interface (`Reply(bool, []byte) error`).
2. Tests pass a fake `replyer` that returns an injected error.
3. The helper is unit-tested with that fake. The production code passes the real `*ssh.Request` (which already implements the interface).

```go
type replyer interface{ Reply(bool, []byte) error }

func replyAndLog(r replyer, ok bool, payload []byte, l *slog.Logger) error {
    if err := r.Reply(ok, payload); err != nil {
        metricReplyErrors.Inc(1)
        l.Warn("ssh: protocol reply failed", "ok", ok, "error", err)
        return err
    }
    return nil
}
```

`*ssh.Request` already has a method set that includes `Reply(bool, []byte) error`, so it satisfies `replyer` without a wrapper. The test injects a `&fakeReplyer{err: errInjected}` and asserts the metric incremented and the log line emitted.

Same shape for `channel.SendRequest("exit-status", ...)` — a single-method `requester` interface plus a `sendRequestAndLog` helper.

This refactor adds ~20 lines but makes the failure paths reachable in tests. Without it, those three sites stay covered only by code review.

### E2 — straightforward filesystem test (already drafted)

`TestC_resolve_AddFileErrorPropagates` from `findings-errcheck.md` §E2.
Trigger `filepath.Abs` failure by cd-ing to a deleted directory.
Platform-sensitive — skip on platforms where deleted-cwd doesn't
return an error from `os.Getwd`.

---

## §6 — Maintainer-reception risk assessment

The user flagged: "maintainers won't be thrilled about us poking at
their bugs". Honest assessment, ordered most→least risky:

| Risk | Mitigation in this design |
|---|---|
| **New config keys** (operators will see them in `config.yml` examples and the doc surface grows) | Zero new config keys. The rate-limit window is a `const` in `dns_server.go`. |
| **New external dependencies** (anything added to `go.mod`) | Zero new dependencies. Reuse `rcrowley/go-metrics` and stdlib `sync/atomic`. |
| **New packages** (e.g. `nebula/util/ratelimit`) | None. ~20-line rate-limit type lives in `dns_server.go` itself. |
| **Behavior change in a hot path** (DNS query handling) | We *only* add a single Counter Inc + a single Warn (rate-limited). On the success path: zero overhead. On the failure path: ~1 µs counter increment + maybe a log line. |
| **New patterns** (rate-limited logging) | We do introduce a new pattern, but as a single-file helper, not a new package or convention. If maintainers prefer a different shape they can flag it in review. |
| **Refactor for testability** (the `replyer` interface) | This is the riskiest change in the PR. Two ways to mitigate: (a) leave the refactor out and skip the test (annotate with `//nolint:errcheck` for E3-E5, accept lower coverage); (b) keep the refactor but justify it inline. |
| **Cross-cutting "production-hardening" framing** | We don't pitch it that way. The PR title is "Log and meter previously-swallowed errors in dns + sshd" — fix-bug framing, not feature-add framing. |

Single-PR option: bundle E1 + E2 + the sshd metrics + the refactored
helper + tests. Six commits, ~+200/-30. Each commit independent.

If a smaller PR is wanted instead, split as:

- **PR 3a-1**: E2 only (one-line config fix + test). Trivial.
- **PR 3a-2**: E1 (DNS + metrics + limiter + tests). Self-contained.
- **PR 3a-3**: E3/E4/E5 (sshd metrics + helper refactor + tests). Self-contained.

I'd lean toward the bundled version since each commit is small
already and the narrative ("five silent-failure sites fixed
uniformly") is stronger than three smaller PRs.

---

## §7 — What I'm NOT proposing (and why)

Items the user explicitly asked about that I'm pushing back on:

- **Exponential backoff + jitter helper.** §1: retry isn't the right pattern at any of these sites. Adding the helper without a use site is dead code.
- **Configurable retry counts / sleep / jitter via `config.C`.** §2: no retry → no knobs.
- **Multi-tier rate limit** (max/sec, max/min, max/hour). The single 10-second window with a suppressed-count is sufficient and simple. Multi-tier adds complexity without a concrete scenario it solves better.
- **Shared rate-limit package.** §6: keeps the diff to one file, no new package surface for maintainers to sign off on.
- **Histograms / latency metrics on DNS.** Out of scope for "fix the silent failures." Useful in a separate observability PR if the maintainers want it.

---

## §8 — Recommended next step

If this design lands well, the path is:

1. Approve / amend this doc (in particular: confirm "no config knob"
   and "no retry" decisions).
2. Enter plan mode for the actual implementation PR (the per-commit
   layout, the test scaffolding, the commit messages — same pattern
   as PR #1725).
3. After plan approval, execute commit-by-commit with the
   stage-then-review workflow we used for #1725.

Open questions for the user before plan mode:

- **Helper refactor for E3-E5**: include it (better test coverage, bigger diff, more
  risk to upstream reception) or skip (lower coverage, smaller diff,
  cleaner accept rate)? My recommendation is include — it's only ~20
  lines and matches the "production-ready" framing the user is asking
  for.
- **PR shape**: single bundled PR (~6 commits) or three smaller PRs
  (E2 / E1 / SSH)? My recommendation is single bundled — narrative
  cohesion outweighs review-burden reduction at this size.
