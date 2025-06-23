#!/bin/sh
# Some Debian-based cloud Virtual Machines don’t have GPG installed by default. To install GPG:
sudo apt install -y gpg

# Import the GPG key and add the Grafana package repository:
sudo mkdir -p /etc/apt/keyrings/
wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor | sudo tee /etc/apt/keyrings/grafana.gpg > /dev/null

echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" | sudo tee /etc/apt/sources.list.d/grafana.list

# Update the repositories:
sudo apt-get update

# (può dare avvisi sull'aggiornare il kernel, quantomeno sulla macchina di test)
sudo apt-get install -y alloy

# Configure Alloy to start at boot:
sudo systemctl enable alloy.service

# conversione da promtail
# alloy convert --source-format=promtail --output=<OUTPUT_CONFIG_PATH> <INPUT_CONFIG_PATH>
alloy convert --source-format=promtail --output=/etc/alloy/config.alloy /opt/monitoring/promtail/promtail.yml

# Modifica (solo se esiste) l'endpoint di loki al nuovo IP privato
# Nota: usiamo sed "inplace" per modificare la riga corretta nel config.alloy
sudo sed -i 's|url = "http://[^"]*:[0-9]\+/loki/api/v1/push"|url = "http://10.0.0.100:3100/loki/api/v1/push"|' /etc/alloy/config.alloy


sudo systemctl restart alloy
sudo systemctl status alloy
