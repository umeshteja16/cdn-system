#!/bin/bash

# 🚀 CDN Performance Testing Suite
# Comprehensive testing for the CDN system architecture

set -e

# Configuration
CDN_BASE_URL="http://localhost"
API_BASE_URL="http://localhost:4000/api"
EDGE_US_URL="http://localhost:8080"
EDGE_EU_URL="http://localhost:8081"
ANALYTICS_URL="http://localhost:5000"
TEST_DURATION=60
CONCURRENT_USERS=50
TEST_FILES_DIR="./test-files"
RESULTS_DIR="./performance-results"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging
log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

success() {
    echo -e "${GREEN}✅ $1${NC}"
}

warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

error() {
    echo -e "${RED}❌ $1${NC}"
}

# Create directories
setup_test_environment() {
    log "Setting up test environment..."
    
    mkdir -p "$TEST_FILES_DIR" "$RESULTS_DIR"
    
    # Create test files of various sizes
    create_test_files
    
    # Upload test files to CDN
    upload_test_files
    
    success "Test environment ready"
}

create_test_files() {
    log "Creating test files..."
    
    # Small image (10KB)
    dd if=/dev/urandom of="$TEST_FILES_DIR/small-image.jpg" bs=1024 count=10 2>/dev/null
    
    # Medium image (500KB)
    dd if=/dev/urandom of="$TEST_FILES_DIR/medium-image.jpg" bs=1024 count=500 2>/dev/null
    
    # Large image (5MB)
    dd if=/dev/urandom of="$TEST_FILES_DIR/large-image.jpg" bs=1024 count=5120 2>/dev/null
    
    # CSS file (50KB)
    dd if=/dev/urandom of="$TEST_FILES_DIR/styles.css" bs=1024 count=50 2>/dev/null
    
    # JavaScript file (100KB)
    dd if=/dev/urandom of="$TEST_FILES_DIR/script.js" bs=1024 count=100 2>/dev/null
    
    # HTML file (5KB)
    cat > "$TEST_FILES_DIR/index.html" << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>CDN Performance Test</title>
    <link rel="stylesheet" href="/content/styles.css">
</head>
<body>
    <h1>CDN Performance Test Page</h1>
    <img src="/content/small-image.jpg" alt="Small Image">
    <img src="/content/medium-image.jpg" alt="Medium Image">
    <script src="/content/script.js"></script>
</body>
</html>
EOF
    
    success "Test files created"
}

upload_test_files() {
    log "Uploading test files to CDN..."
    
    for file in "$TEST_FILES_DIR"/*; do
        filename=$(basename "$file")
        log "Uploading $filename..."
        
        response=$(curl -s -w "%{http_code}" -X POST \
            -F "files=@$file" \
            "$API_BASE_URL/upload" \
            -o /tmp/upload_response.json)
        
        if [ "$response" = "200" ]; then
            success "Uploaded $filename"
        else
            error "Failed to upload $filename (HTTP $response)"
        fi
    done
    
    # Wait for files to be available
    sleep 5
    success "All test files uploaded"
}

# Performance Test Functions

test_cache_performance() {
    log "Testing cache performance..."
    
    local test_file="small-image.jpg"
    local total_requests=1000
    local results_file="$RESULTS_DIR/cache_performance.txt"
    
    echo "Cache Performance Test Results" > "$results_file"
    echo "================================" >> "$results_file"
    echo "Test File: $test_file" >> "$results_file"
    echo "Total Requests: $total_requests" >> "$results_file"
    echo "Date: $(date)" >> "$results_file"
    echo "" >> "$results_file"
    
    # Cold cache test (first request should be MISS)
    log "Testing cold cache (expecting MISS)..."
    cache_status=$(curl -s -I "$CDN_BASE_URL/content/$test_file" | grep -i "x-cache" | cut -d' ' -f2 | tr -d '\r')
    log "Cold cache status: $cache_status"
    echo "Cold Cache Status: $cache_status" >> "$results_file"
    
    # Warm cache test (subsequent requests should be HIT)
    log "Testing warm cache performance..."
    local hit_count=0
    local miss_count=0
    local total_time=0
    
    for i in $(seq 1 100); do
        start_time=$(date +%s.%3N)
        cache_status=$(curl -s -I "$CDN_BASE_URL/content/$test_file" | grep -i "x-cache" | cut -d' ' -f2 | tr -d '\r')
        end_time=$(date +%s.%3N)
        
        response_time=$(echo "$end_time - $start_time" | bc -l)
        total_time=$(echo "$total_time + $response_time" | bc -l)
        
        if [[ "$cache_status" == *"HIT"* ]]; then
            ((hit_count++))
        else
            ((miss_count++))
        fi
        
        if [ $((i % 10)) -eq 0 ]; then
            log "Completed $i/100 cache tests..."
        fi
    done
    
    local avg_time=$(echo "scale=3; $total_time / 100" | bc -l)
    local hit_rate=$(echo "scale=2; $hit_count * 100 / 100" | bc -l)
    
    echo "Warm Cache Results:" >> "$results_file"
    echo "  Cache Hits: $hit_count" >> "$results_file"
    echo "  Cache Misses: $miss_count" >> "$results_file"
    echo "  Hit Rate: ${hit_rate}%" >> "$results_file"
    echo "  Average Response Time: ${avg_time}s" >> "$results_file"
    
    success "Cache performance test completed. Hit rate: ${hit_rate}%"
}

test_load_performance() {
    log "Running load performance test..."
    
    local results_file="$RESULTS_DIR/load_test.txt"
    
    # Test different file sizes under load
    local test_files=("small-image.jpg" "medium-image.jpg" "styles.css" "script.js")
    
    echo "Load Performance Test Results" > "$results_file"
    echo "=============================" >> "$results_file"
    echo "Concurrent Users: $CONCURRENT_USERS" >> "$results_file"
    echo "Test Duration: ${TEST_DURATION}s" >> "$results_file"
    echo "Date: $(date)" >> "$results_file"
    echo "" >> "$results_file"
    
    for test_file in "${test_files[@]}"; do
        log "Load testing $test_file..."
        
        # Use Apache Bench for load testing
        ab_result=$(ab -n 1000 -c "$CONCURRENT_USERS" -t "$TEST_DURATION" \
            "$CDN_BASE_URL/content/$test_file" 2>/dev/null || echo "AB failed")
        
        if [[ "$ab_result" != "AB failed" ]]; then
            echo "File: $test_file" >> "$results_file"
            echo "$ab_result" | grep -E "(Requests per second|Time per request|Transfer rate)" >> "$results_file"
            echo "" >> "$results_file"
            
            # Extract key metrics
            rps=$(echo "$ab_result" | grep "Requests per second" | awk '{print $4}')
            success "Load test for $test_file: ${rps} req/sec"
        else
            warning "Load test failed for $test_file"
        fi
    done
}

test_geographic_performance() {
    log "Testing geographic edge server performance..."
    
    local results_file="$RESULTS_DIR/geographic_performance.txt"
    local test_file="medium-image.jpg"
    
    echo "Geographic Performance Test Results" > "$results_file"
    echo "===================================" >> "$results_file"
    echo "Test File: $test_file" >> "$results_file"
    echo "Date: $(date)" >> "$results_file"
    echo "" >> "$results_file"
    
    # Test US Edge Server
    log "Testing US Edge Server ($EDGE_US_URL)..."
    us_times=()
    for i in $(seq 1 10); do
        start_time=$(date +%s.%3N)
        curl -s "$EDGE_US_URL/content/$test_file" > /dev/null
        end_time=$(date +%s.%3N)
        response_time=$(echo "$end_time - $start_time" | bc -l)
        us_times+=("$response_time")
    done
    
    # Test EU Edge Server
    log "Testing EU Edge Server ($EDGE_EU_URL)..."
    eu_times=()
    for i in $(seq 1 10); do
        start_time=$(date +%s.%3N)
        curl -s "$EDGE_EU_URL/content/$test_file" > /dev/null
        end_time=$(date +%s.%3N)
        response_time=$(echo "$end_time - $start_time" | bc -l)
        eu_times+=("$response_time")
    done
    
    # Calculate averages
    us_avg=$(printf '%s\n' "${us_times[@]}" | awk '{sum+=$1} END {print sum/NR}')
    eu_avg=$(printf '%s\n' "${eu_times[@]}" | awk '{sum+=$1} END {print sum/NR}')
    
    echo "US Edge Server (us-east-1):" >> "$results_file"
    echo "  Average Response Time: ${us_avg}s" >> "$results_file"
    echo "  Individual Times: ${us_times[*]}" >> "$results_file"
    echo "" >> "$results_file"
    echo "EU Edge Server (eu-west-1):" >> "$results_file"
    echo "  Average Response Time: ${eu_avg}s" >> "$results_file"
    echo "  Individual Times: ${eu_times[*]}" >> "$results_file"
    
    success "Geographic performance test completed"
    log "US Edge Average: ${us_avg}s, EU Edge Average: ${eu_avg}s"
}

test_concurrent_uploads() {
    log "Testing concurrent upload performance..."
    
    local results_file="$RESULTS_DIR/concurrent_uploads.txt"
    local upload_count=20
    
    echo "Concurrent Upload Performance Test" > "$results_file"
    echo "=================================" >> "$results_file"
    echo "Concurrent Uploads: $upload_count" >> "$results_file"
    echo "Date: $(date)" >> "$results_file"
    echo "" >> "$results_file"
    
    # Create temporary files for upload testing
    local temp_dir="$TEST_FILES_DIR/upload_test"
    mkdir -p "$temp_dir"
    
    for i in $(seq 1 "$upload_count"); do
        dd if=/dev/urandom of="$temp_dir/upload_test_$i.dat" bs=1024 count=100 2>/dev/null
    done
    
    # Start concurrent uploads
    local start_time=$(date +%s.%3N)
    local pids=()
    
    for i in $(seq 1 "$upload_count"); do
        (
            curl -s -X POST \
                -F "files=@$temp_dir/upload_test_$i.dat" \
                "$API_BASE_URL/upload" \
                > "$temp_dir/result_$i.json"
        ) &
        pids+=($!)
    done
    
    # Wait for all uploads to complete
    for pid in "${pids[@]}"; do
        wait "$pid"
    done
    
    local end_time=$(date +%s.%3N)
    local total_time=$(echo "$end_time - $start_time" | bc -l)
    
    # Count successful uploads
    local success_count=0
    for i in $(seq 1 "$upload_count"); do
        if grep -q "successfully" "$temp_dir/result_$i.json" 2>/dev/null; then
            ((success_count++))
        fi
    done
    
    echo "Results:" >> "$results_file"
    echo "  Total Time: ${total_time}s" >> "$results_file"
    echo "  Successful Uploads: $success_count/$upload_count" >> "$results_file"
    echo "  Average Time per Upload: $(echo "scale=3; $total_time / $upload_count" | bc -l)s" >> "$results_file"
    echo "  Uploads per Second: $(echo "scale=2; $upload_count / $total_time" | bc -l)" >> "$results_file"
    
    # Cleanup
    rm -rf "$temp_dir"
    
    success "Concurrent upload test completed: $success_count/$upload_count successful"
}

test_analytics_performance() {
    log "Testing analytics system performance..."
    
    local results_file="$RESULTS_DIR/analytics_performance.txt"
    
    echo "Analytics Performance Test Results" > "$results_file"
    echo "==================================" >> "$results_file"
    echo "Date: $(date)" >> "$results_file"
    echo "" >> "$results_file"
    
    # Test analytics endpoints
    local endpoints=(
        "metrics/realtime"
        "metrics/timeseries?hours=24"
        "content/top"
        "servers/performance"
    )
    
    for endpoint in "${endpoints[@]}"; do
        log "Testing analytics endpoint: $endpoint"
        
        local total_time=0
        local success_count=0
        
        for i in $(seq 1 10); do
            start_time=$(date +%s.%3N)
            
            if curl -s -f "$ANALYTICS_URL/$endpoint" > /dev/null; then
                ((success_count++))
            fi
            
            end_time=$(date +%s.%3N)
            response_time=$(echo "$end_time - $start_time" | bc -l)
            total_time=$(echo "$total_time + $response_time" | bc -l)
        done
        
        local avg_time=$(echo "scale=3; $total_time / 10" | bc -l)
        
        echo "Endpoint: $endpoint" >> "$results_file"
        echo "  Success Rate: $success_count/10" >> "$results_file"
        echo "  Average Response Time: ${avg_time}s" >> "$results_file"
        echo "" >> "$results_file"
        
        success "Analytics endpoint $endpoint: ${avg_time}s avg, $success_count/10 success"
    done
}

test_system_health() {
    log "Testing system health and connectivity..."
    
    local results_file="$RESULTS_DIR/system_health.txt"
    
    echo "System Health Test Results" > "$results_file"
    echo "==========================" >> "$results_file"
    echo "Date: $(date)" >> "$results_file"
    echo "" >> "$results_file"
    
    # Test health endpoints
    local services=(
        "localhost:3000:Origin Server"
        "localhost:4000:API Gateway"
        "localhost:5000:Analytics Service"
        "localhost:8080:Edge Server US"
        "localhost:8081:Edge Server EU"
        "localhost:80:Load Balancer"
    )
    
    for service in "${services[@]}"; do
        IFS=':' read -r host port name <<< "$service"
        
        log "Testing $name health..."
        
        if curl -s -f "http://$host:$port/health" > /tmp/health_response.json; then
            status=$(jq -r '.status // "unknown"' /tmp/health_response.json 2>/dev/null || echo "unknown")
            echo "$name: ✅ $status" >> "$results_file"
            success "$name is healthy ($status)"
        else
            echo "$name: ❌ Unhealthy or unreachable" >> "$results_file"
            error "$name is unhealthy"
        fi
    done
    
    echo "" >> "$results_file"
    
    # Test database connectivity
    log "Testing database connectivity..."
    if docker-compose exec -T postgres pg_isready -U cdn_user > /dev/null 2>&1; then
        echo "PostgreSQL: ✅ Connected" >> "$results_file"
        success "PostgreSQL is connected"
    else
        echo "PostgreSQL: ❌ Connection failed" >> "$results_file"
        error "PostgreSQL connection failed"
    fi
    
    # Test Redis connectivity
    log "Testing Redis connectivity..."
    if docker-compose exec -T redis-cluster redis-cli ping > /dev/null 2>&1; then
        echo "Redis: ✅ Connected" >> "$results_file"
        success "Redis is connected"
    else
        echo "Redis: ❌ Connection failed" >> "$results_file"
        error "Redis connection failed"
    fi
}

stress_test() {
    log "Running comprehensive stress test..."
    
    local results_file="$RESULTS_DIR/stress_test.txt"
    
    echo "Comprehensive Stress Test Results" > "$results_file"
    echo "=================================" >> "$results_file"
    echo "Test Duration: ${TEST_DURATION}s" >> "$results_file"
    echo "Concurrent Users: $CONCURRENT_USERS" >> "$results_file"
    echo "Date: $(date)" >> "$results_file"
    echo "" >> "$results_file"
    
    # Mixed workload stress test
    local test_urls=(
        "$CDN_BASE_URL/content/small-image.jpg"
        "$CDN_BASE_URL/content/medium-image.jpg"
        "$CDN_BASE_URL/content/styles.css"
        "$CDN_BASE_URL/content/script.js"
        "$CDN_BASE_URL/content/index.html"
    )
    
    log "Starting mixed workload stress test..."
    
    # Start background processes for each URL
    local pids=()
    for url in "${test_urls[@]}"; do
        (
            local requests=0
            local errors=0
            local total_time=0
            local end_time=$(($(date +%s) + TEST_DURATION))
            
            while [ $(date +%s) -lt $end_time ]; do
                start_time=$(date +%s.%3N)
                
                if curl -s -f "$url" > /dev/null 2>&1; then
                    ((requests++))
                else
                    ((errors++))
                fi
                
                end_request_time=$(date +%s.%3N)
                response_time=$(echo "$end_request_time - $start_time" | bc -l)
                total_time=$(echo "$total_time + $response_time" | bc -l)
                
                # Small delay to prevent overwhelming
                sleep 0.01
            done
            
            echo "URL: $url" >> "$results_file.tmp.$$"
            echo "  Requests: $requests" >> "$results_file.tmp.$$"
            echo "  Errors: $errors" >> "$results_file.tmp.$$"
            echo "  Avg Response Time: $(echo "scale=3; $total_time / ($requests + $errors)" | bc -l)s" >> "$results_file.tmp.$$"
            echo "" >> "$results_file.tmp.$$"
        ) &
        pids+=($!)
    done
    
    # Wait for all stress tests to complete
    for pid in "${pids[@]}"; do
        wait "$pid"
    done
    
    # Combine results
    cat "$results_file.tmp."* >> "$results_file" 2>/dev/null || true
    rm -f "$results_file.tmp."* 2>/dev/null || true
    
    success "Stress test completed"
}

generate_report() {
    log "Generating comprehensive performance report..."
    
    local report_file="$RESULTS_DIR/performance_report.html"
    
    cat > "$report_file" << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>CDN Performance Test Report</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; }
        .header { background: #f4f4f4; padding: 20px; border-radius: 5px; }
        .section { margin: 20px 0; padding: 15px; border-left: 4px solid #007cba; }
        .success { color: #28a745; }
        .warning { color: #ffc107; }
        .error { color: #dc3545; }
        pre { background: #f8f9fa; padding: 10px; border-radius: 3px; overflow-x: auto; }
        table { border-collapse: collapse; width: 100%; }
        th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
        th { background-color: #f2f2f2; }
    </style>
</head>
<body>
    <div class="header">
        <h1>CDN Performance Test Report</h1>
        <p>Generated on: $(date)</p>
        <p>Test Configuration:</p>
        <ul>
            <li>Test Duration: ${TEST_DURATION}s</li>
            <li>Concurrent Users: $CONCURRENT_USERS</li>
            <li>CDN Base URL: $CDN_BASE_URL</li>
        </ul>
    </div>
EOF
    
    # Add each test result to the report
    for result_file in "$RESULTS_DIR"/*.txt; do
        if [ -f "$result_file" ]; then
            local section_name=$(basename "$result_file" .txt | tr '_' ' ' | sed 's/\b\w/\U&/g')
            
            cat >> "$report_file" << EOF
    <div class="section">
        <h2>$section_name</h2>
        <pre>$(cat "$result_file")</pre>
    </div>
EOF
        fi
    done
    
    cat >> "$report_file" << 'EOF'
    <div class="section">
        <h2>Summary</h2>
        <p>Performance testing completed successfully. Review individual test results above for detailed metrics.</p>
    </div>
</body>
</html>
EOF
    
    success "Performance report generated: $report_file"
    
    # Also generate a simple text summary
    local summary_file="$RESULTS_DIR/SUMMARY.txt"
    
    cat > "$summary_file" << EOF
CDN PERFORMANCE TEST SUMMARY
============================
Date: $(date)
Test Duration: ${TEST_DURATION}s
Concurrent Users: $CONCURRENT_USERS

Test Results:
$(ls -la "$RESULTS_DIR"/*.txt | wc -l) test files generated

Key Files:
- performance_report.html: Complete HTML report
- cache_performance.txt: Cache hit/miss rates
- load_test.txt: Load testing results
- geographic_performance.txt: Edge server comparison
- system_health.txt: Service health status

Open performance_report.html in your browser for the full report.
EOF
    
    success "Test summary: $summary_file"
}

cleanup() {
    log "Cleaning up test environment..."
    rm -rf "$TEST_FILES_DIR"
    success "Cleanup completed"
}

# Main execution
main() {
    echo "🚀 CDN PERFORMANCE TESTING SUITE"
    echo "================================="
    echo ""
    
    # Check prerequisites
    command -v curl >/dev/null 2>&1 || { error "curl is required but not installed."; exit 1; }
    command -v ab >/dev/null 2>&1 || { warning "apache2-utils (ab) not found. Install for load testing."; }
    command -v jq >/dev/null 2>&1 || { warning "jq not found. Install for better JSON parsing."; }
    command -v bc >/dev/null 2>&1 || { error "bc is required but not installed."; exit 1; }
    
    # Run tests
    setup_test_environment
    
    log "Starting performance tests..."
    
    test_system_health
    test_cache_performance
    test_geographic_performance
    test_concurrent_uploads  
    test_analytics_performance
    test_load_performance
    stress_test
    
    generate_report
    
    echo ""
    success "🎉 All performance tests completed!"
    log "Results available in: $RESULTS_DIR/"
    log "Open $RESULTS_DIR/performance_report.html for the full report"
    
    # Show quick summary
    echo ""
    echo "📊 QUICK SUMMARY:"
    echo "=================="
    if [ -f "$RESULTS_DIR/cache_performance.txt" ]; then
        grep "Hit Rate:" "$RESULTS_DIR/cache_performance.txt" | head -1
    fi
    if [ -f "$RESULTS_DIR/system_health.txt" ]; then
        echo "Services Status:"
        grep -E "(✅|❌)" "$RESULTS_DIR/system_health.txt"
    fi
    
    read -p "Clean up test files? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        cleanup
    fi
}

# Execute main function
main "$@"