#!/bin/bash
# scripts/deploy.sh
set -e

echo "🚀 Deploying CDN System..."

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

# Check if .env file exists
if [ -f .env ]; then
    source .env
    print_status "Environment variables loaded"
else
    print_error ".env file not found. Run ./scripts/setup.sh first."
    exit 1
fi

# Check if Docker is running
if ! docker info >/dev/null 2>&1; then
    print_error "Docker is not running. Please start Docker first."
    exit 1
fi

print_info "Stopping any existing containers..."
docker-compose down --remove-orphans 2>/dev/null || true

print_info "Building Docker images..."
docker-compose build --no-cache

print_info "Starting services..."
docker-compose up -d

# Wait for services to start
print_info "Waiting for services to initialize..."
sleep 10

# Function to wait for service to be ready
wait_for_service() {
    local service_name=$1
    local port=$2
    local max_attempts=30
    local attempt=1
    
    print_info "Waiting for $service_name to be ready..."
    
    while [ $attempt -le $max_attempts ]; do
        if docker-compose exec -T $service_name true 2>/dev/null; then
            if [ "$service_name" = "postgres" ]; then
                if docker-compose exec -T postgres pg_isready -U ${POSTGRES_USER:-cdn_user} -d ${POSTGRES_DB:-cdn_db} >/dev/null 2>&1; then
                    print_status "$service_name is ready"
                    return 0
                fi
            elif [ "$service_name" = "redis-cluster" ]; then
                if docker-compose exec -T redis-cluster redis-cli ping >/dev/null 2>&1; then
                    print_status "$service_name is ready"
                    return 0
                fi
            elif [ "$service_name" = "influxdb" ]; then
                if curl -sf http://localhost:8086/health >/dev/null 2>&1; then
                    print_status "$service_name is ready"
                    return 0
                fi
            else
                print_status "$service_name is ready"
                return 0
            fi
        fi
        
        echo -n "."
        sleep 2
        attempt=$((attempt + 1))
    done
    
    print_error "$service_name failed to start within expected time"
    return 1
}

# Wait for core services
wait_for_service "postgres" 5432
wait_for_service "redis-cluster" 6379
wait_for_service "influxdb" 8086

print_info "Waiting for application services..."
sleep 15

# Check service health
print_info "Performing health checks..."

services=("nginx" "origin-server" "edge-server-1" "edge-server-2" "analytics-service")
failed_services=()

for service in "${services[@]}"; do
    if docker-compose ps | grep -q "$service.*Up"; then
        print_status "$service is running"
    else
        print_error "$service is not running"
        failed_services+=("$service")
    fi
done

# Test key endpoints
print_info "Testing key endpoints..."

endpoints_to_test=(
    "http://localhost/health:CDN Health Check"
    "http://localhost:9090/-/healthy:Prometheus"
    "http://localhost:3001/api/health:Grafana"
)

for endpoint_info in "${endpoints_to_test[@]}"; do
    IFS=':' read -r endpoint description <<< "$endpoint_info"
    
    if curl -sf "$endpoint" >/dev/null 2>&1; then
        print_status "$description is responding"
    else
        print_warning "$description is not responding (may still be starting)"
    fi
done

# Show service status
echo ""
print_info "Service Status:"
docker-compose ps

# Show failed services logs if any
if [ ${#failed_services[@]} -gt 0 ]; then
    echo ""
    print_warning "Some services failed to start. Showing logs:"
    for service in "${failed_services[@]}"; do
        echo ""
        print_info "Logs for $service:"
        docker-compose logs --tail=20 "$service"
    done
fi

echo ""
if [ ${#failed_services[@]} -eq 0 ]; then
    print_status "🎉 CDN System deployed successfully!"
else
    print_warning "⚠️  CDN System deployed with some issues. Check the logs above."
fi

echo ""
echo "🌐 Access URLs:"
echo "   - CDN Main:     http://localhost"
echo "   - Grafana:      http://localhost:3001 (admin/admin123)"
echo "   - Prometheus:   http://localhost:9090"
echo "   - InfluxDB:     http://localhost:8086"
echo ""
echo "📚 Useful Commands:"
echo "   - View logs:    docker-compose logs -f [service-name]"
echo "   - Restart:      docker-compose restart [service-name]"
echo "   - Stop all:     docker-compose down"
echo "   - Test system:  ./scripts/test.sh"
echo ""
echo "🐛 If services failed to start:"
echo "   - Check logs:   docker-compose logs [service-name]"
echo "   - Restart:      docker-compose restart [service-name]"
echo "   - Full restart: docker-compose down && docker-compose up -d"