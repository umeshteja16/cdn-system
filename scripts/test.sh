#!/bin/bash
# scripts/test.sh
set -e

echo "🧪 Running CDN System Tests..."

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Counters
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# Test results file
TEST_RESULTS="test-results.txt"
> $TEST_RESULTS

print_test_header() {
    echo ""
    echo -e "${BLUE}==================== $1 ====================${NC}"
}

print_pass() {
    echo -e "${GREEN}✅ PASS: $1${NC}"
    echo "PASS: $1" >> $TEST_RESULTS
    PASSED_TESTS=$((PASSED_TESTS + 1))
}

print_fail() {
    echo -e "${RED}❌ FAIL: $1${NC}"
    echo "FAIL: $1" >> $TEST_RESULTS
    FAILED_TESTS=$((FAILED_TESTS + 1))
}

print_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

# Function to test HTTP endpoint
test_endpoint() {
    local url=$1
    local expected_status=$2
    local description=$3
    local timeout=${4:-10}
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    
    status=$(timeout $timeout curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
    
    if [ "$status" = "$expected_status" ]; then
        print_pass "$description ($status)"
        return 0
    else
        print_fail "$description (expected $expected_status, got $status)"
        return 1
    fi
}

# Function to check if service is running
check_service() {
    local service_name=$1
    local description=$2
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    
    if docker-compose ps | grep -q "$service_name.*Up"; then
        print_pass "$description is running"
        return 0
    else
        print_fail "$description is not running"
        return 1
    fi
}

# Function to upload test file
upload_test_file() {
    print_info "Creating and uploading test file..."
    
    # Create test files
    echo "This is a test text file for CDN testing" > test-file.txt
    echo "<html><body><h1>Test HTML File</h1></body></html>" > test-file.html
    
    # Create a small image (1x1 pixel PNG)
    echo -n -e '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\nIDATx\x9cc\x00\x01\x00\x00\x05\x00\x01\r\n-\xdb\x00\x00\x00\x00IEND\xaeB`\x82' > test-file.png
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    
    # Upload text file
    response=$(curl -s -X POST -F "files=@test-file.txt" http://localhost/upload 2>/dev/null || echo "upload failed")
    
    if echo "$response" | grep -q "uploaded successfully" 2>/dev/null; then
        print_pass "File upload successful"
        
        # Extract filename from response
        filename=$(echo "$response" | grep -o '"filename":"[^"]*"' | cut -d'"' -f4 | head -1)
        if [ -n "$filename" ]; then
            echo "$filename" > .test-filename
            print_info "Uploaded filename: $filename"
        else
            echo "test-file.txt" > .test-filename
            print_info "Using fallback filename: test-file.txt"
        fi
        return 0
    else
        print_fail "File upload failed"
        echo "$response"
        return 1
    fi
}

# Function to test content delivery
test_content_delivery() {
    if [ ! -f .test-filename ]; then
        print_info "No test file found. Skipping content delivery tests."
        return
    fi
    
    filename=$(cat .test-filename)
    print_info "Testing content delivery for: $filename"
    
    # Test direct content access
    test_endpoint "http://localhost/content/$filename" "200" "Content delivery"
    
    # Test static content access  
    test_endpoint "http://localhost/static/$filename" "200" "Static content delivery"
    
    # Test cache headers
    print_info "Checking cache headers..."
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    
    headers=$(curl -s -I "http://localhost/content/$filename" 2>/dev/null || echo "")
    
    if echo "$headers" | grep -qi "cache-control" && echo "$headers" | grep -qi "x-cache"; then
        cache_status=$(echo "$headers" | grep -i "x-cache" | cut -d' ' -f2 | tr -d '\r' || echo "UNKNOWN")
        print_pass "Cache headers present (Status: $cache_status)"
    else
        print_fail "Cache headers missing or incomplete"
    fi
    
    # Test cache behavior (second request should be cached)
    print_info "Testing cache behavior..."
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    
    # First request
    curl -s -I "http://localhost/content/$filename" >/dev/null 2>&1
    sleep 1
    
    # Second request should show cache status
    headers2=$(curl -s -I "http://localhost/content/$filename" 2>/dev/null || echo "")
    if echo "$headers2" | grep -qi "x-cache"; then
        print_pass "Cache system is working"
    else
        print_fail "Cache system not working properly"
    fi
}

# Function to test analytics
test_analytics() {
    print_info "Testing analytics endpoints..."
    
    # Direct analytics service
    test_endpoint "http://localhost:5000/health" "200" "Analytics service health"
    test_endpoint "http://localhost:5000/metrics/realtime" "200" "Real-time metrics"
    
    # Through main API
    test_endpoint "http://localhost/api/analytics" "200" "Analytics API endpoint" 15
}

# Function to test monitoring
test_monitoring() {
    print_info "Testing monitoring stack..."
    
    test_endpoint "http://localhost:9090/-/healthy" "200" "Prometheus health"
    test_endpoint "http://localhost:3001/api/health" "200" "Grafana health"
    
    # Test metrics endpoints from edge servers
    test_endpoint "http://localhost:8080/metrics" "200" "Edge server metrics" 15
}

# Function to run basic load test
basic_load_test() {
    print_info "Running basic load test..."
    
    if ! command -v ab &> /dev/null; then
        print_info "Apache Bench (ab) not installed. Skipping load test."
        print_info "Install with: sudo apt-get install apache2-utils (Ubuntu) or brew install httpie (macOS)"
        return 0
    fi
    
    filename=$(cat .test-filename 2>/dev/null || echo "")
    if [ -z "$filename" ]; then
        print_info "No test file available for load testing"
        return 0
    fi
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    
    print_info "Running 50 requests with 5 concurrent connections..."
    
    if ab -n 50 -c 5 -q "http://localhost/content/$filename" > load-test-results.txt 2>&1; then
        print_pass "Load test completed successfully"
        
        # Extract key metrics
        rps=$(grep "Requests per second" load-test-results.txt | awk '{print $4}' || echo "N/A")
        mean_time=$(grep "Time per request.*mean" load-test-results.txt | head -1 | awk '{print $4}' || echo "N/A")
        failed=$(grep "Failed requests" load-test-results.txt | awk '{print $3}' || echo "N/A")
        
        print_info "Results: $rps req/sec, ${mean_time}ms avg, $failed failed"
        
        if [ "$failed" = "0" ] 2>/dev/null; then
            print_pass "No failed requests in load test"
            TOTAL_TESTS=$((TOTAL_TESTS + 1))
            PASSED_TESTS=$((PASSED_TESTS + 1))
        else
            print_fail "Some requests failed during load test"
            TOTAL_TESTS=$((TOTAL_TESTS + 1))
            FAILED_TESTS=$((FAILED_TESTS + 1))
        fi
    else
        print_fail "Load test failed to complete"
    fi
}

# Function to test database connections
test_databases() {
    print_info "Testing database connections..."
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    if docker-compose exec -T postgres pg_isready -U cdn_user -d cdn_db >/dev/null 2>&1; then
        print_pass "PostgreSQL connection"
    else
        print_fail "PostgreSQL connection"
    fi
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    if docker-compose exec -T redis-cluster redis-cli ping | grep -q "PONG" 2>/dev/null; then
        print_pass "Redis connection"
    else
        print_fail "Redis connection"
    fi
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    if curl -sf http://localhost:8086/health >/dev/null 2>&1; then
        print_pass "InfluxDB connection"
    else
        print_fail "InfluxDB connection"
    fi
}

# Main test execution
echo "🏁 Starting CDN System Tests..."
echo "=============================="

# 1. Service Health Checks
print_test_header "SERVICE HEALTH CHECKS"
check_service "nginx" "Nginx Load Balancer"
check_service "origin-server" "Origin Server"
check_service "edge-server-1" "Edge Server 1"
check_service "edge-server-2" "Edge Server 2"
check_service "analytics-service" "Analytics Service"
check_service "postgres" "PostgreSQL Database"
check_service "redis-cluster" "Redis Cache"
check_service "prometheus" "Prometheus"
check_service "grafana" "Grafana"

# 2. Basic Endpoint Tests
print_test_header "BASIC ENDPOINT TESTS"
test_endpoint "http://localhost/health" "200" "CDN main health check"
test_endpoint "http://localhost:3000/health" "200" "Origin server direct health"

# 3. Database Tests
print_test_header "DATABASE CONNECTIVITY"
test_databases

# 4. File Upload and Delivery
print_test_header "FILE OPERATIONS"
upload_test_file
test_content_delivery

# 5. Analytics Tests
print_test_header "ANALYTICS SYSTEM"
test_analytics

# 6. Monitoring Tests
print_test_header "MONITORING STACK"
test_monitoring

# 7. Load Testing
print_test_header "PERFORMANCE TESTING"
basic_load_test

# Cleanup test files
print_info "Cleaning up test files..."
rm -f test-file.txt test-file.html test-file.png .test-filename load-test-results.txt

# Final Results
echo ""
print_test_header "TEST RESULTS SUMMARY"
echo "Total Tests: $TOTAL_TESTS"
echo -e "${GREEN}Passed: $PASSED_TESTS${NC}"
echo -e "${RED}Failed: $FAILED_TESTS${NC}"

if [ $FAILED_TESTS -eq 0 ]; then
    echo -e "${GREEN}🎉 All tests passed! CDN system is working correctly.${NC}"
    exit_code=0
else
    echo -e "${YELLOW}⚠️  Some tests failed. Check the output above for details.${NC}"
    echo ""
    echo "Common solutions:"
    echo "- Wait a few more minutes for services to fully start"
    echo "- Check logs: docker-compose logs [service-name]"
    echo "- Restart services: docker-compose restart"
    echo "- Full reset: ./scripts/cleanup.sh && ./scripts/setup.sh && ./scripts/deploy.sh"
    exit_code=1
fi

echo ""
echo "📄 Detailed results saved to: $TEST_RESULTS"
echo "🐛 For troubleshooting: docker-compose logs -f"

exit $exit_code