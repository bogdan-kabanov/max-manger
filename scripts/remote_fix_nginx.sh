#!/bin/bash
set -euo pipefail

cat > /etc/nginx/sites-available/max-desktop <<'EOF'
server {
    listen 8080;
    listen [::]:8080;
    server_name _;
    root /var/www/max-desktop;
    index index.html;
    client_max_body_size 200m;

    location / {
        autoindex on;
        add_header Access-Control-Allow-Origin *;
        add_header Cache-Control "no-cache";
    }

    location = /latest.json {
        add_header Access-Control-Allow-Origin *;
        add_header Cache-Control "no-cache, no-store, must-revalidate";
        default_type application/json;
    }
}
EOF

mkdir -p /var/www/max-desktop
cat > /var/www/max-desktop/latest.json <<'EOF'
{"version":"0.0.0","build":0,"url":"","notes":"placeholder"}
EOF
cat > /var/www/max-desktop/index.html <<'EOF'
<!doctype html><meta charset=utf-8><title>MAX Desktop Updates</title>
<h1>MAX Desktop updates</h1>
<p><a href="/latest.json">latest.json</a></p>
EOF
chown -R www-data:www-data /var/www/max-desktop
ln -sfn /etc/nginx/sites-available/max-desktop /etc/nginx/sites-enabled/max-desktop
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl restart nginx
systemctl is-active nginx
ss -tlnp | grep 8080 || true
curl -s http://127.0.0.1:8080/latest.json
echo
ps -p 23812 -o args= 2>/dev/null || true
