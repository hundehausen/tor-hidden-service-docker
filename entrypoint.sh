#!/bin/sh
set -e

# Signal handling for graceful shutdown
TOR_PID=""

shutdown_tor() {
    echo "Received shutdown signal, stopping Tor gracefully..."
    if [ -n "$TOR_PID" ] && kill -0 "$TOR_PID" 2>/dev/null; then
        # Send SIGTERM to Tor to initiate graceful shutdown
        kill -TERM "$TOR_PID" 2>/dev/null
        # Wait for Tor to exit (with timeout)
        local count=0
        while kill -0 "$TOR_PID" 2>/dev/null && [ $count -lt 30 ]; do
            sleep 1
            count=$((count + 1))
        done
        # If still running, force kill
        if kill -0 "$TOR_PID" 2>/dev/null; then
            echo "Tor did not exit gracefully, forcing shutdown..."
            kill -KILL "$TOR_PID" 2>/dev/null
        fi
    fi
    exit 0
}

# Trap SIGTERM and SIGINT for graceful shutdown
trap 'shutdown_tor' TERM INT

# Ensure Tor data directory exists with correct permissions
# This must be done before creating any hidden service subdirectories
if [ ! -d /var/lib/tor ]; then
    mkdir -p /var/lib/tor
fi
chown tor:tor /var/lib/tor
chmod 700 /var/lib/tor

# Start with a clean torrc configuration
# Keep the basic configuration and remove any hidden service entries
grep -v "HiddenService" /etc/tor/torrc > /tmp/torrc.new
cat /tmp/torrc.new > /etc/tor/torrc
rm /tmp/torrc.new

# Configure SOCKS proxy bind address
# SECURITY DEPRECATION: Defaulting to 0.0.0.0 for backward compatibility.
# This exposes the SOCKS proxy to all interfaces which is a security risk.
# In a future major version, the default will change to 127.0.0.1.
# To secure your deployment now, explicitly set SOCKS_BIND=127.0.0.1
SOCKS_BIND_EXPLICIT=${SOCKS_BIND}
SOCKS_BIND=${SOCKS_BIND:-0.0.0.0}

# Remove any existing SocksPort configuration and add the new one
grep -v "^SocksPort" /etc/tor/torrc > /tmp/torrc.new
cat /tmp/torrc.new > /etc/tor/torrc
rm /tmp/torrc.new

# Add the SOCKS port configuration
echo "SocksPort ${SOCKS_BIND}:9050" >> /etc/tor/torrc

# Log the configuration with security warning if using default
if [ -z "$SOCKS_BIND_EXPLICIT" ] && [ "$SOCKS_BIND" = "0.0.0.0" ]; then
    echo "WARNING: SOCKS proxy is exposed on all interfaces (0.0.0.0:9050)"
    echo "WARNING: This is a security risk. Other containers/networks can use your Tor proxy."
    echo "WARNING: Set SOCKS_BIND=127.0.0.1 to restrict to localhost only."
    echo "WARNING: In a future version, 127.0.0.1 will be the default."
else
    echo "SOCKS proxy configured to bind to: ${SOCKS_BIND}:9050"
fi

# Append a torrc block under a section comment. Strips NUL/CR.
append_torrc_block() {
    block_label=$1
    block_content=$2

    [ -z "$block_content" ] && return 0

    printf '\n# %s\n' "$block_label" >> /etc/tor/torrc
    printf '%s\n' "$block_content" | tr -d '\000\r' >> /etc/tor/torrc

    echo "==> Appended ${block_label}:"
    printf '%s\n' "$block_content" | tr -d '\000\r' | sed 's/^/    /'
}

append_torrc_block "Custom global torrc (TORRC env var)" "${TORRC:-}"

# Security validation functions
validate_service_name() {
    local name=$1
    # Allow only alphanumeric, hyphens, and underscores
    # Prevent path traversal (../), directory traversal, and special characters
    # Use grep for validation to avoid shell escaping issues
    if echo "$name" | grep -qE '[/\\]|\.\.|\*|\?|<|>|\||&|;|\$|\`'; then
        echo "ERROR: Invalid service name: '$name'" >&2
        echo "ERROR: Service names must not contain path separators, '..' or special characters" >&2
        return 1
    fi
    
    # Check length (max 64 chars for directory name)
    if [ ${#name} -gt 64 ] || [ ${#name} -eq 0 ]; then
        echo "ERROR: Service name must be between 1 and 64 characters: '$name'" >&2
        return 1
    fi
    
    # Must start with alphanumeric
    case "$name" in
        [a-zA-Z0-9]*) ;;
        *)
            echo "ERROR: Service name must start with alphanumeric character: '$name'" >&2
            return 1
            ;;
    esac
    
    return 0
}

validate_port() {
    local port=$1
    local name=$2
    
    # Check if port is a number
    case "$port" in
        ''|*[!0-9]*)
            echo "ERROR: Invalid port for service '$name': '$port' (must be a number)" >&2
            return 1
            ;;
    esac
    
    # Check port range (1-65535)
    if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo "ERROR: Port out of range for service '$name': $port (must be 1-65535)" >&2
        return 1
    fi
    
    return 0
}

validate_hostname() {
    local host=$1
    local name=$2
    
    # Reject empty hostnames
    if [ -z "$host" ]; then
        echo "ERROR: Empty hostname for service '$name'" >&2
        return 1
    fi
    
    # Check for obviously malicious patterns using grep
    if echo "$host" | grep -qE '[;|&<>$`\\]'; then
        echo "ERROR: Invalid hostname for service '$name': '$host' contains special characters" >&2
        return 1
    fi
    
    return 0
}

# Function to create a hidden service configuration
create_hidden_service() {
    local service_name=$1
    local target_host=$2
    local target_port=$3
    local virtual_port=$4

    # Defense in depth: validate service name again before using in path
    if ! validate_service_name "$service_name"; then
        echo "ERROR: Aborting creation of hidden service due to invalid name" >&2
        return 1
    fi

    # If virtual port is not specified, use the target port
    if [ -z "$virtual_port" ]; then
        virtual_port=$target_port
    fi

    # Create directory for the hidden service if it doesn't exist
    # Use printf to safely construct the path
    local service_dir
    service_dir=$(printf '/var/lib/tor/%s' "$service_name")
    
    # Security check: ensure the resolved path is still under /var/lib/tor
    # This prevents path traversal even if validation was bypassed
    case "$service_dir" in
        /var/lib/tor/*) ;;
        *)
            echo "ERROR: Security violation - service directory escapes /var/lib/tor: $service_dir" >&2
            return 1
            ;;
    esac
    
    if [ ! -d "$service_dir" ]; then
        mkdir -p "$service_dir" || {
            echo "ERROR: Failed to create directory: $service_dir" >&2
            return 1
        }
    fi
    
    # Check if this is a pre-existing service with keys
    if [ -f "${service_dir}/private_key" ] || [ -f "${service_dir}/hs_ed25519_secret_key" ]; then
        echo "Found existing keys for hidden service: $service_name"
    fi
    
    # Ensure proper permissions
    chown -R tor:tor "$service_dir" || {
        echo "ERROR: Failed to set ownership on: $service_dir" >&2
        return 1
    }
    chmod -R 700 "$service_dir" || {
        echo "ERROR: Failed to set permissions on: $service_dir" >&2
        return 1
    }

    # Add hidden service configuration to torrc
    printf '\n# Hidden service: %s\n' "$service_name" >> /etc/tor/torrc
    printf 'HiddenServiceDir %s\n' "$service_dir" >> /etc/tor/torrc
    printf 'HiddenServicePort %s %s:%s\n' "$virtual_port" "$target_host" "$target_port" >> /etc/tor/torrc

    # Hyphens in service names become underscores; env names can't have hyphens.
    hs_torrc_var="HSTORRC_$(printf '%s' "$service_name" | tr '-' '_')"
    eval "hs_torrc_value=\${${hs_torrc_var}-}"
    append_torrc_block "Per-service torrc (${hs_torrc_var})" "$hs_torrc_value"

    echo "Configured hidden service for $service_name: $target_host:$target_port -> $virtual_port"
}

# Process environment variables for hidden services
# Format: HS_[SERVICE_NAME]=[TARGET_HOST]:[TARGET_PORT]:[VIRTUAL_PORT]
# Example: HS_WEB=web:80:80
env | grep '^HS_' | while IFS= read -r var; do
    # Skip if variable is empty or malformed
    [ -z "$var" ] && continue
    
    # Extract service name (everything between HS_ and first =)
    service_name=$(printf '%s' "$var" | cut -d= -f1 | sed 's/^HS_//')
    value=$(printf '%s' "$var" | cut -d= -f2-)
    
    # Validate service name (prevents path traversal)
    validate_service_name "$service_name" || continue
    
    # Parse the value - must have at least HOST:PORT
    target_host=$(printf '%s' "$value" | cut -d: -f1)
    target_port=$(printf '%s' "$value" | cut -d: -f2)
    virtual_port=$(printf '%s' "$value" | cut -d: -f3)
    
    # Validate hostname
    validate_hostname "$target_host" "$service_name" || continue
    
    # Validate target port
    validate_port "$target_port" "$service_name" || continue
    
    # Validate virtual port (if provided, otherwise will default to target_port)
    if [ -n "$virtual_port" ]; then
        validate_port "$virtual_port" "$service_name" || continue
    fi
    
    create_hidden_service "$service_name" "$target_host" "$target_port" "$virtual_port"
done

# Process command line arguments
# Format: [SERVICE_NAME]:[TARGET_HOST]:[TARGET_PORT]:[VIRTUAL_PORT]
for arg in "$@"; do
    case "$arg" in
        *:*:*)
            service_name=$(printf '%s' "$arg" | cut -d: -f1)
            target_host=$(printf '%s' "$arg" | cut -d: -f2)
            target_port=$(printf '%s' "$arg" | cut -d: -f3)
            virtual_port=$(printf '%s' "$arg" | cut -d: -f4)

            # Validate all inputs
            validate_service_name "$service_name" || continue
            validate_hostname "$target_host" "$service_name" || continue
            validate_port "$target_port" "$service_name" || continue
            if [ -n "$virtual_port" ]; then
                validate_port "$virtual_port" "$service_name" || continue
            fi

            create_hidden_service "$service_name" "$target_host" "$target_port" "$virtual_port"
            ;;
    esac
done

# Make sure the Tor data directory has correct permissions
chown -R tor:tor /var/lib/tor
chmod -R 700 /var/lib/tor

# Print all onion addresses after a short delay to allow Tor to generate them
print_onion_addresses() {
    sleep 10
    echo "======== TOR HIDDEN SERVICES ========"
    for dir in /var/lib/tor/*/; do
        if [ -f "${dir}hostname" ]; then
            service_name=$(basename "$dir")
            onion_address=$(cat "${dir}hostname")
            echo "$service_name: $onion_address"
        fi
    done
    echo "===================================="
}

# Start printing onion addresses in the background
print_onion_addresses &

# Start Tor with signal handling support
start_tor() {
    echo "Starting Tor..."
    su-exec tor "$@" &
    TOR_PID=$!
    
    # Wait for Tor process to complete
    wait $TOR_PID
    local exit_code=$?
    
    # Clear TOR_PID since process has exited
    TOR_PID=""
    
    return $exit_code
}

# If no arguments were provided, run Tor with the default config as the tor user
if [ $# -eq 0 ]; then
    start_tor tor -f /etc/tor/torrc
    exit $?
fi

# If the first argument is "tor", run it as the tor user
if [ "$1" = "tor" ]; then
    shift
    start_tor tor "$@"
    exit $?
fi

# Otherwise, run the command as-is (signals won't be handled gracefully for custom commands)
exec "$@"
