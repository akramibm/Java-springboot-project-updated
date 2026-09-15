#!/bin/bash
set -e

mkdir -p /opt/frontend

cat << 'NGINX' > /etc/nginx/sites-available/default
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:8080/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
NGINX

nginx -t
systemctl restart nginx

cd /opt/frontend
if [ ! -d venv ]; then
    python3 -m venv venv
fi
if [ -f requirements.txt ]; then
    ./venv/bin/pip install --upgrade pip
    ./venv/bin/pip install -r requirements.txt
fi

cat << 'UNIT' > /etc/systemd/system/frontend.service
[Unit]
Description=Python Frontend Service
After=network.target

[Service]
User=ubuntu
WorkingDirectory=/opt/frontend
ExecStart=/opt/frontend/venv/bin/python app.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

chown -R ubuntu:ubuntu /opt/frontend
systemctl daemon-reload
systemctl enable frontend.service
systemctl restart frontend.service

sleep 4
systemctl is-active --quiet frontend.service || (journalctl -u frontend.service -n 50 --no-pager && exit 1)
