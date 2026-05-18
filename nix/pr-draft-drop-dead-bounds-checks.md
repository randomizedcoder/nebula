# PR draft — `drop-dead-bounds-checks`

This file is the **record copy** of the upstream PR — committed to the
local `nix` branch as a record of what was sent.

| Field | Value |
|---|---|
| Source | `randomizedcoder:drop-dead-bounds-checks` |
| Target | `slackhq/nebula:master` |
| Commits | 4 (SA4003 cert + crypto_test coverage / SA4003 metrics / encrypt-side style consistency) |
| Files modified | `cert/crypto.go`, `cert/crypto_test.go`, `message_metrics.go`, `message_metrics_test.go` (new), `cmd/nebula-cert/ca.go`, `cmd/nebula-cert/ca_test.go` |
| Diff stat | +919 / -41 |
| Pushed to | `randomizedcoder/nebula` ([branch](https://github.com/randomizedcoder/nebula/tree/drop-dead-bounds-checks)) |
| PR | [slackhq/nebula#1729](https://github.com/slackhq/nebula/pull/1729) — opened, `mergeable`, CLA passes on first push |
| Related | [#1724](https://github.com/slackhq/nebula/pull/1724), [#1725](https://github.com/slackhq/nebula/pull/1725), [#1726](https://github.com/slackhq/nebula/pull/1726), [#1727](https://github.com/slackhq/nebula/pull/1727) — same static-analysis-driven series; no file overlap |

## Proposed PR title

```
Drop dead bounds-check comparisons in cert and metrics paths
```

## Proposed PR body

The block below is what I will paste into the GitHub PR body.

---

> ### Hi 👋
>
> Two functions in this codebase had bounds-check comparisons that staticcheck SA4003 flags as "no value of type X can be less than/greater than Y" — the comparison is unreachable by type construction, so the clause is dead code. Removing the dead halves makes the live bounds checks (the ones that do real work) easier to read and prevents a future reviewer wondering "what does this defend against?". Behaviour is preserved: a value the old condition rejected is still rejected by the simplified condition. Each commit pairs the cleanup with a table-driven test that passes against both forms, providing the bisect-time proof of behaviour preservation. A small consistency commit at the end aligns the encrypt-side mirror of the same code to the new style.
>
> ### How we found these
>
> Downstream of this fork we run staticcheck (and the same checker via golangci-lint) as part of a strict static-analysis pipeline. The relevant findings:
>
> ```
> cert/crypto.go:235:5     no value of type int32 is less than math.MinInt32 (SA4003)
> cert/crypto.go:235:39    no value of type int32 is greater than math.MaxInt32 (SA4003)
> cert/crypto.go:238:27    no value of type uint32 is greater than math.MaxUint32 (SA4003)
> cert/crypto.go:244:31    no value of type uint32 is greater than math.MaxUint32 (SA4003)
> message_metrics.go:22:6  every value of type uint8 is >= 0 (SA4003)
> message_metrics.go:22:38 every value of type uint8 is >= 0 (SA4003)
> message_metrics.go:31:6  every value of type uint8 is >= 0 (SA4003)
> message_metrics.go:31:38 every value of type uint8 is >= 0 (SA4003)
> ```
>
> ### Commits
>
> **1. `Drop dead bounds-check comparisons in cert.unmarshalArgon2Parameters`** (+113 / -9)
>
> Four bounds-check blocks where six clauses are unreachable:
>
> ```
> params.Version < math.MinInt32     // int32, always false
> params.Version > math.MaxInt32     // int32, always false
> params.Memory > math.MaxUint32     // uint32, always false
> params.Memory <= 0                 // uint32 <= 0 is just == 0
> params.Iterations > math.MaxUint32 // uint32, always false
> params.Iterations <= 0             // uint32 <= 0 is just == 0
> ```
>
> The Version block is wholly unreachable so drop it entirely. Memory and Iterations have one live half each: simplify to `== 0`. The Parallelism block stays as-is for the `> math.MaxUint8` half — that one does real work, because the proto field is `uint32` but the Go struct field is `uint8` (proto3 has no uint8 type), so values > 255 must be caught before the cast on the return statement truncates them. The `<= 0` half of the Parallelism check becomes `== 0` for consistency.
>
> Also fixes the doubled "be be" typo ("must be be greater than 0" → "must be greater than 0") in the error messages.
>
> `TestUnmarshalArgon2Parameters_Validation` (8 rows) is added in this commit and pins the remaining bounds-check behaviour. The Parallelism cast-safety surface gets dedicated rows: 256 (boundary), 1000 (mid-range silent-truncation hazard if the bounds check were weakened), and `math.MaxUint32` (extreme overflow). 255 is asserted to be accepted with exactly that value forwarded, catching off-by-one mutations of `> MaxUint8`. The test passes against both the pre- and post-cleanup forms.
>
> **2. `Expand crypto_test.go coverage to all functions in cert/crypto.go`** (+466 / -34)
>
> Pure test additions — no production-code changes. While in `crypto_test.go` for commit 1, I audited every function in `cert/crypto.go` against the positive / negative / bounds / corner / adversarial axes and added table-driven tests for the gaps.
>
> Six tests touched:
>
> | Test | Rows | Type | Covers |
> |---|---:|---|---|
> | `TestNewArgon2Parameters` | 4 | refactored | typical / large / zero values / max-of-each-type |
> | `TestEncryptAndMarshalSigningPrivateKey` | 3 | refactored | adds previously-missing P256 round-trip + invalid-curve rejection |
> | `TestUnmarshalNebulaEncryptedData_RejectsBadInput` | 5 | new | the four early-return guards + happy path |
> | `TestSplitNonceCiphertext` | 5 | new | boundary cases (nonce+1, equal, short, empty) for the lone non-trivial helper |
> | `TestDeriveKey_Validation` | 5 | new | wrong argon version, nil salt, salt-below-128-bits, happy, 128-bit boundary |
> | `TestAes256Decrypt_RejectsBadInput` | 7 | new | adversarial: tampered ciphertext, tampered nonce, wrong passphrase, plus blob-length boundaries |
> | `TestDecryptAndUnmarshalSigningPrivateKey_AlgorithmAndCurveCases` | 2 | new | hand-constructed PEMs reaching the error paths the public Encrypt API can't produce |
>
> Negative-path tests use minimal Argon2 params (`Memory=1, Parallelism=1, Iterations=1`) because they exercise error branches, not the KDF; this keeps wall-clock under 10ms instead of ~350ms with realistic params.
>
> After this commit: **39 sub-tests across 9 functions** covering every function in `cert/crypto.go`. `TestDecryptAndUnmarshalSigningPrivateKey` is left unchanged: its sequential `rest`-chaining tests the multi-key-bundle feature, which would not survive a table-driven refactor.
>
> **3. `Drop dead >= 0 comparisons in MessageMetrics.Rx/Tx`** (+247 / -2)
>
> `MessageMetrics.Rx` and `.Tx` both guarded their counter increment with a four-clause condition:
>
> ```go
> if t >= 0 && int(t) < len(m.rx) && s >= 0 && int(s) < len(m.rx[t]) {
> ```
>
> `t` is `header.MessageType` and `s` is `header.MessageSubType`, both defined as `uint8`. Every `uint8` value satisfies `>= 0`, so `t >= 0` and `s >= 0` are dead. The surviving `< len(...)` bounds checks stay untouched.
>
> `message_metrics_test.go` is new (19 sub-tests):
>
> | Test | Rows | Covers |
> |---|---:|---|
> | `TestMessageMetrics_Rx` | 7 | positive (3 valid coords incl. multi-sub-counter slot rx[4][1]) + negative (subtype OOR for nil/non-nil slot, type OOR, way-out-of-range routing to unknown) |
> | `TestMessageMetrics_Tx` | 7 | mirror of Rx for the tx grid |
> | `TestMessageMetrics_RxInvalid` | 3 | nil receiver / nil counter / happy path |
> | `TestMessageMetrics_NilReceiverIsSafe` | 1 | `(*MessageMetrics)(nil)` doesn't panic on any method |
> | `TestMessageMetrics_NilUnknownCounter` | 1 | out-of-range hits are silent when `rxUnknown`/`txUnknown` are nil |
>
> Plus three benchmarks (`Rx_Valid`, `Rx_Unknown`, `Tx_Valid`) which empirically confirm the cleanup is **performance-neutral**: ~4.8 ns/op ± 0.4 ns within-sample variance both before and after; 0 B/op, 0 allocs/op. The Go compiler already optimizes away `uint8 >= 0`, so this cleanup is purely for readability. The benchmarks live in the test file forever as a tripwire against any future regression on this per-packet hot path.
>
> **4. `Align parseArgonParameters bounds-check style with cert/crypto.go`** (+103 / -6)
>
> `cmd/nebula-cert.parseArgonParameters` validates the operator-supplied `-argon-memory`, `-argon-parallelism`, `-argon-iterations` CLI flags before casting them down to the `uint32`/`uint8`/`uint32` expected by `cert.NewArgon2Parameters`. It is the encrypt-time mirror of the decrypt-time `cert.unmarshalArgon2Parameters` cleaned up in commit 1.
>
> Bring the encrypt-side into the same shape:
>
> - `<= 0` → `== 0` on all three checks (`uint <= 0` is just `uint == 0`; the simpler form makes the equivalence obvious).
> - Keep the `> math.MaxUint32` / `> math.MaxUint8` halves: these are real bounds checks that prevent silent truncation when `uint` (typically `uint64`) is cast down to `uint32`/`uint8` in the next-line call.
> - Same one-line comment above the Parallelism check that `cert/crypto.go` got.
> - Same doubled "be be" typo fix in all three error messages.
>
> staticcheck SA4003 does not flag this site because `uint` on a 64-bit system is `uint64` and the comparison is technically reachable; but the intent is identical to commit 1's case and we want the two sites to stay in sync stylistically.
>
> `TestParseArgonParameters_Validation` (7 rows) is added. The function had zero direct test coverage before this commit.
>
> ### Approach: test-first + behaviour-preserving
>
> Each commit follows the same workflow:
>
> 1. Write a table-driven test that pins the **remaining** (non-dead) bounds-check behaviour.
> 2. Run the test against the unmodified upstream code — it MUST pass (proving the test reflects current behaviour).
> 3. Apply the SA4003 cleanup.
> 4. Run the test again — it MUST still pass (proving the cleanup is behaviour-preserving).
> 5. Mutation test: remove one of the surviving checks, confirm a test row fails. Restore.
>
> The "test passes against both forms" is the bisect-time proof. Every commit is independently bisect-safe (`go test ./...` passes at every SHA on the branch).
>
> ### How to run the new tests locally
>
> ```
> # All the new SA4003-related + coverage tests:
> go test -count=1 -v -run 'TestUnmarshalArgon2Parameters_Validation|TestDeriveKey_Validation|TestAes256Decrypt_RejectsBadInput|TestSplitNonceCiphertext|TestUnmarshalNebulaEncryptedData_RejectsBadInput|TestEncryptAndMarshalSigningPrivateKey|TestNewArgon2Parameters|TestDecryptAndUnmarshalSigningPrivateKey_AlgorithmAndCurveCases' ./cert
>
> go test -count=1 -v -run 'TestMessageMetrics' .
>
> go test -count=1 -v -run 'TestParseArgonParameters_Validation' ./cmd/nebula-cert/
>
> # MessageMetrics benchmarks:
> go test -bench=BenchmarkMessageMetrics -benchmem -count=10 -run=^$ .
> ```
>
> ### Backward compatibility
>
> No CLI flag, config, public API, or wire-format changes. The only observable changes are:
>
> - Two pairs of error messages no longer say "be be" (the doubled-word typo is fixed in both `cert.unmarshalArgon2Parameters` and `cmd/nebula-cert.parseArgonParameters`). Text content is otherwise identical to upstream.
> - The dropped `Version` bounds check in `cert.unmarshalArgon2Parameters` was unreachable, so its removal has no behavioural impact.
>
> All bounds-check behaviour is end-to-end preserved.

---

## Suggested gh command

```sh
gh auth switch --user randomizedcoder
gh pr create \
  --repo slackhq/nebula \
  --base master \
  --head randomizedcoder:drop-dead-bounds-checks \
  --title "Drop dead bounds-check comparisons in cert and metrics paths" \
  --body-file /tmp/pr-body.md
gh auth switch --user daveseddon-runpod
```

## Outcome

- Branch pushed to `randomizedcoder/nebula` cleanly on first try.
- PR opened as [slackhq/nebula#1729](https://github.com/slackhq/nebula/pull/1729).
- CLA check (`salesforce-cla`) reported `SUCCESS` on first scan.
- GitHub reports `mergeable: MERGEABLE` immediately after open.
- During review the operator (user) asked for finer commit granularity, so commit 1 (originally the SA4003 cleanup bundled with the crypto_test coverage audit) was split into commits 1 and 2 to give the maintainer the option to take just the SA4003 fix and reject the coverage expansion.
- During review the operator also asked whether the SA4003 cleanup affected the `MessageMetrics.Rx/Tx` per-packet hot path. Benchmarks were added (and live in the test file) to confirm the cleanup is performance-neutral (~4.8 ns/op ± 0.4 ns within-sample variance both before and after). The Go compiler already optimizes `uint8 >= 0` away; the benchmarks are tripwires against any future regression.
- `Co-Authored-By: Claude Opus 4.7` trailer is present on all four commits (matching #1726/#1727's convention).
- Cleaned up the encrypt-side `parseArgonParameters` to match the new style in a separate commit 4; this site is NOT flagged by SA4003 (because `uint` is platform-dependent) but the intent and risk profile is identical and we wanted the two sites to stay in sync.
