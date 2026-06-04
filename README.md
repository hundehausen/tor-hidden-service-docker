# Tor Hidden Service Docker

[![Docker Build](https://img.shields.io/github/actions/workflow/status/hundehausen/tor-hidden-service-docker/build.yml?branch=main&style=flat-square)](https://github.com/hundehausen/tor-hidden-service-docker/actions)
[![Tor Version](https://img.shields.io/badge/Tor-0.4.9.9--r0-purple?style=flat-square)](https://gitweb.torproject.org/tor.git)
[![Alpine Version](https://img.shields.io/badge/Alpine-3.23-blue?style=flat-square)](https://alpinelinux.org/)

A lightweight, secure Docker container for running Tor hidden services. Built on Alpine Linux with a focus on minimal footprint and maximum security.

## Table of Contents

- [🚀 Quick Start](#-quick-start)
- [✨ Features](#-features)
- [⚙️ How It Works](#️-how-it-works)
- [📦 Usage](#-usage)
- [🔧 Configuration](#-configuration)
- [🛡️ Security](#️-security)
- [🔑 Key Persistence](#-key-persistence)
- [📚 Examples](#-examples)
- [💓 Health Checks](#-health-checks)
- [🔍 Troubleshooting](#-troubleshooting)
- [🤝 Contributing](#-contributing)

## 🚀 Quick Start

```bash
# Run with a simple web service
docker run -d --name my-tor-service \
  -e HS_WEB=web:80:80 \
  ghcr.io/hundehausen/tor-hidden-service:latest

# View your .onion address
docker logs my-tor-service
```

Or use Docker Compose:

```bash
git clone https://github.com/hundehausen/tor-hidden-service-docker.git
cd tor-hidden-service-docker
docker compose up -d
docker compose logs -f tor
```

## ✨ Features

- 🪶 **Minimal footprint** - Alpine Linux base (~44MB)
- 🎛️ **Easy hidden services** - Configure via environment variables
- 🔒 **Security-first** - Runs as non-root user with minimal privileges
- 🛡️ **Input validation** - Defense-in-depth against path traversal and injection
- 🔎 **Auto-discovery** - Onion addresses displayed in logs
- 🔑 **Key persistence** - Reuse existing keys across restarts
- 💓 **Health checks** - Built-in container health monitoring
- 🛑 **Graceful shutdown** - Proper SIGTERM/SIGINT handling with 30s timeout
- 🏗️ **Multi-arch** - Supports linux/amd64 and linux/arm64

## ⚙️ How It Works

1. The container runs a Tor daemon that registers your services on the Tor network
2. Each `HS_*` environment variable creates a hidden service with its own `.onion` address
3. Incoming connections to a `.onion` address are forwarded to the specified target container and port
4. A SOCKS proxy on port 9050 is available for outbound Tor connections

## 📦 Usage

### Basic Usage

```bash
docker run -d --name tor-hidden-service \
  -e HS_WEB=web-container:80:80 \
  ghcr.io/hundehausen/tor-hidden-service:latest
```

### Docker Compose

```yaml
services:
  web:
    image: nginx:alpine
    container_name: web-container
    volumes:
      - ./example-site:/usr/share/nginx/html
    networks:
      - tor-network

  tor:
    image: ghcr.io/hundehausen/tor-hidden-service:latest
    container_name: tor-hidden-service
    environment:
      - HS_WEB=web:80:80
      - SOCKS_BIND=127.0.0.1
    volumes:
      - tor-data:/var/lib/tor
    networks:
      - tor-network
    deploy:
      resources:
        limits:
          memory: 256M
          cpus: '0.5'

networks:
  tor-network:
    driver: bridge

volumes:
  tor-data:
```

### Retrieving Onion Addresses

From container logs:

```bash
docker logs tor-hidden-service
```

Output:
```
======== TOR HIDDEN SERVICES ========
WEB: 2xxiyj6noereyty4xdxjg5akcop7ylnotvf4fqre57g7xuppy4tixvqd.onion
API: 7gtpkyhhhsbowew7zha6z7h7vlffqkn3nbu2f6hgin4xddq22o7yytyd.onion
====================================
```

From the filesystem:

```bash
# Get specific service address
docker exec tor-hidden-service cat /var/lib/tor/WEB/hostname

# List all services
docker exec tor-hidden-service ls /var/lib/tor/
```

## 🔧 Configuration

### Environment Variables

Configure hidden services using the format:

```
HS_[SERVICE_NAME]=[TARGET_HOST]:[TARGET_PORT]:[VIRTUAL_PORT]
```

| Variable | Description | Example |
|----------|-------------|---------|
| `SERVICE_NAME` | Unique identifier (alphanumeric, hyphens, underscores) | `WEB`, `API`, `BLOG` |
| `TARGET_HOST` | Hostname or container name | `web`, `api.internal` |
| `TARGET_PORT` | Port the service listens on | `80`, `8080` |
| `VIRTUAL_PORT` | (Optional) Port exposed on .onion address, defaults to `TARGET_PORT` | `80` |

**Examples:**

```bash
# Single service
HS_WEB=web-container:80:80

# Multiple services (each gets a unique .onion address)
HS_WEB=web:80:80
HS_API=api:8080:80
HS_BLOG=blog:3000:80
```

### SOCKS Proxy

The container exposes a SOCKS5 proxy on port 9050 for routing traffic through Tor.

By default, the proxy binds to `0.0.0.0` (all interfaces). **For production, restrict this to localhost:**

```yaml
environment:
  - SOCKS_BIND=127.0.0.1
```

> **Note:** The default will change to `127.0.0.1` in a future major version.

### Command-Line Arguments

You can also pass services as arguments:

```bash
docker run -d \
  ghcr.io/hundehausen/tor-hidden-service:latest \
  web:web-container:80:80 \
  api:api-container:8080:80
```

### Custom torrc directives

Two env vars accept multi-line torrc content, appended to `/etc/tor/torrc` at boot:

| Variable | Where it lands | Use for |
|----------|----------------|---------|
| `TORRC` | After `SocksPort`, before any hidden service section | Global directives |
| `HSTORRC_<SERVICE>` | After that service's `HiddenServicePort` line | Per-service directives (PoW, IntroDoS, MaxStreams, …) |

Hyphens in service names become underscores (`HS_MY-API` → `HSTORRC_MY_API`).
Tor validates directives at startup; bad config fails fast in the logs.

```yaml
services:
  tor:
    image: ghcr.io/hundehausen/tor-hidden-service:latest
    environment:
      SOCKS_BIND: 127.0.0.1
      HS_WEB: web:80:80
      HS_API: api:8080:80

      TORRC: |
        ClientUseIPv6 1

      HSTORRC_WEB: |
        HiddenServicePoWDefensesEnabled 1
        HiddenServicePoWQueueRate 250
        HiddenServicePoWQueueBurst 1000
        HiddenServiceEnableIntroDoSDefense 1
        HiddenServiceEnableIntroDoSRatePerSec 25
        HiddenServiceEnableIntroDoSBurstPerSec 200

      HSTORRC_API: |
        HiddenServiceMaxStreams 50
        HiddenServiceMaxStreamsCloseCircuit 1
```

Inspect the rendered config:

```bash
docker exec tor-hidden-service cat /etc/tor/torrc
```

## 🛡️ Security

### Hardening Checklist

- 📊 **Set resource limits** - Prevent resource exhaustion (see [Usage](#-usage))
- 🔐 **Restrict SOCKS proxy** - Set `SOCKS_BIND=127.0.0.1` in production
- 💾 **Persist keys securely** - Mount `/var/lib/tor` as a volume, never commit keys to git

### Protecting Your Keys

The `hs_ed25519_secret_key` files in `/var/lib/tor/[service]/` are the cryptographic identity of your `.onion` address. If compromised, an attacker can impersonate your service.

⚠️ **Never commit private keys to version control.**

### Input Validation

The entrypoint script validates all inputs:
- **Service names** - Alphanumeric, hyphens, and underscores only (max 64 chars)
- **Ports** - Numeric, range 1-65535
- **Hostnames** - No shell metacharacters allowed
- **Path traversal** - Prevented via allowlist and path verification

## 🔑 Key Persistence

### Option 1: Full Directory Persistence

```yaml
volumes:
  - tor-data:/var/lib/tor
```

### Option 2: Selective Key Reuse

```yaml
volumes:
  - tor-data:/var/lib/tor
  - ./backup-keys/WEB:/var/lib/tor/WEB  # Restore specific service
  - ./backup-keys/API:/var/lib/tor/API
```

### Backing Up Keys

```bash
# Copy keys from running container
docker cp tor-hidden-service:/var/lib/tor/WEB ./backup-keys/

# Or archive the entire volume
docker run --rm -v tor-data:/data -v $(pwd):/backup alpine \
  tar czf /backup/tor-keys.tar.gz -C /data .
```

## 📚 Examples

### Static Website

```yaml
services:
  nginx:
    image: nginx:alpine
    volumes:
      - ./website:/usr/share/nginx/html:ro
    networks:
      - tor

  tor:
    image: ghcr.io/hundehausen/tor-hidden-service:latest
    environment:
      - HS_SITE=nginx:80:80
      - SOCKS_BIND=127.0.0.1
    volumes:
      - tor-keys:/var/lib/tor
    networks:
      - tor

networks:
  tor:
volumes:
  tor-keys:
```

### Multiple Services

```yaml
services:
  web:
    image: nginx:alpine
    networks:
      - tor

  api:
    image: node:18-alpine
    networks:
      - tor

  tor:
    image: ghcr.io/hundehausen/tor-hidden-service:latest
    environment:
      - HS_WEBSITE=web:80:80
      - HS_API=api:3000:80
      - HS_ADMIN=api:8080:80
      - SOCKS_BIND=127.0.0.1
    volumes:
      - tor-data:/var/lib/tor
    networks:
      - tor

networks:
  tor:
volumes:
  tor-data:
```

## 💓 Health Checks

The container includes a health check that verifies Tor network connectivity:

- **Interval:** 300 seconds (5 minutes)
- **Timeout:** 3 seconds
- **Test:** Connects to `check.torproject.org` via SOCKS proxy

Check health status:

```bash
docker ps --filter name=tor-hidden-service --format "table {{.Names}}\t{{.Status}}"
```

## 🔍 Troubleshooting

### Can't connect to hidden service

1. Verify Tor bootstrap: `docker logs tor-hidden-service | grep "Bootstrapped 100%"`
2. Check service configuration: `docker exec tor-hidden-service cat /etc/tor/torrc`
3. Ensure target container is reachable: `docker exec tor-hidden-service ping web`

### Onion address keeps changing

Keys are not being persisted. Add a volume for `/var/lib/tor`:

```yaml
volumes:
  - tor-data:/var/lib/tor
```

### High memory usage

Set resource limits in your compose file:

```yaml
deploy:
  resources:
    limits:
      memory: 256M
```

## 🤝 Contributing

Contributions are welcome! Please open an issue or submit a pull request on [GitHub](https://github.com/hundehausen/tor-hidden-service-docker).

---

**Disclaimer:** This tool is for legitimate privacy purposes only. Users are responsible for complying with all applicable laws and regulations in their jurisdiction.
