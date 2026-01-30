# Adapters

Thin wrappers that make existing Docker images compatible with the interop testing conventions.

## When to Use Adapters

**Adapters** are for implementations that already publish Docker images but don't follow the interop runner's conventions (like the `/certs` mount point for TLS certificates).

An adapter is typically just a Dockerfile that:
1. Inherits from the upstream image (`FROM upstream-image:latest`)
2. Sets environment variables to map our conventions to theirs
3. Optionally adds a wrapper script if CLI translation is needed

For most cases, adapters are simpler than [builds](../builds/README.md) (which compile from source).

## Conventions

The interop runner expects relay images to:

| Convention | Description |
|------------|-------------|
| `/certs/cert.pem` | TLS certificate path |
| `/certs/priv.key` | TLS private key path |
| `MOQT_PORT` | Port to listen on (default: 4443) |
| Exit code 0 | Success |
| Exit code non-zero | Failure |

If an upstream image uses different paths or environment variables, an adapter bridges the gap.

## Directory Structure

```
adapters/
├── README.md           # This file
└── moxygen/
    ├── Dockerfile      # Wraps upstream moxygen image
    └── run_endpoint.sh # Optional CLI translation script
```

## Example: moxygen Adapter

Moxygen's official image expects certificates via environment variables, not the `/certs` mount. The adapter maps our convention to theirs:

```dockerfile
FROM ghcr.io/facebookexperimental/moqrelay:latest-amd64

# Map our /certs convention to moxygen's expected env vars
ENV CERT_FILE=/certs/cert.pem
ENV KEY_FILE=/certs/priv.key
ENV MOQ_PORT=4443

EXPOSE 4443/udp
```

## Adding an Adapter

1. Create a directory under `adapters/` matching the implementation name
2. Create a `Dockerfile` that inherits from the upstream image
3. Map environment variables or add wrapper scripts as needed
4. Register the adapter in `implementations.json`:

```json
"your-impl": {
  "roles": {
    "relay": {
      "docker": {
        "image": "your-impl-interop:latest",
        "build": {
          "dockerfile": "adapters/your-impl/Dockerfile",
          "context": "adapters/your-impl"
        },
        "upstream_image": "original-image:latest"
      }
    }
  }
}
```

## Building Adapters

```bash
# Build moxygen adapter
make build-moxygen-adapter

# Or directly
docker build -t moxygen-interop:latest -f adapters/moxygen/Dockerfile adapters/moxygen/
```

## Adapters vs Builds

| Approach | When to Use |
|----------|-------------|
| **Adapters** | Upstream publishes working Docker images; you just need convention mapping |
| **Builds** | You need to compile from source, test specific commits, or no upstream image exists |

Adapters are simpler and faster since they reuse existing images. Use builds when you need source-level control.
