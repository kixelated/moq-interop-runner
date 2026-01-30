# Builds Framework

Build Docker images from source code for MoQ implementations.

## When to Use Builds

**Builds** compile implementations from source, providing:
- Reproducibility via pinned commits
- Ability to test unreleased code or specific branches
- Local development workflows

For most cases, **adapters** (wrapping existing Docker images) or **remote endpoints** (testing against public relays) are simpler. Use builds when you need source-level control.

Builds are opt-in and require explicit invocation - they don't run automatically during tests.

## Directory Structure

```
builds/
├── README.md           # This file
└── moq-rs/
    ├── config.json     # Source repo, refs, targets
    ├── build.sh        # Entry point script
    ├── Dockerfile.*    # Docker build files
    └── .sources/       # gitignored - cloned repos
```

## Usage

### Direct Invocation

```bash
# Build from default ref
./builds/moq-rs/build.sh

# Build from specific branch/tag
./builds/moq-rs/build.sh --ref feature-branch

# Use local checkout (for development)
./builds/moq-rs/build.sh --local ~/git/moq-rs

# Build specific target only
./builds/moq-rs/build.sh --target client
```

### Makefile Integration

```bash
# Build implementation using defaults
make build-impl IMPL=moq-rs

# Build with custom arguments
make build-moq-rs BUILD_ARGS="--local ~/git/moq-rs"
```

## Security Considerations

Builds execute arbitrary code from external repositories. Important safeguards:

- **Never run automatically** - Test targets do not trigger builds
- **Explicit opt-in required** - Users must invoke build commands directly
- **Review before running** - Inspect build definitions for unfamiliar implementations

## Adding a Build for Your Implementation

1. Create a directory under `builds/` matching your implementation name
2. Create `config.json` with:
   - Repository URL
   - Default ref (branch/tag)
   - Build targets (client, server, etc.)
3. Create `build.sh` entry point script
4. Create `Dockerfile.*` for each target

### Example config.json

```json
{
  "name": "moq-impl",
  "description": "Description of your implementation",
  "repository": "https://github.com/example/moq-impl.git",
  "default_ref": "main",
  "targets": {
    "relay": {
      "dockerfile": "Dockerfile.relay",
      "image_name": "moq-relay",
      "context": ".sources/moq-impl"
    },
    "client": {
      "dockerfile": "Dockerfile.client",
      "image_name": "moq-test-client",
      "context": ".sources/moq-impl"
    }
  }
}
```

## Provenance Tracking

Each build captures metadata for reproducibility:

| Field | Description |
|-------|-------------|
| `commit` | Full commit hash |
| `dirty` | Whether working tree had uncommitted changes |
| `timestamp` | Build time (ISO 8601) |
| `ref` | Branch/tag used |

This information is:
- Printed to stdout during build
- Saved to `.last-build.json` in the build directory

Use provenance data to reproduce test results or debug regressions against specific code versions.
