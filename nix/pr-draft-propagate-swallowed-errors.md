# PR draft — `propagate-swallowed-errors`

This file is the **review copy** of the upstream PR I will open against
`slackhq/nebula` once you approve. It is not committed to upstream — it
lives on the local `nix` branch as a record of what was sent.

| Field | Value |
|---|---|
| Source | `randomizedcoder:propagate-swallowed-errors` |
| Target | `slackhq/nebula:master` |
| Commits | 6 (one per nilerr finding, in TDD order — see below) |
| Files modified | `ssh.go`, `ssh_test.go` (new), `config/config.go`, `config/config_test.go` |
| Diff stat | +447 / -17 |
| Pushed to | (not yet — awaiting approval) |
| Related | [#1724](https://github.com/slackhq/nebula/pull/1724) (gosec G109 firewall port-range), independent of this PR |

## Proposed PR title

```
Return previously-swallowed errors from ssh handlers and config load
```

## Proposed PR body

The block below is exactly what I will paste into the GitHub PR body. Each
paragraph is one physical line so GitHub's markdown renderer controls the
visual wrap — the same convention you see in PR #1724.

---

> ### Hi 👋
>
> Six places inside `ssh.go` and `config/config.go` quietly swallowed errors and returned `nil`. Each one is a path where today a real failure (writer error, malformed cert, missing config path) leaves the operator staring at empty output or a misleading "no files found" message with nothing useful in the logs. This PR resolves all six at the root, in six small bisect-safe commits. Hopefully these tighten the diagnostics that downstream nebula operators rely on when something is off — fewer "huh, that should have worked" moments for anyone running `print-cert`, `host-map`, or just loading a config from a typo'd path.
>
> ### How we found these
>
> We ran [`nilerr`](https://github.com/gostaticanalysis/nilerr) via golangci-lint as part of a strict static-analysis pipeline downstream of this fork. `nilerr` flags any function where a non-nil `err` is observed and then `nil` is returned — exactly the silent-failure pattern we wanted to surface. The lint output was:
>
> ```
> config/config.go:334:3:  error is not nil (line 332) but it returns nil
> ssh.go:463:4:            error is not nil (line 461) but it returns nil
> ssh.go:513:4:            error is not nil (line 511) but it returns nil
> ssh.go:871:4:            error is not nil (line 869) but it returns nil
> ssh.go:879:5:            error is not nil (line 876) but it returns nil
> ssh.go:889:4:            error is not nil (line 887) but it returns nil
> ```
>
> Each line maps to one commit. We label them N1…N6 internally and use those tags below for cross-referencing.
>
> ### Per-site operator impact
>
> | Tag | File:line | Function | What the operator saw on failure (pre-fix) |
> |---|---|---|---|
> | **N2** | `ssh.go:461` | `sshListHostMap` | SSH `host-map -json` writer error mid-stream → truncated JSON, command reports success |
> | **N3** | `ssh.go:511` | `sshListLighthouseMap` | Same as N2 but for `lighthouse-map` |
> | **N4** | `ssh.go:869` | `sshPrintCert` (`-json`/`-pretty`) | Host's cert refuses `MarshalJSON` → empty success response |
> | **N5** | `ssh.go:876` | `sshPrintCert` (`-pretty`) | `json.Indent` fails → empty success response **and** a latent "corrupted-partial-buffer" hazard masked only by the `return nil` |
> | **N6** | `ssh.go:887` | `sshPrintCert` (`-raw`) | Host's cert refuses `MarshalPEM` → empty success response |
> | **N1** | `config/config.go:334` | `(c *C).resolve` | `-config /typoed/path` → "no config files found at /typoed/path" instead of "no such file or directory" |
>
> The N1 case is the one most likely to bite an operator in the wild: a typo in `--config` produces an error message that says "no files found in this directory" when in fact the directory doesn't exist at all. With this fix the operator sees the real `ENOENT`/`EACCES`/`ELOOP` and can fix the typo immediately.
>
> ### How each commit is structured (TDD)
>
> Each commit is one finding, fixed test-first:
>
> 1. **Write a table-driven test** that targets the specific swallow. Every row carries a descriptive `name` so failure traces immediately identify which case regressed.
> 2. **Run the test against the unmodified upstream code** — it MUST fail. This proves the test catches the bug rather than being a tautology.
> 3. **Apply the minimal fix** — turn `return nil` into `return fmt.Errorf("<context>: %w", err)`. The `%w` wrapping preserves `errors.Is` / `errors.As` for callers that want to react to the underlying cause.
> 4. **Run the test again** — must pass.
> 5. **Run the full suite** — `go test -count=1 ./...` stays green; no other tests depended on the swallowed behavior.
>
> Mutation-tested: temporarily reverting the fix line in each commit while keeping the test in place causes at least one new test row to fail. The tests are not tautologies.
>
> All six commits are independently bisect-safe — `go test ./...` passes at every SHA on the branch.
>
> ### How to run the new tests locally
>
> A reviewer can verify the full suite of new tests with two commands:
>
> ```
> go test -count=1 -v -run 'TestC_Load_PropagatesStatErrors' ./config
> go test -count=1 -v -run 'TestSshListHostMap|TestSshListLighthouseMap|TestSshPrintCert' .
> ```
>
> Expected output (17 subtests across 6 parent tests, all PASS):
>
> ```
> # config package — N1
> === RUN   TestC_Load_PropagatesStatErrors
> === RUN   TestC_Load_PropagatesStatErrors/nonexistent_path_returns_the_stat_error_not_a_generic_message
> === RUN   TestC_Load_PropagatesStatErrors/permission_denied_on_parent_dir_returns_EACCES_from_stat
> --- PASS: TestC_Load_PropagatesStatErrors (0.00s)
> PASS
> ok  github.com/slackhq/nebula/config
>
> # nebula package — N2 through N6
> === RUN   TestSshListHostMap_WriteFailure_PropagatesError
>     ─── json_mode,_immediate_writer_failure
>     ─── json_mode,_mid-stream_failure
>     ─── pretty_mode,_immediate_writer_failure
>     ─── pretty_mode,_mid-stream_failure
>     ─── pretty_mode,_late_failure
> --- PASS: TestSshListHostMap_WriteFailure_PropagatesError
> === RUN   TestSshPrintCert_MarshalJSONFails_PropagatesError
>     ─── json_flag
>     ─── pretty_flag
> --- PASS: TestSshPrintCert_MarshalJSONFails_PropagatesError
> === RUN   TestSshPrintCert_IndentError
>     ─── indent_error_propagates
>     ─── indent_error_does_not_write_partial_buffer
> --- PASS: TestSshPrintCert_IndentError
> === RUN   TestSshPrintCert_MarshalPEMFails_PropagatesError
>     ─── raw_flag
> --- PASS: TestSshPrintCert_MarshalPEMFails_PropagatesError
> === RUN   TestSshListLighthouseMap_WriteFailure_PropagatesError
>     ─── json_mode,_immediate_writer_failure
>     ─── json_mode,_mid-stream_failure
>     ─── pretty_mode,_immediate_writer_failure
>     ─── pretty_mode,_mid-stream_failure
>     ─── pretty_mode,_late_failure
> --- PASS: TestSshListLighthouseMap_WriteFailure_PropagatesError
> PASS
> ok  github.com/slackhq/nebula
> ```
>
> To verify each test actually catches its bug (mutation-test a single commit):
>
> ```
> # check out the commit before the fix, run the test from that commit
> git checkout <SHA-of-commit-N>^   # parent SHA
> git checkout <SHA-of-commit-N> -- ssh_test.go   # take just the test from the fix commit
> go test -v -run 'TestSshListHostMap_WriteFailure_PropagatesError' .   # MUST FAIL
> git checkout <SHA-of-commit-N> -- ssh.go        # now take the fix
> go test -v -run 'TestSshListHostMap_WriteFailure_PropagatesError' .   # MUST PASS
> git checkout <branch>                           # return to head
> ```
>
> ### Approach notes
>
> One small companion cleanup landed in commit N5: `ssh.go` had six call sites that all passed `"", "    "` to `json.Encoder.SetIndent` or `json.Indent` — the JSON line-prefix and indent-unit for SSH command output. While editing the N5 call we extracted those into file-scope constants `jsonIndentLinePrefix` and `jsonIndentUnit` and renamed all six sites so each call now says what its arguments mean. Doing it in the same commit avoids leaving five sites with the old magic-string spelling next to one named site.
>
> N1's fix branches on the `direct` flag rather than blanket-propagating: a `direct=true` stat failure (the user-supplied `-config` path) propagates with `%w` wrapping, while a `direct=false` failure (a recursed descendant — e.g. a dangling symlink inside an otherwise-valid config directory) logs via `c.l.Warn` and skips so a single bad entry does not abort a multi-file config reload. This preserves the existing reload resilience while fixing the misleading diagnostic for the direct path.
>
> ### Backward compatibility
>
> No CLI flag, config key, or public API changes. The only observable behaviour change is that previously-silent failures (writer mid-stream errors, unmarshallable certs, missing config paths) now return descriptive errors at the failing call site rather than empty success responses or generic "no files found" messages. All existing tests continue to pass with no edits. No upstream test asserted the exact `"no config files found at %s"` string for a nonexistent path (greped — only the `fmt.Errorf` definition itself appears).

---

## Suggested gh command

```sh
gh pr create \
  --repo slackhq/nebula \
  --base master \
  --head randomizedcoder:propagate-swallowed-errors \
  --title "Return previously-swallowed errors from ssh handlers and config load" \
  --body-file /tmp/pr-body.md
```

(The body in this draft file includes metadata, gh command, and open items
that don't belong in the actual GitHub body. The flow I'll use is: extract
just the lines between the two horizontal rules above into `/tmp/pr-body.md`,
strip the leading `> ` prefix from each line, then pass that file to gh —
same approach as the firewall PR.)

## Open items before opening the PR

1. **Review the body wording.** Anything to add / drop / reframe?
2. **Tone check.** The "Hi 👋" intro is friendly per your guidance — let me know if you'd rather it be neutral / technical.
3. **CLA.** You've already signed for #1724, so this PR should land with `cla:signed` automatically. If it shows `cla:missing` initially, the same force-push-empty-amend trick (or close/reopen) will refresh the status check.
4. **Authorship.** Commit author is `randomizedcoder <dave.seddon.ca@gmail.com>` per your git config; no Claude trailer, matching upstream style and PR #1724.

Say **go** and I'll push the branch + open the PR.
