# 🔧 Network Configuration Fix

# The issue: Docker network IPv6 configuration mismatch
# Solution: Remove the manual network creation and let Docker Compose handle it

# Step 1: Clean everything including the problematic network
echo "🧹 Cleaning up everything..."
docker-compose down -v
docker network rm cdn-system_cdn-network 2>/dev/null || echo "Network already removed"
docker system prune -f

# Step 2: Let Docker Compose create the network properly
echo "🚀 Starting with Docker Compose network management..."
docker-compose up -d

# Step 3: If that fails, try a more targeted approach
# If the above command fails with network errors, run this instead:

echo "🔧 Alternative: Sequential startup without manual network..."

# Remove any existing network
docker network rm cdn-system_cdn-network 2>/dev/null || true

# Start infrastructure services (this will create the network)
docker-compose up -d postgres redis-cluster influxdb

# Wait for infrastructure
echo "⏳ Waiting for infrastructure..."
sleep 30

# Check infrastructure
docker-compose ps postgres redis-cluster influxdb

# Start application services
docker-compose up -d origin-server analytics-service api-gateway

# Wait for applications
echo "⏳ Waiting for applications..."
sleep 20

# Check applications
docker-compose ps origin-server analytics-service api-gateway

# Start edge servers
docker-compose up -d edge-server-us edge-server-eu

# Wait for edge servers
echo "⏳ Waiting for edge servers..."
sleep 15

# Start nginx
docker-compose up -d nginx

# Final check
echo "🏁 Final status:"
docker-compose ps