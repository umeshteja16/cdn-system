#!/bin/bash
# scripts/setup.sh
set -e

echo "🚀 Setting up CDN System..."

# Check if Docker and Docker Compose are installed
if ! command -v docker &> /dev/null; then
    echo "❌ Docker is not installed. Please install Docker first."
    exit 1
fi

if ! command -v docker-compose &> /dev/null; then
    echo "❌ Docker Compose is not installed. Please install Docker Compose first."
    exit 1
fi

# Create necessary directories
echo "📁 Creating directories..."
mkdir -p origin-server/uploads
mkdir -p nginx/ssl
mkdir -p monitoring/grafana/dashboards
mkdir -p monitoring/grafana/provisioning
mkdir -p logs

# Set permissions
chmod 755 origin-server/uploads
chmod 755 nginx/ssl

# Generate SSL certificates for development
echo "🔐 Generating SSL certificates..."
if [ ! -f nginx/ssl/cdn.crt ]; then
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout nginx/ssl/cdn.key \
        -out nginx/ssl/cdn.crt \
        -subj "/C=US/ST=Development/L=Local/O=CDN/CN=localhost"
fi

# Create environment file
echo "⚙️ Creating environment configuration..."
cat > .env << EOF
# Database Configuration
POSTGRES_DB=cdn_db
POSTGRES_USER=cdn_user
POSTGRES_PASSWORD=cdn_password

# Redis Configuration
REDIS_PASSWORD=redis_password

# InfluxDB Configuration
INFLUXDB_ADMIN_USER=admin
INFLUXDB_ADMIN_PASSWORD=admin123
INFLUXDB_USER=cdn_user
INFLUXDB_USER_PASSWORD=cdn_password

# Grafana Configuration
GF_SECURITY_ADMIN_PASSWORD=admin123

# Application Configuration
NODE_ENV=development
CDN_DOMAIN=localhost
API_SECRET_KEY=$(openssl rand -hex 32)

# Monitoring
PROMETHEUS_RETENTION_TIME=15d
GRAFANA_ALLOW_SIGN_UP=false
EOF

echo "✅ Setup completed!"
echo ""
echo "Next steps:"
echo "1. Run './scripts/deploy.sh' to start the CDN system"
echo "2. Access the services:"
echo "   - CDN: http://localhost"
echo "   - Grafana: http://localhost:3001 (admin/admin123)"
echo "   - Prometheus: http://localhost:9090"
echo "   - API Docs: http://localhost/api/docs"


#!/bin/bash
# scripts/deploy.sh
set -e

echo "🚀 Deploying CDN System..."

# Load environment variables
if [ -f .env ]; then
    source .env
    echo "✅ Environment variables loaded"
else
    echo "❌ .env file not found. Run ./scripts/setup.sh first."
    exit 1
fi

# Build and start services
echo "🏗️ Building and starting services..."
docker-compose down --remove-orphans
docker-compose build --no-cache
docker-compose up -d

# Wait for databases to be ready
echo "⏳ Waiting for databases to be ready..."
sleep 30

# Check if PostgreSQL is ready
echo "🔍 Checking PostgreSQL connection..."
until docker-compose exec -T postgres pg_isready -U $POSTGRES_USER -d $POSTGRES_DB; do
    echo "Waiting for PostgreSQL..."
    sleep 5
done

# Check if Redis is ready
echo "🔍 Checking Redis connection..."
until docker-compose exec -T redis-cluster redis-cli ping; do
    echo "Waiting for Redis..."
    sleep 5
done

# Check if InfluxDB is ready
echo "🔍 Checking InfluxDB connection..."
until curl -f http://localhost:8086/health; do
    echo "Waiting for InfluxDB..."
    sleep 5
done

# Run database migrations/setup
echo "📊 Setting up database schema..."
docker-compose exec -T postgres psql -U $POSTGRES_USER -d $POSTGRES_DB -f /docker-entrypoint-initdb.d/init.sql

# Verify services are running
echo "🏥 Health check..."
services=("nginx" "origin-server" "edge-server-1" "edge-server-2" "api-gateway" "analytics-service")

for service in "${services[@]}"; do
    echo "Checking $service..."
    if docker-compose ps | grep -q "$service.*Up"; then
        echo "✅ $service is running"
    else
        echo "❌ $service is not running"
        docker-compose logs $service
    fi
done

# Test endpoints
echo "🧪 Testing endpoints..."
endpoints=(
    "http://localhost/health"
    "http://localhost:9090/-/healthy"
    "http://localhost:3001/api/health"
)

for endpoint in "${endpoints[@]}"; do
    if curl -f -s $endpoint > /dev/null; then
        echo "✅ $endpoint is responding"
    else
        echo "❌ $endpoint is not responding"
    fi
done

echo ""
echo "🎉 CDN System deployed successfully!"
echo ""
echo "🌐 Service URLs:"
echo "   - CDN: http://localhost"
echo "   - Grafana: http://localhost:3001 (admin/admin123)"
echo "   - Prometheus: http://localhost:9090"
echo "   - InfluxDB: http://localhost:8086"
echo ""
echo "📚 Logs: docker-compose logs -f [service-name]"
echo "🔄 Restart: docker-compose restart [service-name]"
echo "🛑 Stop: docker-compose down"

---

#!/bin/bash
# scripts/test.sh
set -e

echo "🧪 Running CDN System Tests..."

# Function to test HTTP endpoint
test_endpoint() {
    local url=$1
    local expected_status=$2
    local description=$3
    
    echo "Testing: $description"
    status=$(curl -s -o /dev/null -w "%{http_code}" "$url" || echo "000")
    
    if [ "$status" = "$expected_status" ]; then
        echo "✅ PASS: $description ($status)"
    else
        echo "❌ FAIL: $description (expected $expected_status, got $status)"
        return 1
    fi
}

# Function to upload test file
upload_test_file() {
    echo "📤 Uploading test file..."
    
    # Create a test file
    echo "This is a test file for CDN" > test-file.txt
    
    # Upload via API
    response=$(curl -s -X POST \
        -F "files=@test-file.txt" \
        http://localhost/api/upload)
    
    if echo "$response" | grep -q "uploaded successfully"; then
        echo "✅ File upload successful"
        # Extract filename from response
        filename=$(echo "$response" | grep -o '"filename":"[^"]*"' | cut -d'"' -f4)
        echo "📁 Uploaded filename: $filename"
        echo "$filename" > .test-filename
    else
        echo "❌ File upload failed"
        echo "$response"
        return 1
    fi
    
    rm test-file.txt
}

# Function to test content delivery
test_content_delivery() {
    if [ ! -f .test-filename ]; then
        echo "❌ No test file found. Skipping content delivery test."
        return 1
    fi
    
    filename=$(cat .test-filename)
    echo "📥 Testing content delivery for: $filename"
    
    # Test direct content access
    test_endpoint "http://localhost/content/$filename" "200" "Content delivery"
    
    # Test static content access
    test_endpoint "http://localhost/static/$filename" "200" "Static content delivery"
    
    # Test cache headers
    echo "🔍 Checking cache headers..."
    headers=$(curl -s -I "http://localhost/content/$filename")
    
    if echo "$headers" | grep -q "Cache-Control"; then
        echo "✅ Cache-Control header present"
    else
        echo "❌ Cache-Control header missing"
    fi
    
    if echo "$headers" | grep -q "X-Cache"; then
        cache_status=$(echo "$headers" | grep "X-Cache" | cut -d' ' -f2 | tr -d '\r')
        echo "✅ Cache status: $cache_status"
    else
        echo "❌ X-Cache header missing"
    fi
}

# Function to test analytics
test_analytics() {
    echo "📊 Testing analytics endpoints..."
    
    test_endpoint "http://localhost/api/analytics" "200" "Analytics data"
    
    # Test analytics service directly
    test_endpoint "http://localhost:5000/health" "200" "Analytics service health"
    test_endpoint "http://localhost:5000/metrics/realtime" "200" "Real-time metrics"
}

# Function to test monitoring
test_monitoring() {
    echo "📈 Testing monitoring endpoints..."
    
    test_endpoint "http://localhost:9090/-/healthy" "200" "Prometheus health"
    test_endpoint "http://localhost:3001/api/health" "200" "Grafana health"
    
    # Test metrics endpoints
    test_endpoint "http://localhost:8080/metrics" "200" "Edge server metrics"
}

# Function to load test
load_test() {
    echo "⚡ Running basic load test..."
    
    if ! command -v ab &> /dev/null; then
        echo "⚠️ Apache Bench (ab) not installed. Skipping load test."
        return 0
    fi
    
    filename=$(cat .test-filename 2>/dev/null || echo "")
    if [ -z "$filename" ]; then
        echo "❌ No test file for load testing"
        return 1
    fi
    
    echo "🚀 Running 100 requests with 10 concurrent connections..."
    ab -n 100 -c 10 "http://localhost/content/$filename" > load-test-results.txt
    
    if [ $? -eq 0 ]; then
        echo "✅ Load test completed"
        echo "📊 Results saved to load-test-results.txt"
        
        # Extract key metrics
        grep "Requests per second" load-test-results.txt || true
        grep "Time per request" load-test-results.txt || true
        grep "Failed requests" load-test-results.txt || true
    else
        echo "❌ Load test failed"
    fi
}

# Main test execution
echo "🏁 Starting tests..."
echo "===================="

# Basic health checks
echo "1️⃣ Health Checks"
test_endpoint "http://localhost/health" "200" "CDN health check"
test_endpoint "http://localhost:3000/health" "200" "Origin server health"

# File upload and delivery
echo ""
echo "2️⃣ File Operations"
upload_test_file
test_content_delivery

# Analytics tests
echo ""
echo "3️⃣ Analytics"
test_analytics

# Monitoring tests
echo ""
echo "4️⃣ Monitoring"
test_monitoring

# Load testing
echo ""
echo "5️⃣ Load Testing"
load_test

# Cleanup
echo ""
echo "🧹 Cleaning up..."
rm -f .test-filename load-test-results.txt

echo ""
echo "✅ Test suite completed!"
echo "🐛 If any tests failed, check the logs with: docker-compose logs [service-name]"

---

#!/bin/bash
# scripts/cleanup.sh
set -e

echo "🧹 Cleaning up CDN System..."

# Stop all containers
echo "🛑 Stopping containers..."
docker-compose down --remove-orphans

# Remove volumes (optional - prompts user)
read -p "🗑️ Remove all data volumes? [y/N]: " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    docker-compose down -v
    echo "✅ Volumes removed"
fi

# Remove images (optional - prompts user)
read -p "🗑️ Remove built images? [y/N]: " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    docker-compose down --rmi all
    echo "✅ Images removed"
fi

# Clean up generated files
echo "🗄️ Cleaning up generated files..."
rm -f .env
rm -f origin-server/uploads/*
rm -f nginx/ssl/cdn.*
rm -f logs/*

# Prune Docker system (optional)
read -p "🗑️ Prune Docker system (remove unused containers, networks, images)? [y/N]: " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    docker system prune -f
    echo "✅ Docker system pruned"
fi

echo ""
echo "🎉 Cleanup completed!"
echo "💡 To redeploy, run: ./scripts/setup.sh && ./scripts/deploy.sh"