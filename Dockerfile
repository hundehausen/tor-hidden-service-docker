FROM alpine:3.21

LABEL maintainer="Your Name <your.email@example.com>"
LABEL description="Tor Hidden Service Docker Container"

# Set Tor version - this will be updated by DependencyBot
ENV TOR_VERSION=0.4.8.14-r1

# Install packages
RUN apk add --no-cache \
    tor=${TOR_VERSION} \
    bash \
    su-exec \
    && rm -rf /var/cache/apk/*

# Create directory for hidden services
RUN mkdir -p /var/lib/tor/hidden_service/ \
    && chown -R tor:tor /var/lib/tor/ \
    && chmod -R 700 /var/lib/tor/

# Copy configuration files and scripts
COPY torrc /etc/tor/torrc
COPY entrypoint.sh /entrypoint.sh

# Make the entrypoint script executable
RUN chmod +x /entrypoint.sh

# Expose the Tor SOCKS port
EXPOSE 9050

# Set the entrypoint
ENTRYPOINT ["/entrypoint.sh"]

# Default command
CMD ["tor", "-f", "/etc/tor/torrc"]
