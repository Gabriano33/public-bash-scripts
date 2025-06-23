#!/bin/bash
set -euo pipefail

###############################################################################
# Alloy Migration/Install Script
# -----------------------------------------------------------------------------
# This script:
# - If it finds a Promtail config, migrates it to Alloy (Grafana's new unified agent),
#   converts and fixes configuration, and removes every trace of Promtail.
# - Otherwise, installs Alloy and creates a static, typical config for system logs.
# - Ensures only Alloy is installed, talking to your specified Loki endpoint.
# - Cleans up binaries, configs, and services for Promtail.
#
# tools:
# - apt, wget, gpg: for repository setup and package installation
# - dpkg-query, rm: for robust removal of previous Promtail traces
###############################################################################

# Paths and simple config variables
PROMTAIL_CONFIG_PATH="/opt/monitoring/promtail/promtail.yml"    # Default promtail config path
ALLOY_CONFIG_PATH="/etc/alloy/config.alloy"                     # Alloy config output
ALLOY_REPO_LINE="deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main"  # Repo for apt
LOKI_ENDPOINT="http://10.0.0.100:3100/loki/api/v1/push"         # Where to send logs
HOSTNAME_FIXED="progettogabri-vm"                               # Static hostname label for logs

###############################################################################
# Install Alloy's apt repo, keyring and package
# Always enables systemd service so Alloy runs on boot.
###############################################################################
install_alloy() {
    echo "[INFO] Installing Alloy repository and packages..."
    sudo apt update
    sudo apt install -y gpg wget           # gpg/wget needed for key and repo initialization
    sudo mkdir -p /etc/apt/keyrings/       # Keyring folder for all Grafana products
    # Install Grafana's GPG key if missing
    if ! [ -f /etc/apt/keyrings/grafana.gpg ]; then
        wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor | sudo tee /etc/apt/keyrings/grafana.gpg > /dev/null
    fi
    # Add alloy's APT repo line if not present already
    if ! grep -qF "$ALLOY_REPO_LINE" /etc/apt/sources.list.d/grafana.list 2>/dev/null; then
        echo "$ALLOY_REPO_LINE" | sudo tee /etc/apt/sources.list.d/grafana.list
    fi
    sudo apt-get update
    sudo apt-get install -y alloy          # Actually install Alloy
    sudo systemctl enable alloy.service    # Enable Alloy for auto start on boot
}

###############################################################################
# Write a static Alloy config (for new installs or if you want a canned config)
# Contains two log sources: classic /var/log/*.log and wildfly app logs
###############################################################################
write_static_alloy_config() {
    echo "[INFO] Writing static Alloy configuration as requested..."
    sudo tee "$ALLOY_CONFIG_PATH" > /dev/null <<'EOF'
discovery.relabel "system" {
        targets = [{
                __address__ = "localhost",
                __path__    = "/var/log/*.log",            # System logs
                job         = "varlogs",
        }]
        rule {
                source_labels = ["__address__"]
                target_label  = "host"
                replacement   = "progettogabri-vm"         # Static label for host
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
                __path__    = "/opt/**/wildfly/standalone/log/*.log",   # Wildfly logs
                job         = "wildfly",
        }]
        rule {
                source_labels = ["__address__"]
                target_label  = "host"
                replacement   = "progettogabri-vm"
        }
}

local.file_match "wildfly" {
        path_targets = discovery.relabel.wildfly.output
}

loki.process "wildfly" {
        forward_to = [loki.write.default.receiver]
        stage.multiline {
                firstline = "^\\d{4}-\\d{2}-\\d{2}\\s\\d{2}\\:\\d{2}\\:\\d{2}\\,\\d{3}"   # Regex for multi-line java logs
                max_lines = 1000
        }
        stage.regex {
                expression = "^(?P<time>...)(?P<level>...)(?P<class>...)"   # Complex parsing for Wildfly specifics
                # See docs for full regex explanation
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
                format = "2006-01-02 15:04:05,999"        # Parse log timestamp
        }
        stage.regex {
                expression = "\\/opt\\/(?P<wildflyInstance>.+)\\/wildfly\\/"
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
                url = "http://10.0.0.100:3100/loki/api/v1/push"   # Where to push logs (change as needed)
        }
        external_labels = {}
}
EOF
}

###############################################################################
# Remove all traces of promtail
# - Stops systemd service
# - Removes .deb package
# - Removes binaries, configs, service files, and log positions
# - Reloads systemd to forget the service
###############################################################################
remove_promtail_action() {
    sudo systemctl stop promtail 2>/dev/null || true
    # If installed as a .deb, purge it (no prompts)
    if dpkg-query -W -f='${Status}' promtail 2>/dev/null | grep -q "install ok installed"; then
        sudo DEBIAN_FRONTEND=noninteractive apt-get purge -y promtail || true
    fi
    # Remove possible manual installs and config
    sudo rm -f /usr/bin/promtail /usr/local/bin/promtail 2>/dev/null || true
    sudo rm -rf /opt/monitoring/promtail \
      /etc/promtail* \
      /etc/systemd/system/promtail.service* \
      /var/lib/promtail \
      /var/log/promtail 2>/dev/null || true
    sudo systemctl daemon-reload || true
}

remove_promtail() {
    echo "[INFO] Removing promtail... May take a while"
    remove_promtail_action || true
    echo "[INFO] Promtail removed."
}

###############################################################################
# Convert an existing promtail config to Alloy
# - Installs Alloy first (safe if already installed)
# - Uses `alloy convert` to translate promtail YAML into Alloy HCL
# - Fixes the Loki endpoint and hostname in Alloy's config
# - Cleans up all promtail artifacts
###############################################################################
convert_promtail_to_alloy() {
    echo "[INFO] Promtail detected: converting configuration to Alloy..."

    # Safety: check that promtail config yaml is available
    if [ ! -f "$PROMTAIL_CONFIG_PATH" ]; then
        echo "[ERROR] Promtail configuration file: $PROMTAIL_CONFIG_PATH not found. Aborting."
        exit 1
    fi

    install_alloy
    echo "[INFO] Converting promtail configuration to Alloy format..."
    # The magic! Converts promtail YAML config into Alloy config
    sudo alloy convert --source-format=promtail --output="$ALLOY_CONFIG_PATH" "$PROMTAIL_CONFIG_PATH"

    echo "[INFO] Updating Loki endpoint URL..."
    # Patch the config for the correct Loki endpoint
    sudo sed -i 's|url = "http://[^"]*:[0-9]\+/loki/api/v1/push"|url = "'"$LOKI_ENDPOINT"'"|' "$ALLOY_CONFIG_PATH"
    # Patch host label in config
    sudo sed -i 's/replacement *=[^"]*"[^"]*"/replacement = "'"$HOSTNAME_FIXED"'"/' "$ALLOY_CONFIG_PATH" || true

    remove_promtail
}

###############################################################################
# Main control flow
# If promtail config file exists, migrate and remove promtail.
# Otherwise, do a fresh Alloy install and create a standard config.
###############################################################################
main() {
    if [ -f "$PROMTAIL_CONFIG_PATH" ]; then
        convert_promtail_to_alloy
    else
        install_alloy
        write_static_alloy_config
    fi

    # Restart alloy to pick up any changes, and show status
    sudo systemctl restart alloy
    sudo systemctl status alloy

    echo "[INFO] === END OF SCRIPT ==="
}

main "$@"