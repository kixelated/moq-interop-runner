# Moxygen adapter for MoQT interop testing
#
# Wraps the official moxygen relay image with standard interop conventions:
# - Reads certs from /certs/cert.pem and /certs/priv.key
# - Maps our /certs mount to moxygen's expected env vars
#
# The upstream moxygen image uses environment variables CERT_FILE and KEY_FILE
# to configure certificate paths. We override these to match our naming convention
# (cert.pem/priv.key) instead of the upstream defaults (certificate.pem/certificate.key).
#
# Build:
#   docker build -t moxygen-interop:latest -f adapters/moxygen/Dockerfile adapters/moxygen/
#
# Usage:
#   docker run -v ./certs:/certs -p 4443:4443/udp moxygen-interop:latest

FROM ghcr.io/facebookexperimental/moqrelay:latest-amd64

# Map our /certs convention to moxygen's expected env vars
# Upstream default port is 4433, we use 4443 for consistency with other implementations
ENV MOQ_PORT=4443
# Override cert paths to match our naming convention (cert.pem, priv.key)
ENV CERT_FILE=/certs/cert.pem
ENV KEY_FILE=/certs/priv.key
ENV MOQ_ENDPOINT=/
ENV MOQ_LOG_LEVEL=DBG2

EXPOSE 4443/udp

# The upstream image's CMD uses these environment variables to start moqrelayserver
# No custom entrypoint needed - the env var overrides are sufficient
