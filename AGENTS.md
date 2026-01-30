# MoQ Interop Runner - Agent Guidelines

Guidelines for AI assistants helping with this repository.

## Repository Purpose

This is a framework for testing interoperability between MoQT (Media over QUIC Transport) implementations. It orchestrates tests between different MoQT relays and clients.

## Key Files

| File | Purpose |
|------|---------|
| `implementations.json` | Registry of all MoQT implementations with their endpoints and Docker images |
| `implementations.schema.json` | JSON Schema for validating implementations.json |
| `run-interop-tests.sh` | Main test orchestration script |
| `docker-compose.test.yml` | Docker Compose configuration for local testing |
| `docs/TEST-SPECIFICATIONS.md` | Defines the test cases implementations should support |

## Adding a New Implementation

To add an implementation to the registry:

1. **Edit `implementations.json`** - Add an entry under `implementations` with:
   - `name`: Display name
   - `organization`: Who maintains it
   - `repository`: Git repository URL
   - `draft_versions`: Array of supported MoQT draft versions (e.g., `["draft-14"]`)
   - `roles`: Object with `relay` and/or `client` capabilities

2. **For remote endpoints** (public relays), add under `roles.relay.remote`:
   ```json
   {
     "url": "https://example.com:443/moq",
     "transport": "webtransport",
     "notes": "Optional description"
   }
   ```
   
3. **For Docker images**, add under `roles.relay.docker`:
   ```json
   {
     "image": "impl-name:latest",
     "notes": "Build instructions or registry location"
   }
   ```

4. **Validate** the JSON against the schema before committing.

## Docker Image Conventions

Relay images should follow these conventions:

- **TLS certificates**: Mount at `/certs/cert.pem` and `/certs/priv.key`
- **Environment variables**: 
  - `MOQT_ROLE` - Role to run (`relay`, `client`)
  - `MOQT_PORT` - Port to listen on
  - `MOQT_CERT`, `MOQT_KEY` - Paths to TLS cert/key if not using defaults
- **Exit codes**: 0 for success, 127 for unsupported role/test

If an implementation's image doesn't follow these conventions, create an adapter in `adapters/<impl-name>/`.

## Test Specifications

Test cases are defined in `docs/TEST-SPECIFICATIONS.md`. Each test has:
- A unique identifier (e.g., `setup-only`, `announce-subscribe`)
- Prerequisites
- Steps to execute
- Expected outcomes

When adding tests, follow the existing format and assign to an appropriate tier.

## Common Tasks

### Verify an implementation entry
```bash
# Check JSON syntax
python3 -m json.tool implementations.json > /dev/null

# Run tests against a specific relay
make interop-relay RELAY=<impl-name>
```

### Test locally with Docker
```bash
make build-moq-rs BUILD_ARGS="--local /path/to/moq-rs"
make test
```

## Style Guidelines

- Keep `implementations.json` entries alphabetically sorted by key
- Use lowercase for implementation keys (e.g., `moq-rs` not `MoQ-RS`)
- URLs should include explicit ports unless using standard 443
- Draft versions use format `draft-NN` (e.g., `draft-14`)
