FROM alpine:3.24

LABEL maintainer="hundehausen"
LABEL description="Tor Hidden Service Docker Image"

# Set Tor version - this will be updated by DependencyBot
ENV TOR_VERSION=0.4.9.12-r0

# Install packages & Create directory
RUN apk add --no-cache \
    tor=${TOR_VERSION} \
    curl \
    ca-certificates \
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
