#!/bin/bash
set -euo pipefail
# Exit the script immediately if any command fails (-e),
# treat any use of undefined variables as an error (-u),
# and fail a pipeline if any command in it fails (pipefail).

###############################################################################
# ALLOY MIGRATION/INSTALL SCRIPT
#
# This script:
# - If it finds a Promtail config, migrates it to Alloy
# - Converts and the previous Promtail config, and removes every trace of it.
# - Otherwise, if Prom is not found on OS, installs Alloy and creates a static, typical config for system logs.
# - Ensures Alloy is installed, talking to your specified Loki endpoint.
# - Cleans up binaries, configs, and services for Promtail, if the migration occurs.
#
# Usage:
# apt-cache madison alloy <---- for showing all the Alloy releases
# sudo ./script.sh
#
#
# Author: Gabriele Pergola
###############################################################################

# Configuration variables
readonly PROMTAIL_CONFIG_PATH="/opt/monitoring/promtail/promtail.yml"
readonly ALLOY_CONFIG_PATH="/etc/alloy/config.alloy"
readonly ALLOY_REPO_LINE="deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main"
readonly LOKI_ENDPOINT="http://10.0.0.100:3100/loki/api/v1/push"
readonly HOSTNAME_FIXED="hostaname_alloytest"
readonly ALLOY_VERSION="${1:-1.8.3-1}"  # Default to 1.8.3 if not specified;latest is accepted
# readonly ALLOY_VERSION="${1:-latest}"

# Logging functions
log_info() { echo "[INFO] $*"; }
log_error() { echo "[ERROR] $*" >&2; }

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "THIS SCRIPT MUST BE RUN AS ROOT OR WITH SUDO"
        exit 1
    fi
}

# Install dependencies
install_dependencies() {
    log_info "Installing dependencies..."
    apt update
    apt install -y gpg wget
}

# Setup Grafana repository
setup_grafana_repo() {
    log_info "Setting up Grafana repository..."
    mkdir -p /etc/apt/keyrings/

    if [[ ! -f /etc/apt/keyrings/grafana.gpg ]]; then
        wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor | tee /etc/apt/keyrings/grafana.gpg > /dev/null
    fi

    if ! grep -qF "$ALLOY_REPO_LINE" /etc/apt/sources.list.d/grafana.list 2>/dev/null; then
        echo "$ALLOY_REPO_LINE" | tee /etc/apt/sources.list.d/grafana.list
    fi
}

# Install specific version of Alloy
install_alloy() {
    log_info "Installing Alloy version $ALLOY_VERSION..."
    install_dependencies
    setup_grafana_repo

    apt update

    # Install specific version if specified, otherwise latest
    if [[ "$ALLOY_VERSION" != "latest" ]]; then
        apt install -y "alloy=$ALLOY_VERSION"
        # Hold the package to prevent automatic updates
        apt-mark hold alloy
    else
        apt install -y alloy
    fi

    systemctl enable alloy.service
}

# Write static Alloy configuration
write_static_alloy_config() {
    log_info "Writing static Alloy configuration..."
    tee "$ALLOY_CONFIG_PATH" > /dev/null <<EOF
discovery.relabel "system" {
    targets = [{
        __address__ = "localhost",
        __path__    = "/var/log/*.log",
        job         = "varlogs",
    }]
    rule {
        source_labels = ["__address__"]
        target_label  = "host"
        replacement   = "$HOSTNAME_FIXED"
    }
}

local.file_match "system" {
    path_targets = discovery.relabel.system.output
}

loki.source.file "system" {
    targets               = local.file_match.system.targets
    forward_to            = [loki.write.default.receiver]
    legacy_positions_file = "/tmp/positions.yaml"
}

discovery.relabel "wildfly" {
    targets = [{
        __address__ = "localhost",
        __path__    = "/opt/**/wildfly/standalone/log/*.log",
        job         = "wildfly",
    }]
    rule {
        source_labels = ["__address__"]
        target_label  = "host"
        replacement   = "$HOSTNAME_FIXED"
    }
}

local.file_match "wildfly" {
    path_targets = discovery.relabel.wildfly.output
}

loki.process "wildfly" {
    forward_to = [loki.write.default.receiver]
    stage.multiline {
        firstline = "^\\\\d{4}-\\\\d{2}-\\\\d{2}\\\\s\\\\d{2}\\\\:\\\\d{2}\\\\:\\\\d{2}\\\\,\\\\d{3}"
        max_lines = 1000
    }
    stage.regex {
        expression = "^(?P<time>...)(?P<level>...)(?P<class>...)"
    }
    stage.labels {
        values = {
            level               = null,
            tcpm_mem_used_perc  = null,
            tcpm_remote_address = null,
            tcpm_username       = null,
        }
    }
    stage.timestamp {
        source = "time"
        format = "2006-01-02 15:04:05,999"
    }
    stage.regex {
        expression = "\\\\/opt\\\\/(?P<wildflyInstance>.+)\\\\/wildfly\\\\/"
        source     = "filename"
    }
    stage.labels {
        values = {
            wildflyInstance = null,
        }
    }
}

loki.source.file "wildfly" {
    targets               = local.file_match.wildfly.targets
    forward_to            = [loki.process.wildfly.receiver]
    legacy_positions_file = "/tmp/positions.yaml"
}

loki.write "default" {
    endpoint {
        url = "$LOKI_ENDPOINT"
    }
    external_labels = {}
}
EOF
}

# Remove all traces of Promtail
remove_promtail() {
    log_info "Removing Promtail..."

    # Stop service if running
    systemctl stop promtail 2>/dev/null || true

    # Remove package if installed
    if dpkg-query -W -f='${Status}' promtail 2>/dev/null | grep -q "install ok installed"; then
        DEBIAN_FRONTEND=noninteractive apt purge -y promtail || true
    fi

    # Remove files and directories
    rm -rf /usr/bin/promtail \
           /usr/local/bin/promtail \
           /opt/monitoring/promtail \
           /etc/promtail* \
           /etc/systemd/system/promtail.service* \
           /var/lib/promtail \
           /var/log/promtail 2>/dev/null || true

    systemctl daemon-reload || true
    log_info "Promtail removed successfully"
}

# Convert Promtail config to Alloy
convert_promtail_to_alloy() {
    log_info "Converting Promtail configuration to Alloy..."

    [[ ! -f "$PROMTAIL_CONFIG_PATH" ]] && {
        log_error "Promtail configuration file not found: $PROMTAIL_CONFIG_PATH"
        exit 1
    }

    install_alloy

    log_info "Converting configuration format..."
    alloy convert --source-format=promtail --output="$ALLOY_CONFIG_PATH" "$PROMTAIL_CONFIG_PATH"

    # Update Loki endpoint and hostname
    sed -i "s|url = \"http://[^\"]*:[0-9]\\+/loki/api/v1/push\"|url = \"$LOKI_ENDPOINT\"|" "$ALLOY_CONFIG_PATH"
    sed -i "s/replacement *= *\"[^\"]*\"/replacement = \"$HOSTNAME_FIXED\"/" "$ALLOY_CONFIG_PATH"

    remove_promtail
}

# Main execution
main() {
    check_root

    log_info "Starting Alloy migration/installation (version: $ALLOY_VERSION)..."

    if [[ -f "$PROMTAIL_CONFIG_PATH" ]]; then
        convert_promtail_to_alloy
    else
        install_alloy
        write_static_alloy_config
    fi

    # Start Alloy service
    log_info "Starting Alloy service..."
    systemctl restart alloy
    systemctl status alloy --no-pager

    log_info "Installation completed successfully!"
}

main "$@"
# calls the main function, forwarding all original script arguments ($@).
# this ensures that any command-line arguments given to the script
# are available to the main() function as its parameters.
