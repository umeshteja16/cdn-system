#!/bin/bash
set -e

echo "🚀 Setting up CDN system..."

# Create necessary directories
mkdir -p uploads logs cache/edge-1 cache/edge-2 nginx/ssl

# Set permissions
chmod 755 uploads/ cache/ logs/ nginx/ssl/

# Generate SSL certificates for development
if [ ! -f nginx/ssl/cdn.crt ]; then
    echo "📜 Generating SSL certificates..."
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout nginx/ssl/cdn.key \
        -out nginx/ssl/cdn.crt \
        -subj "/C=US/ST=State/L=City/O=CDN/CN=localhost"
fi

# Create .env file
cat > .env << EOF
# Database
POSTGRES_DB=cdn_db
POSTGRES_USER=cdn_user
POSTGRES_PASSWORD=cdn_password

# Redis
REDIS_PASSWORD=redis_password

# InfluxDB
INFLUXDB_ADMIN_USER=admin
INFLUXDB_ADMIN_PASSWORD=admin123
INFLUXDB_ADMIN_TOKEN=admin-token

# Application
NODE_ENV=production
CDN_DOMAIN=localhost
API_SECRET_KEY=$(openssl rand -hex 32)
EOF

echo "✅ Setup complete! Run './scripts/deploy.sh' to start your CDN."