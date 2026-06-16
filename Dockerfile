FROM --platform=$BUILDPLATFORM alpine:3.24

LABEL maintainer="hundehausen"
LABEL description="Tor Hidden Service Docker Image"

# Set Tor version - this will be updated by DependencyBot
ENV TOR_VERSION=0.4.9.9-r0

# Install packages & Create directory
RUN apk add --no-cache \
    tor=${TOR_VERSION} \
    curl \
    ca-certificates \
    su-exec \
    && chown -R tor:tor /var/lib/tor/ \
    && chmod -R 700 /var/lib/tor/ \
    && rm -rf /var/cache/apk/*

# Copy configuration files and scripts
COPY torrc /etc/tor/torrc
COPY entrypoint.sh /entrypoint.sh

# Make the entrypoint script executable
RUN chmod +x /entrypoint.sh

HEALTHCHECK --interval=300s --timeout=3s \
CMD curl -sS --socks5-hostname localhost:9050 https://check.torproject.org/ | grep -q Congratulations

# Expose the Tor SOCKS port
EXPOSE 9050

# Set the entrypoint
ENTRYPOINT ["/entrypoint.sh"]

# Default command
CMD ["tor", "-f", "/etc/tor/torrc"]
