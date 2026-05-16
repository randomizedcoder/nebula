# Deep-dive: `nilerr` and `gosec` findings on the `nix` branch

Each finding from the static analysis baseline (see `nix/static-analysis-report.md`)
is examined here with:

- **Current code** — exact lines as they exist today.
- **How it can go wrong** — concrete failure paths, not just "the linter complained".
- **TDD test** — a failing test you can add today that proves the bug. Tests are
  written so they fail against current code and pass against the proposed fix.
- **Proposed fix** — the minimal change to make the test pass.

Findings are ordered by severity (real bug → security audit gap → false positive).

---

# Part 1: `nilerr` (6 findings)

`nilerr` flags code where a non-nil `err` is observed and then `nil` is returned.
In every case below, an error path is silently swallowed.

## N1. `config/config.go:331-335` — `os.Stat` error swallowed when resolving config path

**Current code**

```go
// direct signifies if this is the config path directly specified by the user,
// versus a file/dir found by recursing into that path
func (c *C) resolve(path string, direct bool) error {
    i, err := os.Stat(path)
    if err != nil {
        return nil
    }
    ...
}
```

**How it can go wrong**

`resolve` is called from `Load` (`config/config.go:45`) with `direct=true`. If
the user-supplied `-config` path fails `os.Stat`, the error is dropped. The
caller's downstream check (`len(c.files) == 0` on line 50) does fire and the
user eventually gets an error — but the error becomes the generic
`"no config files found at %s"` instead of the actual cause. Concrete examples:

| Real failure | What the user sees today | What they should see |
|---|---|---|
| Typo: `-config /etc/nebula/cnf` | `no config files found at /etc/nebula/cnf` | `stat /etc/nebula/cnf: no such file or directory` |
| Permission denied: `-config /root/nebula` as a non-root user | `no config files found at /root/nebula` | `stat /root/nebula: permission denied` |
| Symlink loop: `-config /var/nebula/loop` | `no config files found at /var/nebula/loop` | `stat /var/nebula/loop: too many levels of symbolic links` |
| Stale NFS handle: `-config /mnt/cfg` | `no config files found at /mnt/cfg` | `stat /mnt/cfg: stale file handle` |

The user wastes time looking for a file-listing bug when the real issue is a
filesystem error. For the recursive case (`direct=false`), it's reasonable to
log-and-skip — but for the direct case, the diagnostic should propagate.

**TDD test** (in `config/config_test.go`):

```go
func TestC_Load_NonexistentDirect_ReturnsStatError(t *testing.T) {
    c := NewC(test.NewLogger())
    err := c.Load("/nonexistent/definitely/not/here/" + t.Name())

    require.Error(t, err)
    // The diagnostic should mention WHY, not just "no files found"
    assert.ErrorContains(t, err, "no such file or directory",
        "user should see the underlying stat error, not just 'no config files found'")
}

func TestC_Load_PermissionDenied_ReturnsStatError(t *testing.T) {
    if os.Getuid() == 0 {
        t.Skip("permission test is meaningless as root")
    }
    dir := t.TempDir()
    require.NoError(t, os.WriteFile(filepath.Join(dir, "x.yml"),
        []byte("foo: bar\n"), 0644))
    require.NoError(t, os.Chmod(dir, 0o000))
    t.Cleanup(func() { _ = os.Chmod(dir, 0o700) })

    c := NewC(test.NewLogger())
    err := c.Load(dir)

    require.Error(t, err)
    assert.ErrorContains(t, err, "permission denied",
        "user should see EACCES, not 'no config files found'")
}
```

These tests **fail today** because `Load` returns `"no config files found at …"`
even when the real error was ENOENT or EACCES.

**Proposed fix**

```go
func (c *C) resolve(path string, direct bool) error {
    i, err := os.Stat(path)
    if err != nil {
        if direct {
            return fmt.Errorf("stat %s: %w", path, err)
        }
        // A descendant of a user-supplied directory: log and skip so a single
        // unreadable file does not kill the whole reload.
        c.l.Warn("skipping config entry",
            "path", path, "error", err)
        return nil
    }
    ...
}
```

`%w` wrapping preserves the original `os.PathError` so callers can still
`errors.As` it.

---

## N2. `ssh.go:455-475` — SSH `host-map list` swallows JSON encoder error

**Current code**

```go
if fs.Json || fs.Pretty {
    js := json.NewEncoder(w.GetWriter())
    if fs.Pretty {
        js.SetIndent("", "    ")
    }

    err := js.Encode(hm)
    if err != nil {
        return nil
    }

} else {
    ...
}
```

**How it can go wrong**

`json.Encoder.Encode` returns an error when:

1. The underlying `io.Writer` (the SSH session) errors — most commonly because
   the SSH client disconnected mid-stream, or the server-side write buffer hit
   a network error.
2. A struct member is non-marshallable (less likely here — `hm` is plain data).

When (1) fires, `Encode` typically completes only part of the output before the
write fails. The current code returns `nil`, so the SSH command handler thinks
the listing succeeded and continues. The next thing the handler does in this
function is `return nil` (line 475), which signals "command complete". If the
client *reconnects* (e.g. via session resumption) it sees a half-written JSON
blob with no error indication.

This also makes debugging a flaky `host-map list` over a lossy connection much
harder for operators: nothing is logged, nothing is returned, and the symptom
is a truncated reply.

**TDD test** (in `ssh_test.go` — would need a new file if absent):

```go
// failingWriter writes the first n bytes then returns errInjected.
type failingWriter struct {
    buf       bytes.Buffer
    afterBytes int
    written    int
}

var errInjected = errors.New("injected write failure")

func (f *failingWriter) Write(p []byte) (int, error) {
    remaining := f.afterBytes - f.written
    if remaining <= 0 {
        return 0, errInjected
    }
    if len(p) > remaining {
        n, _ := f.buf.Write(p[:remaining])
        f.written += n
        return n, errInjected
    }
    n, err := f.buf.Write(p)
    f.written += n
    return n, err
}

type captureStringWriter struct{ w io.Writer }
func (c *captureStringWriter) GetWriter() io.Writer        { return c.w }
func (c *captureStringWriter) WriteLine(s string) error    { _, e := c.w.Write([]byte(s + "\n")); return e }
func (c *captureStringWriter) WriteBytes(b []byte) error   { _, e := c.w.Write(b); return e }

func TestSshListHostMap_WriteFailure_PropagatesError(t *testing.T) {
    f := newTestInterface(t)              // helper that returns an *Interface
    addHostMapEntries(t, f.hostMap, 50)   // enough entries so JSON > afterBytes

    sw := &captureStringWriter{w: &failingWriter{afterBytes: 16}}

    err := sshListHostMap(f, &sshListHostMapFlags{Json: true}, sw)

    require.Error(t, err,
        "ssh handler must propagate the writer error so operators can diagnose lost output")
    assert.ErrorIs(t, err, errInjected)
}
```

This test **fails today** because the handler returns `nil` even when the
writer errors.

**Proposed fix** (lines 461-464):

```go
if err := js.Encode(hm); err != nil {
    return fmt.Errorf("encode host-map json: %w", err)
}
```

(Wrap with `fmt.Errorf` so the SSH client sees a useful prefix; raw
`return err` is also acceptable.)

---

## N3. `ssh.go:505-514` — Identical bug in `sshListLighthouseMap`

**Current code**

```go
if fs.Json || fs.Pretty {
    js := json.NewEncoder(w.GetWriter())
    if fs.Pretty {
        js.SetIndent("", "    ")
    }

    err := js.Encode(addrMap)
    if err != nil {
        return nil
    }
} else {
    ...
}
```

**How it can go wrong** — identical to N2.

**TDD test** — symmetric to N2 but calling `sshListLighthouseMap` against a
LightHouse with at least one entry. Sketch:

```go
func TestSshListLighthouseMap_WriteFailure_PropagatesError(t *testing.T) {
    lh := newTestLightHouse(t)
    seedLighthouseAddrMap(t, lh, 50)

    sw := &captureStringWriter{w: &failingWriter{afterBytes: 16}}

    err := sshListLighthouseMap(lh, &sshListHostMapFlags{Pretty: true}, sw)

    require.Error(t, err)
    assert.ErrorIs(t, err, errInjected)
}
```

**Proposed fix**: same as N2 — `return fmt.Errorf("encode lighthouse-map json: %w", err)`.

---

## N4. `ssh.go:868-872` — `sshPrintCert` swallows `cert.MarshalJSON` error

**Current code**

```go
if args.Json || args.Pretty {
    b, err := cert.MarshalJSON()
    if err != nil {
        return nil
    }
    ...
}
```

**How it can go wrong**

`Certificate.MarshalJSON` can return an error when the underlying cert has an
unsupported curve or malformed fields. The cert here is retrieved from
`hostInfo.GetCert().Certificate` (line 865), which is reconstructed from
network input during the handshake. A malformed cert that survived parsing
(e.g. a cert from a newer nebula version with an unknown field) would
fail to marshal.

Returning `nil` makes the SSH client see a successful command with no output.
The operator running `print-cert` over SSH to debug a connection has no
indication that the cert exists but won't serialize.

**TDD test** sketch (in `ssh_test.go`):

```go
// fakeCert satisfies the cert.Certificate interface enough to be set on a
// HostInfo, but MarshalJSON always errors.
type unmarshallableCert struct{ cert.Certificate }
func (u unmarshallableCert) MarshalJSON() ([]byte, error) {
    return nil, errors.New("cert: cannot marshal experimental fields")
}

func TestSshPrintCert_MarshalJSONFails_PropagatesError(t *testing.T) {
    ifce := newTestInterface(t)
    hi := newTestHostInfo(t, netip.MustParseAddr("10.0.0.1"))
    hi.SetCert(unmarshallableCert{...})
    ifce.hostMap.Add(hi)

    sw := newRecordingStringWriter()
    err := sshPrintCert(ifce, &sshPrintTunnelFlags{Json: true},
        []string{"10.0.0.1"}, sw)

    require.Error(t, err)
}
```

**Proposed fix**:

```go
b, err := cert.MarshalJSON()
if err != nil {
    return fmt.Errorf("marshal cert json: %w", err)
}
```

---

## N5. `ssh.go:874-881` — `sshPrintCert` swallows `json.Indent` AND returns corrupt data

**Current code**

```go
if args.Pretty {
    buf := new(bytes.Buffer)
    err := json.Indent(buf, b, "", "    ")
    b = buf.Bytes()                       // ⚠️ assigned BEFORE checking err
    if err != nil {
        return nil
    }
}

return w.WriteBytes(b)
```

**How it can go wrong**

Two distinct problems compound:

1. `json.Indent` can fail partway through (invalid JSON in `b`). When it does,
   `buf` contains a partial, possibly-corrupt indented blob.
2. The code assigns `b = buf.Bytes()` **before** checking the error. If `args.Pretty`
   were the only branch and `err` were swallowed instead of returning, the
   caller would receive the corrupt buffer. Today the bug is masked by the
   `return nil` two lines later — but the corrupt assignment is still latent,
   and any future refactor that removes the `return nil` would emit garbage.

Even with the current swallowing return, the failure mode is bad: the operator
sees no output and no error.

**TDD tests** — two cases:

```go
func TestSshPrintCert_IndentError_PropagatesError(t *testing.T) {
    // craft a Cert whose MarshalJSON returns syntactically-invalid JSON
    // so json.Indent fails when -pretty is set
    ifce, hi := setupHostWithMalformedJSONCert(t)
    ifce.hostMap.Add(hi)

    sw := newRecordingStringWriter()
    err := sshPrintCert(ifce, &sshPrintTunnelFlags{Pretty: true},
        []string{"10.0.0.1"}, sw)

    require.Error(t, err)
}

// Documents the dormant "assign before check" bug — would catch any future
// refactor that removed the swallowing return.
func TestSshPrintCert_IndentError_DoesNotWritePartialBuffer(t *testing.T) {
    ifce, hi := setupHostWithMalformedJSONCert(t)
    ifce.hostMap.Add(hi)

    sw := newRecordingStringWriter()
    _ = sshPrintCert(ifce, &sshPrintTunnelFlags{Pretty: true},
        []string{"10.0.0.1"}, sw)

    assert.Empty(t, sw.bytesWritten,
        "must not emit a partially-indented buffer when json.Indent fails")
}
```

**Proposed fix** — check the error first, and don't reassign on failure:

```go
if args.Pretty {
    buf := new(bytes.Buffer)
    if err := json.Indent(buf, b, "", "    "); err != nil {
        return fmt.Errorf("indent cert json: %w", err)
    }
    b = buf.Bytes()
}
```

---

## N6. `ssh.go:886-890` — `sshPrintCert` swallows `cert.MarshalPEM` error

**Current code**

```go
if args.Raw {
    b, err := cert.MarshalPEM()
    if err != nil {
        return nil
    }

    return w.WriteBytes(b)
}
```

**How it can go wrong** — symmetric to N4 but for the PEM path. `MarshalPEM`
fails on unsupported curves or banner mismatches. Today the operator sees no
output and no error.

**TDD test** sketch:

```go
func TestSshPrintCert_MarshalPEMFails_PropagatesError(t *testing.T) {
    ifce, hi := setupHostWithUnsupportedCurveCert(t)
    ifce.hostMap.Add(hi)

    sw := newRecordingStringWriter()
    err := sshPrintCert(ifce, &sshPrintTunnelFlags{Raw: true},
        []string{"10.0.0.1"}, sw)

    require.Error(t, err)
}
```

**Proposed fix**:

```go
b, err := cert.MarshalPEM()
if err != nil {
    return fmt.Errorf("marshal cert pem: %w", err)
}
return w.WriteBytes(b)
```

---

# Part 2: `gosec` HIGH findings (7)

Reading order is "most actionable first" — real bugs before justified
false-positives.

## G1. `firewall.go:1067,1082,1087` (4 gosec hits) — port-range parsing accepts any 64-bit integer

**Current code**

```go
const notAPort int32 = -2
if s == "any" {
    return firewall.PortAny, firewall.PortAny, nil          // 0
}
if s == "fragment" {
    return firewall.PortFragment, firewall.PortFragment, nil // -1
}
if !strings.Contains(s, `-`) {
    rPort, err := strconv.Atoi(s)
    if err != nil {
        return notAPort, notAPort, fmt.Errorf("was not a number; `%s`", s)
    }
    return int32(rPort), int32(rPort), nil          // ← G109 hit, twice
}

sPorts := strings.SplitN(s, `-`, 2)
...
rStartPort, err := strconv.Atoi(sPorts[0])
...
rEndPort, err := strconv.Atoi(sPorts[1])
...
startPort := int32(rStartPort)                       // ← G109 hit
endPort := int32(rEndPort)                           // ← G109 hit
```

gosec is right to flag this, but the framing ("integer overflow") understates
the consequence. The constants involved are:

```go
// firewall/packet.go
PortAny      = 0   // matches port: any
PortFragment = -1  // matches port: fragment
```

**How it can go wrong** — silent configuration footgun:

| Operator writes in config | `strconv.Atoi` returns | `int32(...)` becomes | Firewall behaves as |
|---|---|---|---|
| `port: 4242` | 4242 | 4242 | port 4242 ✓ |
| `port: 65536` | 65536 | 65536 | port 65536 (not a real TCP port) |
| `port: -1` | -1 | -1 = `PortFragment` | **fragments only** (wrong rule) |
| `port: 4294967296` (typo for 4242) | 4294967296 | 0 = `PortAny` | **all ports open** (rule expanded) |
| `port: 4294967297` (any 2^32+k) | 4294967297 | 1 | port 1 |
| `port: -2` | -2 | -2 = `notAPort` sentinel | rule accepts, internal sentinel leaks |

The 4294967296 → `PortAny` case is the most dangerous: a typo in the config
silently widens a "permit one port" rule to "permit all ports". An operator
who meant to allow port 4242 ends up exposing every UDP/TCP port on the
overlay.

**TDD tests** — add to `firewall_test.go` `Test_parsePort`:

```go
func Test_parsePort_RejectsOutOfRange(t *testing.T) {
    // The most dangerous case: large integer truncates to PortAny.
    _, _, err := parsePort("4294967296")
    require.Error(t, err,
        "port outside [0,65535] must be rejected, "+
            "not silently truncate to firewall.PortAny")
    assert.ErrorContains(t, err, "out of range")

    _, _, err = parsePort("65536")
    require.Error(t, err)

    _, _, err = parsePort("-1")
    require.Error(t, err,
        "negative numeric ports must be rejected; "+
            "use the literal 'fragment' keyword instead")

    // Range syntax must also reject out-of-range
    _, _, err = parsePort("1-65536")
    require.Error(t, err)

    _, _, err = parsePort("4294967296-4294967300")
    require.Error(t, err)
}

func Test_parsePort_AcceptsBoundary(t *testing.T) {
    s, e, err := parsePort("65535")
    require.NoError(t, err)
    assert.Equal(t, int32(65535), s)
    assert.Equal(t, int32(65535), e)

    s, e, err = parsePort("0-65535")
    require.NoError(t, err)
    assert.Equal(t, int32(0), s)
    assert.Equal(t, int32(65535), e)
}
```

The first test **fails today** — `parsePort("4294967296")` returns `(0, 0, nil)`
instead of an error.

**Proposed fix** — validate the range before truncating:

```go
func parsePort(s string) (int32, int32, error) {
    const notAPort int32 = -2
    const maxPort  = 65535

    validate := func(n int) error {
        if n < 0 || n > maxPort {
            return fmt.Errorf("port %d out of range [0,%d]; "+
                "use 'any' for all ports or 'fragment' for IP fragments", n, maxPort)
        }
        return nil
    }

    if s == "any" {
        return firewall.PortAny, firewall.PortAny, nil
    }
    if s == "fragment" {
        return firewall.PortFragment, firewall.PortFragment, nil
    }

    if !strings.Contains(s, `-`) {
        rPort, err := strconv.Atoi(s)
        if err != nil {
            return notAPort, notAPort, fmt.Errorf("was not a number; `%s`", s)
        }
        if err := validate(rPort); err != nil {
            return notAPort, notAPort, err
        }
        return int32(rPort), int32(rPort), nil
    }

    sPorts := strings.SplitN(s, `-`, 2)
    for i := range sPorts {
        sPorts[i] = strings.Trim(sPorts[i], " ")
    }
    if len(sPorts) != 2 || sPorts[0] == "" || sPorts[1] == "" {
        return notAPort, notAPort, fmt.Errorf("appears to be a range but could not be parsed; `%s`", s)
    }

    rStartPort, err := strconv.Atoi(sPorts[0])
    if err != nil {
        return notAPort, notAPort, fmt.Errorf("beginning range was not a number; `%s`", sPorts[0])
    }
    if err := validate(rStartPort); err != nil {
        return notAPort, notAPort, err
    }

    rEndPort, err := strconv.Atoi(sPorts[1])
    if err != nil {
        return notAPort, notAPort, fmt.Errorf("ending range was not a number; `%s`", sPorts[1])
    }
    if err := validate(rEndPort); err != nil {
        return notAPort, notAPort, err
    }

    startPort := int32(rStartPort)
    endPort := int32(rEndPort)

    if startPort == firewall.PortAny {
        endPort = firewall.PortAny
    }
    return startPort, endPort, nil
}
```

This also eliminates the gosec G109 warnings — `validate` proves the value
fits in `int32` (and in fact in `uint16`) before the conversion.

---

## G2. `cert/crypto.go:74` — G407 hardcoded IV/nonce (FALSE POSITIVE)

**Current code**

```go
nonce := make([]byte, gcm.NonceSize())
if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
    return nil, err
}

ciphertext := gcm.Seal(nil, nonce, data, nil)         // ← G407 fires here
```

**Why gosec flags it**

gosec's G407 heuristic looks for "a `[]byte` allocated by `make` that is later
passed to `Seal`". The rule is meant to catch:

```go
nonce := make([]byte, 12)   // zero-filled
ciphertext := gcm.Seal(nil, nonce, data, nil) // disaster: same nonce every call
```

The pattern matcher does not follow the data flow through `io.ReadFull(rand.Reader, …)`.

**Why this code is actually correct**

This is the canonical pattern from the
[Go `crypto/cipher` documentation](https://pkg.go.dev/crypto/cipher#example-NewGCM-Encrypt):
allocate a buffer the size of `NonceSize()`, fill it with cryptographic
randomness from `rand.Reader`, then call `Seal`. The nonce is fresh per call
and unique with overwhelming probability (96-bit GCM nonce, birthday bound
≈ 2⁴⁸ encryptions before collision risk becomes meaningful).

The `rand.Reader` path even handles the error correctly (`return nil, err`
on line 71), so a failing entropy source aborts the encryption rather than
proceeding with a partially-initialized nonce.

**TDD test** — the right test is a *property* of the function: every call
must produce a unique nonce (and therefore unique ciphertext) for identical
input.

```go
// cert/crypto_test.go (new test)
func TestAes256Encrypt_NonceIsRandomPerCall(t *testing.T) {
    pass := []byte("hunter2hunter2")
    params := NewArgon2Parameters(64*1024, 4, 1)
    plaintext := bytes.Repeat([]byte{0xAB}, 64)

    ct1, err := aes256Encrypt(pass, params, plaintext)
    require.NoError(t, err)

    ct2, err := aes256Encrypt(pass, params, plaintext)
    require.NoError(t, err)

    // The first NonceSize() bytes are the nonce; the rest is GCM ciphertext.
    // If the nonce were hardcoded, identical plaintext + identical key would
    // produce identical ciphertext.
    require.NotEqual(t, ct1, ct2,
        "encrypting the same plaintext twice must NOT produce identical ciphertext; "+
        "this would indicate a static nonce — a critical AES-GCM failure")
}
```

This test passes today and would fail if anyone "fixed" the gosec finding by
hardcoding the nonce.

**Proposed action**

Annotate the call site to document the rationale and silence gosec for this
specific instance:

```go
nonce := make([]byte, gcm.NonceSize())
if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
    return nil, err
}

//nolint:gosec // G407: nonce is freshly populated from crypto/rand on the
// preceding line; this is the canonical AES-GCM encrypt pattern documented
// at https://pkg.go.dev/crypto/cipher#example-NewGCM-Encrypt.
ciphertext := gcm.Seal(nil, nonce, data, nil)
```

The nolint annotation is the right outcome here because the property test
proves correctness — the comment + test combo makes the intent and the
verification explicit.

---

## G3. `cmd/nebula/notify_linux.go:22` — G704 SSRF via `NOTIFY_SOCKET` (JUSTIFIED)

**Current code**

```go
func notifyReady(l *slog.Logger) {
    sockName := os.Getenv("NOTIFY_SOCKET")
    if sockName == "" {
        l.Debug("NOTIFY_SOCKET systemd env var not set, not sending ready signal")
        return
    }

    conn, err := net.DialTimeout("unixgram", sockName, time.Second)  // ← G704
    if err != nil {
        l.Error("failed to connect to systemd notification socket", "error", err)
        return
    }
    defer conn.Close()

    err = conn.SetWriteDeadline(time.Now().Add(time.Second))
    if err != nil { ... return }

    if _, err = conn.Write([]byte(SdNotifyReady)); err != nil { ... }
    ...
}
```

**Why gosec flags it**

`os.Getenv` is treated as "tainted user input" by gosec's taint tracker. Any
network call that uses a tainted value is flagged as potential
Server-Side Request Forgery.

**Why the framing is wrong here**

This is the standard
[systemd `sd_notify` integration](https://www.freedesktop.org/software/systemd/man/sd_notify.html).
The contract is:

1. systemd sets `NOTIFY_SOCKET=/run/systemd/notify` (or similar) in the
   service's environment before exec'ing the daemon.
2. The daemon connects to that socket and writes `READY=1` to inform systemd
   it's up.

A malicious actor controlling the daemon's environment is already inside the
trust boundary — they could simply replace the binary. The "attacker can
redirect us to a different unix socket" scenario gains them nothing: this code
only sends the fixed 7-byte string `READY=1` and discards the connection.
There is no SSRF surface (no fetching of data, no proxying, no host-header
manipulation).

**TDD test** — verify the contract: when `NOTIFY_SOCKET` points to a real
unix datagram socket, `READY=1` is delivered; otherwise the function returns
without error or side effect.

```go
// notify_linux_test.go (new test)
func TestNotifyReady_WritesReadyToSocket(t *testing.T) {
    if runtime.GOOS != "linux" {
        t.Skip("Linux-only systemd notify")
    }
    dir := t.TempDir()
    sockPath := filepath.Join(dir, "notify.sock")

    // Listen on a unixgram socket
    addr, err := net.ResolveUnixAddr("unixgram", sockPath)
    require.NoError(t, err)
    conn, err := net.ListenUnixgram("unixgram", addr)
    require.NoError(t, err)
    defer conn.Close()

    t.Setenv("NOTIFY_SOCKET", sockPath)

    done := make(chan []byte, 1)
    go func() {
        buf := make([]byte, 32)
        n, _ := conn.Read(buf)
        done <- buf[:n]
    }()

    notifyReady(test.NewLogger())

    select {
    case msg := <-done:
        assert.Equal(t, "READY=1", string(msg))
    case <-time.After(2 * time.Second):
        t.Fatal("did not receive READY=1 within 2s")
    }
}

func TestNotifyReady_NoEnv_NoCall(t *testing.T) {
    t.Setenv("NOTIFY_SOCKET", "")
    notifyReady(test.NewLogger())   // must not panic, must not block
}
```

The first test would catch any regression that changes the message or path
lookup.

**Proposed action** — annotate:

```go
//nolint:gosec // G704: NOTIFY_SOCKET is the documented systemd sd_notify
// integration. Only the fixed 7-byte string "READY=1" is written; there
// is no remote-fetched data or proxying surface.
conn, err := net.DialTimeout("unixgram", sockName, time.Second)
```

---

## G4. `cmd/nebula-cert/stdio.go:110` — G703 path traversal in CLI tool (JUSTIFIED)

**Current code**

```go
// writeOutput writes data to path, or to stdout when path is stdioPath.
func writeOutput(path string, data []byte, perm os.FileMode, stdout io.Writer) error {
    if path == stdioPath {
        _, err := stdout.Write(data)
        return err
    }
    return os.WriteFile(path, data, perm)   // ← G703
}
```

**Why gosec flags it**

The `path` argument traces back to CLI flags like `-out-key` and `-out-crt`,
which gosec marks as tainted. A `WriteFile` on a tainted path is flagged as
path traversal.

**Why the framing is wrong here**

`nebula-cert` is a single-binary CLI tool. The user invoking it has direct
shell access. They are not in an adversarial relationship with their own
shell — `-out-key /etc/shadow` would write where they asked, but they could
also `cat /etc/shadow` directly with the same privileges. There is no
"attacker controls the path" path here that isn't already
"attacker controls the host".

This is not the same as a web service taking a path from a request body
(where G703 applies and the path needs sanitization). It's a command-line tool
taking a command-line argument.

**TDD test** — the contract is "the file is written exactly where the user
specified, with the requested mode":

```go
// stdio_test.go (new test)
func TestWriteOutput_RespectsFlagPath(t *testing.T) {
    dir := t.TempDir()
    target := filepath.Join(dir, "subdir", "out.key")
    require.NoError(t, os.MkdirAll(filepath.Dir(target), 0o755))

    err := writeOutput(target, []byte("payload"), 0o600, io.Discard)
    require.NoError(t, err)

    got, err := os.ReadFile(target)
    require.NoError(t, err)
    assert.Equal(t, "payload", string(got))

    stat, err := os.Stat(target)
    require.NoError(t, err)
    assert.Equal(t, os.FileMode(0o600), stat.Mode().Perm(),
        "perm parameter must be honored so private keys land at 0600")
}

func TestWriteOutput_StdioWritesToProvidedWriter(t *testing.T) {
    var buf bytes.Buffer
    err := writeOutput(stdioPath, []byte("payload"), 0o600, &buf)
    require.NoError(t, err)
    assert.Equal(t, "payload", buf.String())
}
```

**Proposed action** — annotate:

```go
//nolint:gosec // G703: path is a CLI flag (-out-crt / -out-key) controlled
// by the operator running nebula-cert. Writing where the user asks is the
// intended behavior of the tool.
return os.WriteFile(path, data, perm)
```

---

# Summary table

| ID | Site | Class | Verdict | Action |
|---|---|---|---|---|
| N1 | `config/config.go:331` | nilerr | Real bug | Fix + 2 tests |
| N2 | `ssh.go:461` | nilerr | Real bug | Fix + 1 test |
| N3 | `ssh.go:511` | nilerr | Real bug | Fix + 1 test |
| N4 | `ssh.go:868` | nilerr | Real bug | Fix + 1 test |
| N5 | `ssh.go:876` | nilerr + dormant | Real bug + latent (corrupt-data) | Reorder + 2 tests |
| N6 | `ssh.go:887` | nilerr | Real bug | Fix + 1 test |
| G1 | `firewall.go:1071/1092/1093` | G109 | **Real bug — silent config footgun** | Validate range + 2 tests |
| G2 | `cert/crypto.go:74` | G407 | False positive | `//nolint:gosec` + property test |
| G3 | `cmd/nebula/notify_linux.go:22` | G704 | False positive (systemd contract) | `//nolint:gosec` + 2 tests |
| G4 | `cmd/nebula-cert/stdio.go:110` | G703 | Justified (CLI tool) | `//nolint:gosec` + 2 tests |

Of 13 high-severity findings (6 nilerr + 7 gosec HIGH), **7 are real bugs**
(all 6 nilerr plus G1 the port-range overflow). The remaining **3 unique
gosec sites** are justified false positives that warrant a `//nolint`
annotation + the property tests above to lock in the behavior.

# Suggested test scaffolding to add first

Several of these tests need helpers (`failingWriter`, `captureStringWriter`,
`unmarshallableCert`, `setupHostWithMalformedJSONCert`, …). The cheapest path
to landing all the fixes is:

1. **First PR** — add `ssh_test.go` test helpers (`failingWriter`,
   `captureStringWriter`) + N2/N3 fixes & tests. These have the simplest
   helpers and the lowest reviewer surface.
2. **Second PR** — N4/N5/N6 (build on the SSH harness) + the gosec G1 port-range fix and tests.
3. **Third PR** — N1 (config) and G2/G3/G4 nolint annotations + lock-in tests.
