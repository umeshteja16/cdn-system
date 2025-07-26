#!/bin/bash

echo "📊 CDN System Monitor - Press Ctrl+C to stop"

while true; do
    clear
    echo "=== CDN SYSTEM DASHBOARD ==="
    echo "Time: $(date)"
    echo
    
    # Container status
    echo "🐳 CONTAINER STATUS:"
    docker-compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" | head -10
    echo
    
    # Health checks
    echo "💚 HEALTH STATUS:"
    services=("3000:Origin" "4000:Gateway" "5000:Analytics" "8080:Edge-US" "8081:Edge-EU" "80:LoadBalancer")
    for service in "${services[@]}"; do
        port=${service%:*}
        name=${service#*:}
        if curl -f -s "http://localhost:$port/health" > /dev/null 2>&1; then
            echo "✅ $name (port $port)"
        else
            echo "❌ $name (port $port)"
        fi
    done
    echo
    
    # Quick analytics
    echo "📊 REAL-TIME METRICS:"
    analytics=$(curl -s "http://localhost:5000/metrics/realtime" 2>/dev/null || echo '{"error":"unavailable"}')
    echo "$analytics" | jq -r 'if .total_requests then "Requests: \(.total_requests) | Cache Hit Rate: \(.cache_hit_rate)% | Bytes: \(.bytes_served)" else "Analytics: Starting..." end' 2>/dev/null || echo "Analytics: Starting..."
    echo
    
    # System resources
    echo "💾 RESOURCE USAGE:"
    docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" | head -8
    
    sleep 5
done