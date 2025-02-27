#!/bin/bash
set -e

# Function to create a hidden service configuration
create_hidden_service() {
    local service_name=$1
    local target_host=$2
    local target_port=$3
    local virtual_port=$4

    # If virtual port is not specified, use the target port
    if [ -z "$virtual_port" ]; then
        virtual_port=$target_port
    fi

    # Create directory for the hidden service
    local service_dir="/var/lib/tor/${service_name}"
    mkdir -p "$service_dir"
    chown -R tor:tor "$service_dir"
    chmod -R 700 "$service_dir"

    # Add hidden service configuration to torrc
    echo "HiddenServiceDir $service_dir" >> /etc/tor/torrc
    echo "HiddenServicePort $virtual_port $target_host:$target_port" >> /etc/tor/torrc

    echo "Configured hidden service for $service_name: $target_host:$target_port -> $virtual_port"
}

# Process environment variables for hidden services
# Format: HS_[SERVICE_NAME]=[TARGET_HOST]:[TARGET_PORT]:[VIRTUAL_PORT]
# Example: HS_WEB=web:80:80
for var in $(env | grep ^HS_); do
    service_name=$(echo "$var" | cut -d= -f1 | sed 's/^HS_//')
    value=$(echo "$var" | cut -d= -f2-)
    
    # Parse the value
    target_host=$(echo "$value" | cut -d: -f1)
    target_port=$(echo "$value" | cut -d: -f2)
    virtual_port=$(echo "$value" | cut -d: -f3)
    
    create_hidden_service "$service_name" "$target_host" "$target_port" "$virtual_port"
done

# Process command line arguments
# Format: [SERVICE_NAME]:[TARGET_HOST]:[TARGET_PORT]:[VIRTUAL_PORT]
for arg in "$@"; do
    if [[ "$arg" == *:*:* ]]; then
        service_name=$(echo "$arg" | cut -d: -f1)
        target_host=$(echo "$arg" | cut -d: -f2)
        target_port=$(echo "$arg" | cut -d: -f3)
        virtual_port=$(echo "$arg" | cut -d: -f4)
        
        create_hidden_service "$service_name" "$target_host" "$target_port" "$virtual_port"
    fi
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

# If the first argument is "tor", run it as the tor user
if [ "$1" = "tor" ]; then
    shift
    exec su-exec tor tor "$@"
else
    # Otherwise, run the command as is
    exec "$@"
fi

exec su-exec tor tor -f /etc/tor/torrc
