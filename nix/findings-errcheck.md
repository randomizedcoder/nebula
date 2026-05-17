# Deep-dive: `errcheck` findings on the `nix` branch

50 sites flagged by `errcheck` (the lint that reports unchecked error
returns). Captured from `golangci-lint-quick`'s tier-0 run on the
post-`#1725` baseline. This file walks every site and assigns one of
three verdicts — **real bug** (silent failure, should propagate or log),
**cosmetic** (interactive output where a failed write means the user
already has bigger problems), or **test setup** (mechanical upgrade to
`require.NoError`).

The deliverable shape mirrors `nix/findings-nilerr-and-gosec.md`: for
each real-bug site, current code → failure mode → TDD test → fix. The
cosmetic and test-setup sites get a compact triage table because the
remedies are mechanical.

## Summary

| Class | Sites | Action |
|---|---:|---|
| **Real bug** — silent failure in production code | 5 | Per-site TDD test + fix (test first, like the nilerr work) |
| **Cosmetic** — interactive UI writes where failure is unrecoverable anyway | 7 | `//nolint:errcheck` annotation with one-line rationale |
| **Test setup** — `Write`/`WriteString`/`Truncate`/`Seek` in `*_test.go` fixtures | 38 | Convert to `require.NoError(t, err)` so test failures are visible at the source line |
| **Total** | **50** | |

```
By directory:
  cmd/nebula-cert/   34   (mostly test fixtures: 29 test + 5 prod)
  sshd/               5   (all prod — handshake-protocol replies)
  config/             5   (1 prod + 4 test)
  (root)/             5   (1 prod dns + 4 test)
  header/             1   (test)
```

Same `%w` wrapping policy as the nilerr PR: real bugs get
`fmt.Errorf("<context>: %w", err)` or `c.l.Warn(...)` depending on the
caller's signature.

---

# Part 1: Real-bug findings (5)

These are the highest-priority sites — each one represents an operator-
invisible failure today. Five distinct fix shapes, ordered by impact.

## E1. `dns_server.go:439` — DNS response write swallowed

**Current code**

```go
func (d *dnsServer) handleDnsRequest(w dns.ResponseWriter, r *dns.Msg) {
    m := new(dns.Msg)
    m.SetReply(r)
    m.Compress = false

    switch r.Opcode {
    case dns.OpcodeQuery:
        d.parseQuery(m, w)
    }

    w.WriteMsg(m)
}
```

**How it can go wrong**

`miekg/dns`'s `WriteMsg` returns an error when the underlying UDP
socket / TCP connection write fails — network blip, EAGAIN under load,
process running out of FDs, etc. Today nebula's lighthouse DNS server
silently drops the response, and the operator sees client-side
timeouts with no server-side log line to explain what happened.
Diagnosing flaky overlay-DNS resolution requires actual packet
captures because the daemon claims everything is fine.

The handler signature doesn't return error (it's a callback on
`dns.HandleFunc`), so propagation is impossible — the right move is
to `Warn`-log the failure with enough context to correlate against a
pcap.

**TDD test** (new `dns_server_test.go` or extending existing — file
already exists at upstream master):

```go
// fakeResponseWriter is a dns.ResponseWriter whose WriteMsg always
// errors. Used to assert that the handler logs WriteMsg failures
// rather than dropping them silently.
type failingDNSWriter struct{ dns.ResponseWriter }
func (failingDNSWriter) WriteMsg(*dns.Msg) error { return errInjectedDNS }

func TestHandleDnsRequest_WriteMsgFailureIsLogged(t *testing.T) {
    var buf bytes.Buffer
    l := slog.New(slog.NewTextHandler(&buf, nil))
    ds := newTestDNSServer(t, l)

    q := new(dns.Msg).SetQuestion("example.test.", dns.TypeA)
    ds.handleDnsRequest(failingDNSWriter{}, q)

    require.Contains(t, buf.String(), "dns: failed to write response",
        "WriteMsg failures must produce a log line for operator triage")
    require.Contains(t, buf.String(), errInjectedDNS.Error())
}
```

**Proposed fix**

```go
if err := w.WriteMsg(m); err != nil {
    d.l.Warn("dns: failed to write response",
        "error", err,
        "client", w.RemoteAddr().String(),
        "qname", queryName(r))
}
```

(`d.l` is the existing `*slog.Logger` on `*dnsServer`. The `client` /
`qname` attrs are best-effort context — DNS triage often needs both.)

## E2. `config/config.go:338` — `addFile` error swallowed in `resolve`

**Current code**

```go
func (c *C) resolve(path string, direct bool) error {
    i, err := os.Stat(path)
    if err != nil { /* fixed by N1 in PR #1725 */ }

    if !i.IsDir() {
        c.addFile(path, direct)   // ← errcheck flags this
        return nil
    }
    ...
}

func (c *C) addFile(path string, direct bool) error {
    ext := filepath.Ext(path)
    if !direct && ext != ".yaml" && ext != ".yml" {
        return nil
    }
    ap, err := filepath.Abs(path)
    if err != nil {
        return err   // ← currently lost
    }
    c.files = append(c.files, ap)
    return nil
}
```

**How it can go wrong**

`filepath.Abs(path)` returns an error if `os.Getwd()` fails (rare:
deleted-cwd, ENOENT on the working dir). When that happens, `addFile`
returns the error and `resolve` discards it. The file silently fails
to be added to `c.files`. If it was the *only* config file the operator
supplied, `Load` then falls through to "no config files found at %s" —
same diagnostic confusion as the N1 nilerr fix in PR #1725 but via a
different code path.

**TDD test** (in `config/config_test.go`):

```go
func TestC_resolve_AddFileErrorPropagates(t *testing.T) {
    // Construct a setup where filepath.Abs fails. Simplest portable
    // way: cd into a temp dir, remove it, then call resolve on a path
    // there. os.Getwd will fail → filepath.Abs returns an error.
    parent := t.TempDir()
    target := filepath.Join(parent, "x.yml")
    require.NoError(t, os.WriteFile(target, []byte("a: 1\n"), 0o644))

    origCwd, err := os.Getwd()
    require.NoError(t, err)
    require.NoError(t, os.Chdir(parent))
    require.NoError(t, os.RemoveAll(parent))   // cwd is now deleted
    t.Cleanup(func() { _ = os.Chdir(origCwd) })

    c := NewC(test.NewLogger())
    err = c.resolve(target, true)
    require.Error(t, err, "addFile error must propagate via resolve")
}
```

(Caveat: deleted-cwd behavior is platform-sensitive; the test should
skip on platforms where `os.Getwd` doesn't actually fail in that
state.)

**Proposed fix**

```go
if !i.IsDir() {
    return c.addFile(path, direct)
}
```

(One-line change — `addFile` already returns `error`. The
single-line check at the call site was the bug.)

## E3. `sshd/session.go:85` — `req.Reply(false, nil)` on malformed exec payload

**Current code**

```go
case "exec":
    var payload = struct{ Value string }{}
    cErr := ssh.Unmarshal(req.Payload, &payload)
    if cErr != nil {
        req.Reply(false, nil)   // ← errcheck flags this
        return
    }
    req.Reply(true, nil)        // ← E4 below
    ...
```

**How it can go wrong**

When an SSH client sends a malformed `exec` request, the server tries
to reply with "request rejected" via `req.Reply(false, nil)`. If that
write itself fails (channel already torn down, network blip), the
client may be left waiting for a response that never arrives. The
function then `return`s and tears down the request loop, but the
operator gets no log entry naming what happened.

The function signature (`handleRequests`) doesn't return error, so
propagation is impossible — the right move is a `Warn` log.

**TDD test**: harder than the others — needs a fake `*ssh.Request`
whose `Reply` errors. The `ssh.Request` type has unexported fields
and isn't easily mockable. Realistic options:

1. **Refactor first**: extract the reply logic into a small helper
   that takes `func(bool, []byte) error` instead of `*ssh.Request`
   directly, making it test-double-able.
2. **Skip the test**: log + comment that explains the choice; rely
   on code review + the `errcheck` lint to keep the call sites
   honest. Acceptable here because `req.Reply` errors are rare and
   the operator-visible impact is minimal compared to the test
   plumbing cost.

**Proposed fix** (option 2):

```go
if cErr != nil {
    if err := req.Reply(false, nil); err != nil {
        s.l.Warn("ssh: reply to malformed exec request failed", "error", err)
    }
    return
}
```

## E4. `sshd/session.go:89` — `req.Reply(true, nil)` on accepted exec

Same shape as E3 but on the success path. Identical fix.

```go
if err := req.Reply(true, nil); err != nil {
    s.l.Warn("ssh: reply to exec request failed", "error", err)
    return  // bail out — client will be confused otherwise
}
```

The `return` is new: previously a failed `Reply(true)` was silently
followed by `dispatchCommand` and `SendRequest("exit-status", ...)`,
sending an exit status for a command the client doesn't know was
accepted. Cleaner to terminate the handler when the protocol
handshake has already broken.

**TDD note**: same plumbing constraint as E3.

## E5. `sshd/session.go:93` — `channel.SendRequest("exit-status", ...)`

**Current code**

```go
req.Reply(true, nil)
s.dispatchCommand(payload.Value, &stringWriter{channel})

status := struct{ Status uint32 }{uint32(0)}
channel.SendRequest("exit-status", false, ssh.Marshal(status))   // ← E5
channel.Close()
return
```

**How it can go wrong**

The exit-status SendRequest tells the SSH client that the command
finished with status 0. If this fails, the client may see the
connection close without ever receiving an exit code, causing
clients like `ssh host -- run-command` to report exit 255 instead of
0 — confusing for any operator wrapping nebula's SSH endpoint in
scripts.

**Proposed fix**

```go
if err := channel.SendRequest("exit-status", false, ssh.Marshal(status)); err != nil {
    s.l.Warn("ssh: failed to send exit-status to client", "error", err)
}
```

Same TDD plumbing constraint as E3/E4 — `ssh.Channel` is unmockable
without test refactor. Acceptable trade-off.

---

# Part 2: Cosmetic findings (7)

Sites where the unchecked error returns from interactive-UI writes.
If these fail, the user already cannot see the output that's failing
to write, so propagation has no operator benefit. The right action
is a `//nolint:errcheck` annotation with a one-line rationale so
future readers (and future automated lint passes) know the decision
was deliberate.

| ID | Site | Call | Why a failed write is unrecoverable here |
|---|---|---|---|
| C1 | `cmd/nebula-cert/ca.go:201` | `errOut.Write([]byte("Enter passphrase: "))` | Prompt write in passphrase loop; if stderr is broken the operator can't read the prompt anyway, but `pr.ReadPassword()` on the next line still blocks for input. |
| C2 | `cmd/nebula-cert/ca.go:358` | `out.Write([]byte("Usage of ..."))` | `caHelp` usage banner. If `--help` output can't be written, the user is about to see nothing regardless. |
| C3 | `cmd/nebula-cert/ca.go:359` | `out.Write([]byte(stdioHelpText))` | Same as C2 — second line of the help banner. |
| C4 | `cmd/nebula-cert/print.go:123` | `out.Write([]byte("Usage of ..."))` | Same pattern as C2 in the `print` subcommand's help. |
| C5 | `cmd/nebula-cert/sign.go:149` | `errOut.Write([]byte("Enter passphrase: "))` | Same as C1, in `sign`'s CA-key decrypt path. |
| C6 | `sshd/session.go:49` | `newChannel.Reject(ssh.UnknownChannelType, "...")` | If we can't send "rejected" to the client, the connection is broken and they'll figure it out. |
| C7 | `sshd/session.go:120` | `term.Write([]byte(strings.Join(cmds, "\n") + "\n\n"))` | Tab-completion suggestions write. Failed write → user sees no suggestion list; not a correctness issue. |

**Proposed annotation pattern** — write the original line plus a
`//nolint:errcheck` comment naming the rationale:

```go
//nolint:errcheck // stderr prompt; failed write is unrecoverable (user can't read it)
errOut.Write([]byte("Enter passphrase: "))
```

Slightly more verbose than `_ = errOut.Write(...)` but keeps the
intent obvious to a future reader.

---

# Part 3: Test-setup findings (38)

All in `*_test.go` files; mostly `Write` / `WriteString` / `Truncate`
/ `Seek` on `*os.File` test fixtures. If any of these fails the test
is broken (or the temp filesystem is broken), so the right action is
to upgrade them to `require.NoError(t, err)`. That way:

1. The test fails with a clear message naming the line + the I/O
   error if the temp filesystem misbehaves.
2. `errcheck` stops flagging them.
3. The "intent: this write is supposed to succeed" is explicit in
   the source instead of implicit by omission.

Distribution:

| File | Sites | Migration shape |
|---|---:|---|
| `cmd/nebula-cert/verify_test.go` | 13 | `caFile.WriteString(...)` → `_, err := caFile.WriteString(...); require.NoError(t, err)` |
| `cmd/nebula-cert/sign_test.go` | 8 | same shape, mostly `Write` on temp CA/cert files |
| `cmd/nebula-cert/print_test.go` | 8 | same shape |
| `config/config_test.go` | 4 | `os.WriteFile`, `os.Mkdir` — same require.NoError |
| `hostmap_test.go` | 2 | `c.ReloadConfigString(...)` — slightly different shape; the call returns an error that the test should care about |
| `lighthouse_test.go` | 1 | `c.ReloadConfigString(...)` — same |
| `outside_test.go` | 1 | `buffer.Clear()` — returns error from `firewall.Buffer.Clear`; trivially `require.NoError` |
| `header/header_test.go` | 1 | `parsedHeader.Parse(...)` — same |

**Recommended migration pattern**:

```go
// before
caFile.Truncate(0)
caFile.Seek(0, 0)
caFile.Write(badCert)

// after
require.NoError(t, caFile.Truncate(0))
_, err = caFile.Seek(0, 0)
require.NoError(t, err)
_, err = caFile.Write(badCert)
require.NoError(t, err)
```

(Truncate returns only `error`; Seek and Write return `(int64, error)`
and `(int, error)` respectively, so they need the two-line form.)

---

# Suggested PR shape

The 50 findings naturally split into **three PRs of increasing scope**,
each landable independently. I'd suggest opening them in order with
the per-PR rationale stated upfront so upstream maintainers can
review each in isolation:

| PR | Scope | Files | Diff size |
|---|---|---|---|
| **3a** | Real-bug fixes E1–E5 (DNS log, addFile propagate, SSH session log/return) | `dns_server.go`, `config/config.go`, `sshd/session.go` + tests | ~+80/-10 (test plumbing inflates the test count) |
| **3b** | Test cleanup — 38 `_test.go` sites converted to `require.NoError` | the 8 test files listed above | ~+150/-50 (mechanical) |
| **3c** | Cosmetic annotations C1–C7 with `//nolint:errcheck` rationale | `cmd/nebula-cert/{ca,print,sign}.go`, `sshd/session.go` | ~+14/-7 (one comment per site) |

PR 3a is the highest-impact (real silent-failure fixes, analogous in
spirit to PR #1725's nilerr fixes — same "operator-invisible failure"
class). PR 3b is the most mechanical and the easiest to review. PR 3c
is small and uncontroversial.

If upstream prefers fewer larger PRs over more smaller ones, all
three could be bundled as one with three separate sections in the PR
body. The deep-dive doc (this file) is the source of truth either
way.

---

# Verification plan

Once each PR's commits land locally:

1. `go test -count=1 ./...` — full suite green.
2. Mutation test per real-bug commit (E1–E5): revert just the fix
   line, run the targeted test, confirm at least one row fails.
3. `nix build .#checks.x86_64-linux.golangci-lint-quick` — confirm
   the `errcheck` count in the tier-0 output drops by the number
   resolved in that PR.
4. `gofmt -l <changed files>` and `go vet ./...` clean.

Final state after 3a+3b+3c land upstream: tier-0 `errcheck` count
goes from 50 → 0. Combined with PR #1725's nilerr fixes (6 → 0),
the silent-failure surface in nebula's source is fully accounted
for — every remaining tier-0 hit is style/correctness rather than
silent-bug class.
