#!/bin/sh
#
# ==============================================================================
# Tor Hidden Service Dynamic Configurator
# ==============================================================================
# This script automatically configures Tor hidden services based on environment
# variables. It is designed to be run as an entrypoint in a Docker container.
#
# Usage:
#   Define environment variables prefixed with 'HS_'. Each variable defines
#   one hidden service.
#
#   Format:
#   HS_<SERVICE_NAME>="host1:port_spec1;host2:port_spec2;..."
#
#   Port Specification (port_spec):
#   - A single port:           80                  (maps virtual port 80 to target port 80)
#   - A virtual:target pair:   8080:80             (maps virtual port 8080 to target port 80)
#   - A range:                 9000-9010           (maps virtual 9000-9010 to target 9000-9010)
#   - A grouped list:          (80,443,8080:80)    (groups multiple ports for a single host)
#
#   Example:
#   HS_WEBSITE="web:(80,443);api:9000-9005,9006:9007"
#
# ==============================================================================

set -e

TORRC_PATH="/etc/tor/torrc"
TOR_DIR="/var/lib/tor"

###
# UTILITY FUNCTIONS
###

# Expands a port range string "START-END" into individual "PORT:PORT" lines.
# Arguments:
#   $1 - The port range string (e.g., "9000-9005").
expand_port_range() {
    port_range="$1"
    start=$(echo "$port_range" | cut -d- -f1)
    end=$(echo "$port_range" | cut -d- -f2)

    i=$start
    while [ "$i" -le "$end" ]; do
        echo "${i}:${i}"
        i=$((i + 1))
    done
}

# Splits the main service specification string by semicolons, but only at the
# top level (i.e., it ignores semicolons inside parentheses).
# Arguments:
#   $1 - The full specification string.
split_services_by_semicolon() {
    input_string="$1"
    echo "$input_string" | awk '
        BEGIN { depth=0; token="" }
        {
            n=length($0)
            for(i=1; i<=n; i++) {
                c=substr($0,i,1)
                if (c=="(") { depth++; token=token c }
                else if (c==")") { depth--; token=token c }
                else if (c==";" && depth==0) {
                    if (token != "") print token
                    token=""
                }
                else { token=token c }
            }
        }
        END { if (token != "") print token }
    '
}

###
# PARSING LOGIC
###

# Processes a single port entry (e.g., "80", "443:80", "9000-9005") for a given host
# and outputs it in the "host:target_port:virtual_port" format.
# Arguments:
#   $1 - The target host.
#   $2 - The port entry string.
_process_port_entry() {
    host="$1"
    entry=$(echo "$2" | tr -d '[:space:]') # Sanitize entry

    [ -z "$entry" ] && return

    if echo "$entry" | grep -q '^[0-9]\+-[0-9]\+$'; then
        # Case: "9000-9005" -> range without target, target=virtual
        expand_port_range "$entry" | while read -r expanded_port; do
            echo "$host:$expanded_port"
        done
    elif echo "$entry" | grep -q ':'; then
        # Case: "target:virtual" or "target:virtual_start-virtual_end"
        target_port=$(echo "$entry" | cut -d: -f1)
        virtual_spec=$(echo "$entry" | cut -d: -f2)

        if echo "$virtual_spec" | grep -q '^[0-9]\+-[0-9]\+$'; then
            # Virtual port is a range
            expand_port_range "$virtual_spec" | while read -r virtual_port; do
                echo "$host:$target_port:$virtual_port"
            done
        else
            # Single virtual port
            echo "$host:$target_port:$virtual_spec"
        fi
    else
        # Single port -> target=virtual
        echo "$host:$entry:$entry"
    fi
}

# Parses a single service item (e.g., "web:(80,443)" or "api:9000") and
# breaks it down into "host:target:virtual" triplets.
# Arguments:
#   $1 - The service item string.
parse_service_item() {
    item="$1"

    case "$item" in
        *\(*\) )
            # Parenthesized format, e.g., "web:(80,443)"
            host=$(echo "$item" | cut -d: -f1)
            inner_spec=$(echo "$item" | sed -E 's/^[^:]*:\((.*)\)$/\1/')

            echo "$inner_spec" | tr ',' '\n' | while read -r entry; do
                _process_port_entry "$host" "$entry"
            done
            ;;
        *)
            # Simple format, e.g., "api:9000"
            host=$(echo "$item" | cut -d: -f1)
            port_spec=$(echo "$item" | cut -s -d: -f2-)

            [ -z "$port_spec" ] && return 0 # Ignore if only a host is provided
            _process_port_entry "$host" "$port_spec"
            ;;
    esac
}


###
# TOR CONFIGURATION
###

# Removes any previous HiddenService directives from the torrc file.
clear_existing_hs_config() {
    echo "Clearing old hidden service configurations..."
    grep -v "HiddenService" "$TORRC_PATH" > "/tmp/torrc.tmp" || true
    cat "/tmp/torrc.tmp" > "$TORRC_PATH"
    rm -f "/tmp/torrc.tmp"
}

# Sets up the directory for a new hidden service.
# Arguments:
#   $1 - The full path to the service directory.
setup_service_directory() {
    service_dir="$1"
    echo "Setting up directory: $service_dir"
    [ ! -d "$service_dir" ] && mkdir -p "$service_dir"
    chown -R tor:tor "$service_dir"
    chmod 700 "$service_dir"
}

# Configures a full hidden service based on a service name and specification.
# Arguments:
#   $1 - The name of the service (e.g., "WEB").
#   $2 - The full, sanitized specification string for the service.
configure_hidden_service() {
    service_name="$1"
    spec="$2"
    service_dir="${TOR_DIR}/${service_name}"

    setup_service_directory "$service_dir"

    echo "HiddenServiceDir $service_dir" >> "$TORRC_PATH"

    split_services_by_semicolon "$spec" | while read -r item; do
        [ -z "$item" ] && continue

        parse_service_item "$item" | while read -r triplet; do
            host=$(echo "$triplet" | cut -d: -f1)
            target_port=$(echo "$triplet" | cut -d: -f2)
            virtual_port=$(echo "$triplet" | cut -d: -f3)

            echo "HiddenServicePort $virtual_port $host:$target_port" >> "$TORRC_PATH"
            echo "  -> Configured $service_name port: $host:$target_port -> $virtual_port"
        done
    done
}

# Finds all environment variables starting with "HS_" and processes them.
process_environment_variables() {
    echo "Processing HS_* environment variables..."
    env | grep -E '^HS_[A-Z0-9_]*=' | cut -d= -f1 | while IFS= read -r var_name; do
        service_name=$(echo "$var_name" | sed 's/^HS_//')

        # Use 'eval' to correctly read the full value of multiline variables
        eval "raw_spec=\$$var_name"

        # Sanitize the spec by removing all whitespace
        sanitized_spec=$(echo "$raw_spec" | tr -d '[:space:]')

        if [ -n "$sanitized_spec" ]; then
            echo "Found service definition for: $service_name"
            configure_hidden_service "$service_name" "$sanitized_spec"
        fi
    done
}


###
# SCRIPT EXECUTION
###

# Prints the .onion addresses to the log after a delay.
print_onion_addresses() {
    sleep 10
    echo ""
    echo "======== TOR HIDDEN SERVICES ========"
    for dir in "${TOR_DIR}"/*/; do
        if [ -f "${dir}hostname" ]; then
            service_name=$(basename "$dir")
            hostname=$(cat "${dir}hostname")
            echo "${service_name}: ${hostname}"
        fi
    done
    echo "===================================="
}

main() {
    clear_existing_hs_config
    process_environment_variables

    # Ensure final permissions are correct for the main Tor data directory
    chown -R tor:tor "$TOR_DIR"
    chmod 700 "$TOR_DIR"

    echo ""
    echo "======== FINAL TORRC CONFIGURATION ========"
    cat "$TORRC_PATH" || true
    echo "========================================="

    # Print addresses in the background
    print_onion_addresses &

    echo "Starting Tor..."
    exec su-exec tor tor -f "$TORRC_PATH"
}

main "$@"