#!/bin/bash
# run_endpoint.sh - Wrapper script for moxygen relay
# Translates standard MoQT interop conventions to moxygen CLI
#
# NOTE: This script is currently NOT USED by the Dockerfile.
# The moxygen adapter instead uses environment variable overrides (CERT_FILE, KEY_FILE)
# which the upstream image's entrypoint reads directly. This script is retained for
# reference or if we need CLI-based configuration in the future.
#
# Expected environment:
#   MOQT_ROLE=relay (only relay supported for moxygen currently)
#
# Expected mounts:
#   /certs/cert.pem - TLS certificate
#   /certs/priv.key - TLS private key
#
# Exit codes:
#   0   - Success
#   1   - Configuration error
#   127 - Unsupported role

set -euo pipefail

ROLE="${MOQT_ROLE:-relay}"
PORT="${MOQT_PORT:-4443}"
CERT="${MOQT_CERT:-/certs/cert.pem}"
KEY="${MOQT_KEY:-/certs/priv.key}"

case "$ROLE" in
  relay)
    echo "Starting moxygen relay on port $PORT"
    echo "  Cert: $CERT"
    echo "  Key:  $KEY"

    # Verify certs exist
    if [ ! -f "$CERT" ]; then
      echo "ERROR: Certificate not found at $CERT" >&2
      echo "Make sure /certs is mounted with cert.pem and priv.key" >&2
      exit 1
    fi
    if [ ! -f "$KEY" ]; then
      echo "ERROR: Private key not found at $KEY" >&2
      exit 1
    fi

    # moxygen relay expects -cert and -key flags
    # Based on moxygen CLI: https://github.com/facebookexperimental/moxygen
    exec /usr/local/bin/moqrelayserver \
      -port "$PORT" \
      -cert "$CERT" \
      -key "$KEY"
    ;;

  *)
    echo "Role '$ROLE' not supported by moxygen adapter" >&2
    echo "Supported roles: relay" >&2
    exit 127
    ;;
esac
