# PR draft — `firewall-reject-out-of-range-ports`

This file is the **review copy** of the upstream PR I will open against
`slackhq/nebula` once you approve. It is not committed to upstream — it
lives on the local `nix` branch as a record of what was sent.

| Field | Value |
|---|---|
| Source | `randomizedcoder:firewall-reject-out-of-range-ports` |
| Target | `slackhq/nebula:master` |
| Commit | `fd8c5f5` — *Reject port numbers outside [0, 65535] in firewall rule parsing* |
| Diff stat | `firewall.go +28 -11`, `firewall_test.go +148`, `firewall_parseport_bench_test.go +233` (new) |
| Pushed to | `git@github.com:randomizedcoder/nebula.git` (branch `firewall-reject-out-of-range-ports`) |
| Create-PR URL | https://github.com/randomizedcoder/nebula/pull/new/firewall-reject-out-of-range-ports |

---

## Proposed PR title

```
Reject port numbers outside [0, 65535] in firewall rule parsing
```

(60 chars, sentence case, imperative, no trailing period — matches the
shape of recent upstream PR titles such as *Search for config.yaml/yml in
both service and cli mode (#1717)* and *Reset static host list addresses
on change (#1713)*.)

---

## Proposed PR body

The block below is what I will paste into the GitHub PR body. Each
paragraph is one physical line (no embedded line wraps) so GitHub's
markdown renderer controls the visual wrap; this is the same convention
the deep-dive findings doc uses.

> ### What this resolves
>
> Running [`gosec`](https://github.com/securego/gosec) against the nebula source flagged three rule **G109** ("integer overflow conversion", [CWE-190](https://cwe.mitre.org/data/definitions/190.html)) findings in `firewall.go`, all on the same `int32(strconv.Atoi(...))` pattern inside `parsePort`. This PR resolves those three findings at the root — by removing the unsafe conversion altogether — rather than by suppressing them with `//nolint:gosec`.
>
> ### What gosec found
>
> ```
> firewall.go:1071  G109 (CWE-190): Potential Integer overflow made by strconv.Atoi result conversion to int16/32 (Confidence: MEDIUM, Severity: HIGH)
> firewall.go:1092  G109 (CWE-190): Potential Integer overflow made by strconv.Atoi result conversion to int16/32 (Confidence: MEDIUM, Severity: HIGH)
> firewall.go:1093  G109 (CWE-190): Potential Integer overflow made by strconv.Atoi result conversion to int16/32 (Confidence: MEDIUM, Severity: HIGH)
> ```
>
> ### Why those three findings matter — silent failure modes
>
> Tracing the three `int32(strconv.Atoi(s))` sites through the firewall constants `PortAny = 0` and `PortFragment = -1` revealed three silent failure modes — each one a config load that succeeds with no warning, no error, and no log line:
>
> - `port: 4294967296` (a typo for `4242`, say) — `strconv.Atoi` returns `2³²`, `int32(...)` truncates to `0`, which equals `firewall.PortAny`. **A one-port rule silently widens to match every port.**
> - `port: -1` — `int32(-1) == firewall.PortFragment`. **A numeric port silently becomes a fragments-only rule.**
> - `port: -2` — `int32(-2) == notAPort`, the internal-only sentinel. **An internal marker leaks into a live rule.**
>
> The YAML still parses, the firewall still loads, the operator sees no diagnostic. TCP/UDP ports are 16-bit unsigned — anything outside `[0, 65535]` should be a config error, never a silent rule widening.
>
> ### Fix
>
> Replace `int32(strconv.Atoi(s))` with `strconv.ParseUint(s, 10, 16)`. With `bitSize = 16` the port range is encoded in the call site itself: negative input, values above 65535, and any non-decimal byte are rejected by construction. The follow-up `int32(uint16)` widening is provably safe — **all three G109 findings disappear from the gosec report**, with no `//nolint:gosec` suppression, no exclusion list entry, and no comment defending an unsafe conversion. The unsafe conversion is gone.
>
> The constants `firewall.PortAny` (0) and `firewall.PortFragment` (-1) remain reachable only through the documented `port: any` and `port: fragment` keywords. Existing semantics are preserved: `port: 0` still means PortAny, ranges with `start == 0` still force `end = 0`, and the original `Test_parsePort` continues to pass unchanged — every literal error string from before is still produced.
>
> ### Tests
>
> Two new table-driven tests in `firewall_test.go`. Every row carries a `name` describing what is exercised, so a failure clearly identifies which case regressed.
>
> `Test_parsePort_invalid` walks 36 adversarial inputs grouped by attack class — numeric overflow that collides with sentinels (`4294967296`, `4294967297`, `2147483648`, `9223372036854775807`, `65536`), negative inputs (`-1`, `-2`, `-99999`, `-9223372036854775808`), NUL / newline / tab / CR injection (`42\x00`, `\x00`, `4\x002`, `42\n`, `42\t`, `42\r`), hex / octal / binary / float / scientific / underscore notation (`0x10`, `0o20`, `0b101010`, `4.2`, `1e3`, `1_000`), explicit `+` sign, multi-byte and Unicode digits (fullwidth `４２`, Arabic-Indic `٤٢`, superscript `⁴²`, emoji), and range-branch overflow (`1-65536`, `1-4294967296`, `65536-65537`, `-1-100`, `1--1`, `4\x002-100`, `4294967296-4294967300`).
>
> `Test_parsePort_valid_boundaries` locks in the preserved success cases at 0, 1, 65535, the range-with-zero override, and the existing whitespace-trim behavior so future refactors can't accidentally regress these.
>
> Mutation-tested: temporarily reverting the single-port branch to the original `int32(strconv.Atoi(s))` makes six of the new `Test_parsePort_invalid` rows fail (`2^32 truncates to PortAny`, `2^32 plus one truncates to port 1`, `2^31 truncates to INT32_MIN`, `max int64`, `just above max real port`, `order-of-magnitude typo`), confirming the suite would have caught the original bug.
>
> ### Benchmarks
>
> `BenchmarkParsePort` exercises the production path across 10 representative input shapes (keywords, single ports, range, out-of-range, negative, 2^32). For methodology context, `firewall_parseport_bench_test.go` compares four conversion primitives — `strconv.ParseUint(s, 10, 16)`, `strconv.Atoi(s)` + manual range check, `strconv.ParseInt(s, 10, 32)` + manual range check, and a hand-rolled digit loop — so the choice is empirical, not hand-waved.
>
> On a typical single-port input (`4242`), mean of five 500ms runs on x86_64:
>
> ```
> Manual:    11.8 ns/op   0 B/op   0 allocs/op
> Atoi:      13.5 ns/op   0 B/op   0 allocs/op
> ParseUint: 21.6 ns/op   0 B/op   0 allocs/op   (chosen)
> ParseInt:  27.8 ns/op   0 B/op   0 allocs/op
> ```
>
> ParseUint is ~10 ns/op slower than the fastest variant on the hot path. It is chosen for the intrinsic uint16 bounds-checking — the bound lives in the call site (`bitSize 16`) rather than a separate range check that a future refactor could weaken or remove. `parsePort` runs once per rule at config load, so the absolute cost is imperceptible (microseconds for any realistic ruleset).
>
> The bench loop assigns results to package-level sink vars so the Go compiler cannot elide the otherwise-pure `parsePort` call as dead code.
>
> ### Compatibility
>
> No CLI flag, config key, or public API changes. The only observable behavior change is that previously-silent-but-broken inputs (`port: 4294967296`, `port: -1`, `port: -2`, `port: 65536`, etc.) now return an explicit error at config load time instead of installing a quietly-wrong rule.
>
> ### Verifying gosec is now clean on these lines
>
> Before:
>
> ```sh
> $ gosec ./... 2>&1 | grep -A1 'firewall.go:.*G109'
> [firewall.go:1071] - G109 (CWE-190): Potential Integer overflow...
> [firewall.go:1092] - G109 (CWE-190): Potential Integer overflow...
> [firewall.go:1093] - G109 (CWE-190): Potential Integer overflow...
> ```
>
> After this PR: zero G109 findings against `firewall.go`. The remaining gosec findings in the rest of the tree are out of scope here and tracked separately.

---

## Suggested gh command (no `--web`, body from file)

I'll run something like the below once you say go. The body lives in
this file from the `### Summary` heading down to the end of the
`### Compatibility` section, so I'll extract it directly rather than
re-typing.

```sh
gh pr create \
  --repo slackhq/nebula \
  --base master \
  --head randomizedcoder:firewall-reject-out-of-range-ports \
  --title "Reject port numbers outside [0, 65535] in firewall rule parsing" \
  --body-file nix/pr-draft-firewall-port-range.md
```

The `--body-file` form will include this whole document — that's more
than the body needs. The actual flow will be: I'll write a stripped
version to `/tmp/pr-body.md` (just the `>` quoted block minus the
leading `> ` prefix) and point `--body-file` at it. The version in this
review file keeps the metadata so you have the audit trail.

---

## Open items before opening the PR

1. **Review the body wording.** Anything you want reframed? Add / drop sections? The current draft leads with "Why this is dangerous" before the fix because the security framing is the load-bearing argument; flip if you want a more neutral lead.
2. **Add a reference to the deep-dive doc?** The `nix/findings-nilerr-and-gosec.md` file lives on your fork's `nix` branch (commit `0ab50e2`). I could include a link if you want the PR to point at the longer analysis, or keep it self-contained.
3. **Issue link.** Nebula doesn't seem to require a linked issue (recent PRs go straight in), but if you'd like to file one first for discussion, that changes the body shape.
4. **Confirm authorship.** Commit author is already `randomizedcoder <dave.seddon.ca@gmail.com>` per your git config; no Claude trailer, matching upstream style.

Say go (with any edits) and I'll open the PR.
