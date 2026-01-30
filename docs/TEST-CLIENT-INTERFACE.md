# MoQT Test Client Interface Specification

This document defines the interface that MoQT test clients MUST implement to be compatible with the moq-interop-runner framework.

## Command Line Interface

Test clients SHOULD support the following command-line interface:

```bash
moq-test-client [OPTIONS]

Options:
  -r, --relay <URL>           Relay URL (default: https://localhost:4443)
  -t, --test <NAME>           Run specific test (omit to run all)
  -l, --list                  List available tests
  -v, --verbose               Verbose output
      --tls-disable-verify    Disable TLS certificate verification
```

### URL Schemes

- `https://` - WebTransport over HTTP/3
- `moqt://` - Raw QUIC with ALPN `moq-00`

## Environment Variable Interface

For containerized testing, the following environment variables are supported:

| Variable | Required | Description |
|----------|----------|-------------|
| `RELAY_URL` | Yes | Relay URL (`https://` for WebTransport, `moqt://` for raw QUIC) |
| `TESTCASE` | No | Specific test to run (runs all if not set) |
| `TLS_DISABLE_VERIFY` | No | Set to `1` to skip certificate verification |
| `VERBOSE` | No | Set to `1` for verbose output |

Environment variables take precedence over command-line defaults but not over explicit command-line arguments.

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | All requested tests passed |
| 1 | One or more tests failed |
| 127 | Test or role not supported by this client |

## Output Format

### Human-Readable Output

Each test result SHOULD be printed on a single line:

```
✓ setup-only (24 ms)
✓ announce-only (31 ms)
✗ subscribe-error (timeout after 2000 ms)
```

Include a summary at the end:

```
Results: 2 passed, 1 failed
```

### Machine-Parseable Output

The final line of output MUST include a machine-parseable result:

- `MOQT_TEST_RESULT: SUCCESS` - all tests passed
- `MOQT_TEST_RESULT: FAILURE` - one or more tests failed

This allows the test runner to determine results without parsing human-readable output.

### Connection ID Reporting

Each test result SHOULD include the QUIC connection ID(s) for mlog correlation:

```
✓ setup-only (24 ms) [CID: 84ee7793841adcadd926a1baf1c677cc]
```

For multi-connection tests (e.g., publisher + subscriber):

```
✓ announce-subscribe (156 ms) [CID: pub=abc123..., sub=def456...]
```

### List Output

When `--list` is specified, output one test identifier per line:

```
setup-only
announce-only
publish-namespace-done
subscribe-error
announce-subscribe
subscribe-before-announce
```

This enables the runner to discover which tests a client supports.

## Timeout Handling

Test clients MUST implement timeouts to prevent hanging:

- Individual tests SHOULD timeout after their specified duration (see test case specs)
- If no timeout is specified, default to 5 seconds
- On timeout, report the test as failed with a clear message

## Error Reporting

When tests fail, include enough context to diagnose the issue:

```
✗ announce-only (2001 ms)
  Expected: PUBLISH_NAMESPACE_OK
  Received: timeout (no response after 2000 ms)
  Connection ID: 84ee7793841adcadd926a1baf1c677cc
```

For protocol errors:

```
✗ subscribe-error (45 ms)
  Expected: SUBSCRIBE_ERROR
  Received: SUBSCRIBE_OK (unexpected success)
  Connection ID: 84ee7793841adcadd926a1baf1c677cc
```

---

## Output Format: Under Discussion

> **Note**: The output format defined above is provisional. Before implementing a test client, please check with the moq-interop-runner maintainers or the MoQ working group about the current status of this specification.
>
> We're evaluating alternatives including:
> - [TAP (Test Anything Protocol)](https://testanything.org/) - established test output standard
> - JSON Lines - fully structured, machine-parseable output
> - mlog-based validation - using qlog/mlog events for test verification
>
> Feedback welcome via GitHub issues or the MoQ mailing list.
