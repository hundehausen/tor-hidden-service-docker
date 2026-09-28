# Pinned by digest for reproducible builds. Dependabot bumps the digest.
# To refresh manually:
#   docker buildx imagetools inspect alpine:3.24 --format '{{.Manifest.Digest}}'
FROM alpine:3.24@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6

LABEL maintainer="hundehausen"
LABEL description="Tor Hidden Service Docker Image"

# Packages are pinned so rebuilds resolve the same bytes. Alpine keeps only the
# newest revision per branch, so when a pinned package disappears from v3.24,
# bump it here and rebuild: https://pkgs.alpinelinux.org/packages?branch=v3.24
ENV TOR_VERSION=0.4.9.13-r0
ENV CURL_VERSION=8.22.0-r0
ENV CA_CERTIFICATES_VERSION=20260909-r0

# Install packages & Create directory
RUN apk add --no-cache \
    tor=${TOR_VERSION} \
    curl=${CURL_VERSION} \
    ca-certificates=${CA_CERTIFICATES_VERSION} \
    && chown -R tor:tor /var/lib/tor/ \
    && chmod -R 700 /var/lib/tor/ \
    && rm -rf /var/cache/apk/*

# Copy configuration files and scripts
COPY torrc /etc/tor/torrc
COPY --chown=tor:tor entrypoint.sh /entrypoint.sh

# Make the entrypoint script executable
RUN chmod +x /entrypoint.sh

HEALTHCHECK --interval=300s --timeout=3s \
CMD curl -sS --socks5-hostname localhost:9050 https://check.torproject.org/ | grep -q Congratulations

# Expose the Tor SOCKS port
EXPOSE 9050

# Run as the unprivileged tor user (uid 100, gid 101)
USER tor

# Set the entrypoint
ENTRYPOINT ["/entrypoint.sh"]

# Default command
CMD ["tor"]
