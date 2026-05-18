# PR draft — `log-and-meter-swallowed-errors`

This file is the **record copy** of the upstream PR — committed to the local
`nix` branch as a record of what was sent.

| Field | Value |
|---|---|
| Source | `randomizedcoder:log-and-meter-swallowed-errors` |
| Target | `slackhq/nebula:master` |
| Commits | 5 (one per errcheck real-bug finding, in dependency order — see below) |
| Files modified | `config/config.go`, `config/config_test.go`, `dns_server.go`, `dns_server_test.go`, `sshd/metrics.go` (new), `sshd/reply.go` (new), `sshd/reply_test.go` (new), `sshd/session.go` |
| Diff stat | +529 / -13 |
| Pushed to | `randomizedcoder/nebula` ([branch](https://github.com/randomizedcoder/nebula/tree/log-and-meter-swallowed-errors)) |
| PR | [slackhq/nebula#1726](https://github.com/slackhq/nebula/pull/1726) — opened, `mergeable`, CLA passes on first push |
| Related | [#1724](https://github.com/slackhq/nebula/pull/1724) (gosec G109 firewall port-range), [#1725](https://github.com/slackhq/nebula/pull/1725) (nilerr propagation) — both independent, no file overlap |

## Proposed PR title

```
Surface previously-swallowed errors in DNS, SSH, and config paths
```

## Proposed PR body

The block below is exactly what I will paste into the GitHub PR body.

---

> ### Hi 👋
>
> Five places inside `dns_server.go`, `sshd/session.go`, and `config/config.go` quietly swallowed the error returned by a write/reply/stat call. In each case the operator saw normal output or a misleading success while a real failure (UDP write error, channel torn down mid-handshake, addFile failing on an unresolvable path) went unrecorded. This PR resolves all five at the root, in five small bisect-safe commits. Where the calling API can carry an error, it is now propagated; where it cannot (DNS write callbacks, SSH protocol replies inside a goroutine), the failure is now logged via `slog.Warn` and counted in a `rcrowley/go-metrics` counter so it shows up in the existing metrics export.
>
> ### How we found these
>
> We ran [`errcheck`](https://github.com/kisielk/errcheck) via golangci-lint as part of a strict static-analysis pipeline downstream of this fork. `errcheck` flags every call whose returned error is discarded. After triaging the full report into "real bugs", "cosmetic (test setup, defer-close)", and "false-positive", five real-bug call sites remained:
>
> ```
> config/config.go:351:14:  Error return value of `c.addFile` is not checked
> dns_server.go:194:14:     Error return value of `w.WriteMsg` is not checked
> sshd/session.go:85:13:    Error return value of `req.Reply` is not checked
> sshd/session.go:89:13:    Error return value of `req.Reply` is not checked
> sshd/session.go:96:21:    Error return value of `channel.SendRequest` is not checked
> ```
>
> Each line maps to one commit.
>
> ### Per-site operator impact
>
> | File:line | Function | Pre-fix operator experience |
> |---|---|---|
> | `config/config.go:351` | `(c *C).resolve` | A user-specified config path whose `filepath.Abs` fails is silently dropped — the user sees "no config files found" with no hint of the real cause |
> | `dns_server.go:194` | `handleDnsRequest` | `WriteMsg` failures (client socket closed, FD exhaustion, UDP send error) are invisible; clients quietly timeout and the operator has no signal |
> | `sshd/session.go:85` | `handleRequests` (bad-payload reject) | A malformed exec request rejection that fails to reach the client is invisible — the user sees a hung session, the operator sees nothing |
> | `sshd/session.go:89` | `handleRequests` (accept-exec) | Same shape, but the consequence is worse: today the handler still proceeds to dispatch the command and emit exit-status to a client that never confirmed the accept |
> | `sshd/session.go:96` | `handleRequests` (exit-status) | The final exit-status notification can fail with no record; the client appears to hang for a moment before close |
>
> The `dns_server.go` case is the one most likely to bite an operator in the wild — a single failing client (e.g. a closed-socket replay or a transient UDP error) is currently silent, so a misbehaving DNS consumer is invisible until it is widespread enough to show up elsewhere.
>
> ### Design notes
>
> We thought carefully about how to handle each site:
>
> 1. **No retry**, even for the DNS WriteMsg case. UDP DNS responses are stateless: if the client socket is gone, retrying the same response with the same DNS transaction ID is a protocol violation. FD exhaustion is not solvable by retry. The DNS protocol already expects the resolver layer to retry on no-answer, so adding handler-side retry would only delay the eventual `WriteMsg` failure. **Decision: observe, do not retry.**
>
> 2. **No new dependencies.** The DNS commit adds a `~20`-line atomic-int-based `dnsWriteWarnLimiter` rather than pulling in `golang.org/x/time/rate`. The limiter coalesces high-rate failure bursts so a runaway client does not flood the journal: the first failure in a 10-second window logs immediately with the count of suppressed messages since the last log, the rest only increment the counter. (The counter is exposed regardless of the log rate-limit.)
>
> 3. **`rcrowley/go-metrics` counters everywhere**, following the same dot-separated registry convention the rest of nebula already uses (e.g. `messages.tx.*`). Three new counters:
>     - `dns.responses.write_failures`
>     - `sshd.reply.errors`
>     - `sshd.send_request.errors`
>
> 4. **`replyer` / `requester` interfaces** for the SSH side. `*ssh.Request.Reply` and `*ssh.Channel.SendRequest` are not testable in isolation without standing up a full SSH transport; we extracted single-method interfaces and route the call sites through small helpers (`replyAndLog`, `sendRequestAndLog`). `*ssh.Request` and `*ssh.Channel` satisfy them unchanged; tests inject fakes.
>
> 5. **One commit bails out, the others observe.** Specifically, the SSH `accept-exec` site (sshd/session.go:89) now branches on the helper's return: if the accept-reply fails, the handler closes the channel and bails without running the user's command — proceeding would dispatch a command for which the client never received the accept and would lead to a confused exit-status that the client cannot correlate. The other SSH sites and the DNS site only observe, because at those points the work is either done or there is no useful follow-up action.
>
> ### Commit map
>
> 1. `Return addFile errors from config.resolve` — propagates `filepath.Abs` failures through `addFile` to `resolve`. Test injects a fake `filepathAbs` via a package-level var.
> 2. `Log and meter dns_server WriteMsg failures` — adds the `dnsWriteWarnLimiter` (with a 6-row table-driven test) and routes `WriteMsg` errors through it. Counter `dns.responses.write_failures` increments unconditionally; the Warn is rate-limited to one per 10s.
> 3. `Log and meter SSH protocol reply failures from session handler` — introduces `sshd/metrics.go`, `sshd/reply.go` (`replyer` interface + `replyAndLog`), and `sshd/reply_test.go` (`TestReplyAndLog`, 4-row table). Routes the bad-payload reject site through the helper.
> 4. `Bail out of SSH exec handler when accept-reply fails` — routes the accept-reply through `replyAndLog` and branches on its return so the handler stops cleanly when the accept never reaches the client.
> 5. `Log and meter ssh.Channel.SendRequest failures` — extends `sshd/reply.go` with `requester` + `sendRequestAndLog`, adds `metricSendRequestErrors`, routes the exit-status request through the helper. `TestSendRequestAndLog` is a 4-row table covering success/failure × wantReply.
>
> Mutation-tested: at every commit that adds an observability helper, I removed the metric line and the log line in turn and confirmed the table test catches each mutation. The tests are not tautologies.
>
> All five commits are independently bisect-safe — `go test -count=1 ./...` passes at every SHA on the branch.
>
> ### How to run the new tests locally
>
> ```
> go test -count=1 -v -run 'TestConfig_Resolve_AddFileErrorPropagates' ./config
> go test -count=1 -v -run 'TestDNSWriteWarnLimiter|TestDnsServer_HandleDnsRequest_WriteMsgFailure' .
> go test -count=1 -v -run 'TestReplyAndLog|TestSendRequestAndLog' ./sshd
> ```
>
> ### Backward compatibility
>
> No CLI flag, config key, or public API changes. The only observable behaviour change is that previously-silent failures now appear in the metrics export and the journal, plus the SSH accept-exec path now cleanly aborts on a broken handshake rather than dispatching a command whose accept never landed. All existing tests continue to pass with no edits.

---

## Suggested gh command

```sh
gh auth switch --user randomizedcoder
gh pr create \
  --repo slackhq/nebula \
  --base master \
  --head randomizedcoder:log-and-meter-swallowed-errors \
  --title "Surface previously-swallowed errors in DNS, SSH, and config paths" \
  --body-file /tmp/pr-body.md
gh auth switch --user daveseddon-runpod
```

(The body in this draft includes metadata, gh command, and open items
that don't belong in the actual GitHub body. The flow I'll use is: extract
just the lines between the two horizontal rules above into `/tmp/pr-body.md`,
strip the leading `> ` prefix from each line, then pass that file to gh —
same approach as PRs #1724 and #1725.)

## Outcome

- Branch pushed to `randomizedcoder/nebula` cleanly on first try.
- PR opened as [slackhq/nebula#1726](https://github.com/slackhq/nebula/pull/1726).
- CLA check (`salesforce-cla`) reported `SUCCESS` on first scan — no force-push refresh needed (unlike #1724).
- GitHub reports `mergeable: MERGEABLE` immediately after open.
- `Co-Authored-By: Claude Opus 4.7` trailer is present on all five commits in this PR. Approved as-is by user on review (diverges from #1724 / #1725 which omitted the trailer).
