#!/bin/bash
set -e

# 1. Ensure required system packages exist
which python3 &>/dev/null || (apt-get update -y && apt-get install -y python3 python3-pip python3-venv)

# 2. Configure Nginx reverse proxy
cat << 'NGINX' > /etc/nginx/sites-available/default
server {
listen 80 default_server;
listen [::]:80 default_server;

location / {
    proxy_pass http://127.0.0.1:5000;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
}

location /api/ {
    proxy_pass http://127.0.0.1:8080/;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
}
}
NGINX

nginx -t
systemctl restart nginx

# 3. Setup Python venv outside /opt/frontend so s3 sync never touches it
mkdir -p /opt/frontend
VENV_DIR="/opt/frontend-venv"

if [ ! -f "${VENV_DIR}/bin/pip" ]; then
rm -rf "$VENV_DIR"
python3 -m venv "$VENV_DIR"
fi

if [ -f /opt/frontend/requirements.txt ]; then
"${VENV_DIR}/bin/pip" install --upgrade pip
"${VENV_DIR}/bin/pip" install -r /opt/frontend/requirements.txt
fi

# 4. Configure frontend systemd unit
cat << 'UNIT' > /etc/systemd/system/frontend.service
[Unit]
Description=Python Frontend Service
After=network.target

[Service]
User=ubuntu
WorkingDirectory=/opt/frontend
ExecStart=/opt/frontend-venv/bin/python app.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

chown -R ubuntu:ubuntu /opt/frontend /opt/frontend-venv
systemctl daemon-reload
systemctl enable frontend.service
systemctl restart frontend.service

sleep 4
systemctl is-active --quiet frontend.service || (journalctl -u frontend.service -n 50 --no-pager && exit 1)
echo "Frontend service is active and running."
