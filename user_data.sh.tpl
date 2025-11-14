#!/bin/bash
# install nginx and simple app that hits RDS (demo)
apt update -y
apt install -y nginx python3-pip
# create a very simple app (python flask) - optional; here we'll serve static index connecting to DB
cat > /var/www/html/index.html <<EOF
<html><body><h1>Hello from $(hostname)</h1>
<p>DB endpoint: ${db_endpoint}</p>
</body></html>
EOF
systemctl restart nginx
