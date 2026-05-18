# PR draft — `prometheus-listener-timeouts`

This file is the **record copy** of the upstream PR — committed to the
local `nix` branch as a record of what was sent.

| Field | Value |
|---|---|
| Source | `randomizedcoder:prometheus-listener-timeouts` |
| Target | `slackhq/nebula:master` |
| Commits | 3 (security floor / config knobs / TimeoutHandler wrap) |
| Files modified | `stats.go`, `stats_test.go`, `examples/config.yml` |
| Diff stat | +429 / -2 |
| Pushed to | `randomizedcoder/nebula` ([branch](https://github.com/randomizedcoder/nebula/tree/prometheus-listener-timeouts)) |
| PR | [slackhq/nebula#1727](https://github.com/slackhq/nebula/pull/1727) — opened, `mergeable`, CLA passes on first push |
| Related | [#1724](https://github.com/slackhq/nebula/pull/1724), [#1725](https://github.com/slackhq/nebula/pull/1725), [#1726](https://github.com/slackhq/nebula/pull/1726) — same static-analysis-driven series; no file overlap |

## Proposed PR title

```
Set timeouts on the Prometheus stats HTTP listener
```

## Proposed PR body

The block below is exactly what I will paste into the GitHub PR body.

---

> ### Hi 👋
>
> The Prometheus stats `*http.Server` is currently constructed bare: `&http.Server{Addr: cfg.prom.listen, Handler: mux}`. Every timeout field is the zero value, which `net/http` reads as "no limit". That means the server accepts connections that send headers one byte per minute forever (slowloris), bodies that never end (slowpost), responses that drain one byte per minute (slow read), and keep-alive idle connections that never close. On a listener bound to a public interface — either deliberately (cross-host scraping by a central Prometheus) or by accident (operator types `0.0.0.0` instead of an overlay address) — a single attacker can park thousands of FDs at near-zero cost. Some operators may already be running with these issues now: this PR closes the gap, with conservative defaults and full reload-aware configurability.
>
> ### How we found this
>
> Downstream of this fork we run [`gosec`](https://github.com/securego/gosec) via golangci-lint as part of a strict static-analysis pipeline. The relevant finding was:
>
> ```
> stats.go:304  G112 (CWE-400): Potential Slowloris Attack because
>                ReadHeaderTimeout is not configured in the http.Server
>                (Confidence: LOW, Severity: MEDIUM)
> ```
>
> `ReadHeaderTimeout` is the floor; this PR fixes the floor and the three siblings (`ReadTimeout`, `WriteTimeout`, `IdleTimeout`) at the same time so the gap is closed cleanly rather than just silencing the lint.
>
> ### What lands in this PR
>
> Three commits, each focused on one concern, all bisect-safe (`go test ./...` passes at every SHA).
>
> **Commit 1 — `Set timeouts on the Prometheus stats HTTP listener`**
>
> The security floor. Adds four `defaultStatsXxxTimeout` constants in a single `const ( )` block, following the repo's existing `defaultPromoteEvery` / `defaultReQueryEvery` / `defaultReQueryWait` convention from `hostmap.go`. Plumbs them into the `http.Server` literal. Adds a table-driven test that pins each field to its constant, plus an invariant test that guards `ReadTimeout >= ReadHeaderTimeout` so a future careless edit can't silently degrade slowloris defense into a generic i/o-timeout.
>
> Defaults:
>
> | Field | Default | Reasoning |
> |---|---|---|
> | `ReadHeaderTimeout` | 10s | Slowloris defense. Real clients send all headers in <100ms; 10s is loose enough to survive bad networks, tight enough to deny attackers. |
> | `ReadTimeout` | 15s | Bounds the entire request read. Prom scrapes are body-less GETs so this rarely matters, but it adds a cheap second layer for slowpost-style attacks. |
> | `WriteTimeout` | 30s | A large registry (10k metrics × keep-alive) can take seconds to serialize. 30s gives headroom well beyond any plausible scrape size. |
> | `IdleTimeout` | 120s | Default Prometheus scrape interval is ~15s; keep-alive across multiple scrapes saves TCP/TLS setup. 120s comfortably spans 8 scrapes. |
>
> **Commit 2 — `Make Prometheus listener timeouts configurable`**
>
> Five new optional `stats.*` yaml keys override the defaults. The whole `stats:` section is already reload-aware, so the new keys are picked up on SIGHUP without restart:
>
> ```yaml
> stats:
>   type: prometheus
>   listen: 127.0.0.1:8080
>   path: /metrics
>   #read_header_timeout: 10s
>   #read_timeout: 15s
>   #write_timeout: 30s
>   #idle_timeout: 120s
>   #handler_timeout: 30s    # 0 disables the TimeoutHandler wrap (commit 3)
> ```
>
> `loadStatsConfig` reads each key via `c.GetDuration` with the default constant as the fallback. Validation rejects any negative duration with an error naming the offending key. Zero is allowed (operator explicit opt-out); the example config documents that `read_header_timeout: 0` defeats slowloris defense.
>
> Two new table-driven tests:
> - `TestLoadStatsConfig_PromTimeouts_Overrides` — 6 rows covering each key individually plus all-five-overridden-together (the latter catches plumbing mistakes where one key's value lands in another field).
> - `TestLoadStatsConfig_PromTimeouts_NegativeRejected` — 5 rows asserting `loadStatsConfig` errors AND the error message names the key so an operator can grep their config for it.
>
> **Commit 3 — `Wrap Prometheus handler with http.TimeoutHandler for clean 503`**
>
> The existing `WriteTimeout` does its job by abruptly closing the TCP connection when the server exceeds its budget — the scraper sees `io.UnexpectedEOF` with no body and no status, which is hostile to triage. `http.TimeoutHandler` observes the request context and substitutes a 503 response with a configurable body once the per-request budget elapses, giving the scraper something to log and the operator something to grep for.
>
> A small `wrapPromHandler` helper conditionally applies the wrap when `handler_timeout > 0` and returns the inner handler unchanged otherwise. The wrap is the Layer-3 expression of the Go context model: the inner handler's request context is cancelled by the middleware when the budget elapses, so any handler that honors `r.Context()` aborts cleanly. `promhttp.HandlerFor` already honors it for its gatherer iteration.
>
> Two integration tests cover the wrap, both gated by `testing.Short` so the `-short` CI matrix isn't slowed:
> - `TestWrapPromHandler_FiresOn503` — slow handler + `httptest.NewServer` + `handler_timeout=50ms`; asserts 503 + canned body + slow handler's body did NOT leak through.
> - `TestStatsServer_Slowloris_ReadHeaderTimeout` — the headline security test. Real listener with `read_header_timeout: 200ms`, raw TCP, partial header line, asserts the server closes the connection within 1s.
>
> Two unit tests cover the cheap path:
> - `TestWrapPromHandler_ZeroTimeoutPassesThrough` — fast assertion via `reflect.ValueOf().Pointer()` that the wrap conditional is real (handler value identity preserved for `handler_timeout = 0` and negative).
> - `TestWrapPromHandler_NoWrap_ResponseFlowsThrough` — end-to-end via `httptest.NewServer` that the real response body reaches the client when the wrap is disabled.
>
> ### How to run the new tests locally
>
> ```
> # Fast - what -short CI runs (skips the two integration tests):
> go test -count=1 -short -run 'TestStatsServer_buildRuntime|TestLoadStatsConfig_PromTimeouts|TestStatsTimeoutDefaults|TestWrapPromHandler' .
>
> # Full - runs everything including the two ~200ms integration tests:
> go test -count=1 -run 'TestStatsServer_buildRuntime|TestLoadStatsConfig_PromTimeouts|TestStatsTimeoutDefaults|TestWrapPromHandler|TestStatsServer_Slowloris' .
> ```
>
> ### Why the values we picked
>
> The four `http.Server` defaults are sized for typical Prometheus deployments. None are tight enough to break a real scraper on a slow network; none are loose enough to be a useful slowloris vector. The 30s `handler_timeout` matches `WriteTimeout` so the 503 path fires before the abrupt-close path.
>
> Every value is operator-overridable. We considered adding a hard floor on `handler_timeout` (rejecting e.g. <100ms as "probably a typo") but decided against it: nebula's existing validation rejects only structurally-invalid values, and adding strictness only here would be inconsistent with the rest of the codebase. An operator who configures `handler_timeout: 1ms` and gets nothing but 503s will notice via their alerting and fix the typo.
>
> ### Performance impact on tests
>
> The two integration tests in commit 3 add ~270ms to a full `go test ./...` run of the nebula package (392ms vs the prior 112ms). Both are gated by `testing.Short` so `go test -short ./...` is unaffected (~100ms). If maintainers prefer to gate them behind a build tag instead, the change is trivial.
>
> ### Backward compatibility
>
> No CLI flag changes. No public API changes. The five new yaml keys are optional and default to the new constants. Existing configs continue to work unchanged. The behavior change is that the server now rejects slow-client connection patterns it previously held open; legitimate scrapers will not notice.

---

## Suggested gh command

```sh
gh auth switch --user randomizedcoder
gh pr create \
  --repo slackhq/nebula \
  --base master \
  --head randomizedcoder:prometheus-listener-timeouts \
  --title "Set timeouts on the Prometheus stats HTTP listener" \
  --body-file /tmp/pr-body.md
gh auth switch --user daveseddon-runpod
```

(The body in this draft includes metadata, gh command, and open items
that don't belong in the actual GitHub body. The flow I'll use is:
extract just the lines between the two horizontal rules above into
`/tmp/pr-body.md`, strip the leading `> ` prefix from each line, then
pass that file to gh — same approach as PRs #1724 / #1725 / #1726.)

## Outcome

- Branch pushed to `randomizedcoder/nebula` cleanly on first try.
- PR opened as [slackhq/nebula#1727](https://github.com/slackhq/nebula/pull/1727).
- CLA check (`salesforce-cla`) reported `SUCCESS` on first scan.
- GitHub reports `mergeable: MERGEABLE` immediately after open.
- During design review the operator (user) questioned whether `handler_timeout` should have a hard floor. We decided **against** one: no good objective threshold, inconsistent with the rest of nebula's validation, bounded blast radius (a too-low value makes scrapes 503 but doesn't break anything else). Negative values are still rejected. The PR body section "Why the values we picked" documents this decision.
- `Co-Authored-By: Claude Opus 4.7` trailer is present on all three commits (matching #1726's convention).
