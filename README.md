# CDN System - Complete Guide

A production-ready Content Delivery Network (CDN) implementation built with modern technologies including Node.js, Go, Python, Redis, PostgreSQL, and Nginx. This system provides distributed content caching, real-time analytics, and high-performance content delivery across multiple edge servers.

## Table of Contents

- [What is a CDN?](#what-is-a-cdn)
- [System Architecture](#system-architecture)
- [Features](#features)
- [Technology Stack](#technology-stack)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Detailed Setup](#detailed-setup)
- [System Components](#system-components)
- [API Documentation](#api-documentation)
- [Performance Testing](#performance-testing)
- [Monitoring & Analytics](#monitoring--analytics)
- [Troubleshooting](#troubleshooting)
- [Learning Resources](#learning-resources)

## What is a CDN?

A **Content Delivery Network (CDN)** is a distributed system of servers that delivers web content to users based on their geographic location. The primary goals are:

- **Reduce Latency**: Serve content from the closest server to the user
- **Improve Performance**: Cache static assets to reduce server load
- **Increase Availability**: Distribute content across multiple servers for redundancy
- **Scale Globally**: Handle high traffic volumes across different regions

### Key CDN Concepts

- **Origin Server**: The main server containing the original content
- **Edge Servers**: Distributed cache servers close to end users
- **Cache Hit/Miss**: Whether content is found in cache (hit) or needs to be fetched from origin (miss)
- **TTL (Time To Live)**: How long content stays cached before expiring
- **Geographic Distribution**: Placing servers in different regions worldwide

## System Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   User Request  │───▶│  Load Balancer  │───▶│   Edge Server   │
│                 │    │     (Nginx)     │    │   (Go Cache)    │
└─────────────────┘    └─────────────────┘    └─────────────────┘
                                │                        │
                                ▼                        ▼
                       ┌─────────────────┐    ┌─────────────────┐
                       │  API Gateway    │    │ Origin Server   │
                       │   (Node.js)     │    │   (Node.js)     │
                       └─────────────────┘    └─────────────────┘
                                │                        │
                                ▼                        ▼
                       ┌─────────────────┐    ┌─────────────────┐
                       │ Analytics API   │    │   PostgreSQL    │
                       │   (Python)      │    │   Database      │
                       └─────────────────┘    └─────────────────┘
                                │                        │
                                ▼                        ▼
                       ┌─────────────────┐    ┌─────────────────┐
                       │    InfluxDB     │    │   Redis Cache   │
                       │ (Time Series)   │    │   (Cluster)     │
                       └─────────────────┘    └─────────────────┘
```

### Service Flow

1. **User Request** → Nginx Load Balancer
2. **Load Balancer** → Routes to appropriate Edge Server
3. **Edge Server** → Checks Redis cache for content
4. **Cache Miss** → Fetches from Origin Server
5. **Cache Hit** → Serves cached content directly
6. **Analytics** → Tracks all requests in real-time
7. **Database** → Stores metadata and analytics data

## Features

### Core CDN Features
- **Multi-Region Edge Servers** - US East, EU West, expandable
- **Intelligent Caching** - Redis-based with configurable TTL
- **Load Balancing** - Nginx with health checks and failover
- **Content Upload** - Multi-file upload with validation
- **Cache Invalidation** - Pattern-based cache clearing
- **Geographic Routing** - Automatic region-based serving

### Analytics & Monitoring
- **Real-time Analytics** - Request tracking and performance metrics
- **Time-series Data** - InfluxDB for historical analysis
- **Geographic Distribution** - Request origin tracking
- **Cache Performance** - Hit/miss rates and optimization insights
- **Edge Server Monitoring** - Health status and performance metrics
- **Daily Reports** - Automated analytics summaries

### Performance Features
- **HTTP/2 Support** - Modern protocol optimization
- **Gzip Compression** - Automatic content compression
- **Smart TTL** - Content-type based cache duration
- **Rate Limiting** - DDoS protection and traffic control
- **Health Checks** - Automatic service monitoring

## Technology Stack

### Backend Services
- **Node.js 18** - Origin server and API gateway
- **Go 1.21** - High-performance edge servers
- **Python 3.11** - Analytics and data processing
- **Nginx** - Load balancing and reverse proxy

### Databases & Caching
- **PostgreSQL 15** - Primary database for metadata
- **Redis 7** - Distributed caching layer
- **InfluxDB 2.7** - Time-series analytics data

### Infrastructure
- **Docker & Docker Compose** - Containerized deployment
- **Prometheus Metrics** - Performance monitoring
- **Health Check Endpoints** - Service monitoring

## Prerequisites

### System Requirements
- **Operating System**: Linux, macOS, or Windows with WSL2
- **RAM**: Minimum 8GB (16GB recommended)
- **Storage**: At least 10GB free space
- **CPU**: Multi-core processor recommended

### Required Software
```bash
# Docker & Docker Compose
docker --version  # 20.10+
docker-compose --version  # 1.29+

# Development tools (optional)
curl --version
jq --version
bc --version
```

### Installation Commands

**Ubuntu/Debian:**
```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Install Docker
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
sudo usermod -aG docker $USER

# Install Docker Compose
sudo apt install docker-compose-plugin

# Install testing tools
sudo apt install curl jq bc apache2-utils
```

**macOS:**
```bash
# Install Docker Desktop
# Download from: https://docs.docker.com/desktop/mac/install/

# Install testing tools with Homebrew
brew install curl jq bc apache2-utils
```

**Windows (WSL2):**
```bash
# Install Docker Desktop with WSL2 backend
# Download from: https://docs.docker.com/desktop/windows/install/

# In WSL2 terminal:
sudo apt update
sudo apt install curl jq bc apache2-utils
```

## Quick Start

### 1. Clone and Setup
```bash
# Clone the repository
git clone <repository-url>
cd cdn-system

# Make scripts executable
chmod +x scripts/*.sh

# Run setup script
./scripts/setup.sh
```

### 2. Deploy the System
```bash
# Deploy all services
./scripts/deploy.sh

# Monitor deployment status
./scripts/monitor.sh
```

### 3. Verify Installation
```bash
# Check all services are running
docker-compose ps

# Test health endpoints
curl http://localhost/health
curl http://localhost:4000/health
curl http://localhost:5000/health
```

### 4. Upload Test Content
```bash
# Create a test file
echo "Hello CDN World!" > test.txt

# Upload via API
curl -X POST \
  -F "files=@test.txt" \
  http://localhost:4000/api/upload

# Access through CDN
curl http://localhost/content/test-<timestamp>.txt
```

## Detailed Setup

### Environment Configuration

The system uses environment variables for configuration. The setup script creates a `.env` file with defaults:

```bash
# Database Configuration
POSTGRES_DB=cdn_db
POSTGRES_USER=cdn_user
POSTGRES_PASSWORD=cdn_password

# Redis Configuration
REDIS_PASSWORD=redis_password

# InfluxDB Configuration
INFLUXDB_ADMIN_USER=admin
INFLUXDB_ADMIN_PASSWORD=admin123
INFLUXDB_ADMIN_TOKEN=admin-token

# Application Settings
NODE_ENV=production
CDN_DOMAIN=localhost
API_SECRET_KEY=<auto-generated>
```

### SSL Configuration

For production deployment with custom domains:

```bash
# Replace development certificates
cp your-domain.crt nginx/ssl/cdn.crt
cp your-domain.key nginx/ssl/cdn.key

# Update nginx configuration
# Edit nginx/nginx.conf to use your domain
```

### Custom Domain Setup

1. **Update DNS Records**:
   ```
   A    cdn.yourdomain.com    → YOUR_SERVER_IP
   CNAME api.yourdomain.com   → cdn.yourdomain.com
   ```

2. **Update Configuration**:
   ```bash
   # Edit docker-compose.yml
   environment:
     - CDN_DOMAIN=cdn.yourdomain.com
   ```

3. **Restart Services**:
   ```bash
   docker-compose restart nginx
   ```

## System Components

### 1. Origin Server (Node.js)
**Location**: `origin-server/src/app.js`
**Port**: 3000

The main content server handling:
- File uploads and storage
- Content metadata management
- Database operations
- Health monitoring

**Key Features**:
- Multi-file upload support
- File validation and security
- PostgreSQL integration
- Analytics tracking

### 2. Edge Servers (Go)
**Location**: `edge-server/main.go`
**Ports**: 8080 (US), 8081 (EU)

High-performance caching servers:
- Redis-based content caching
- Origin server fallback
- Geographic routing
- Prometheus metrics

**Key Features**:
- Intelligent cache management
- HTTP/2 support
- Concurrent request handling
- Automatic cache invalidation

### 3. Analytics Service (Python)
**Location**: `analytics-service/main.py`
**Port**: 5000

Real-time analytics and reporting:
- Request tracking
- Performance metrics
- Time-series data storage
- Geographic analytics

**Key Features**:
- InfluxDB integration
- Real-time dashboards
- Historical reporting
- Cache performance analysis

### 4. API Gateway (Node.js)
**Location**: `api-gateway/src/app.js`
**Port**: 4000

Request routing and rate limiting:
- Service proxy
- Authentication
- Rate limiting
- CORS handling

### 5. Load Balancer (Nginx)
**Location**: `nginx/nginx.conf`
**Port**: 80/443

Traffic distribution and SSL termination:
- Geographic routing
- Health checks
- SSL/TLS termination
- Static content serving

## API Documentation

### Content Management

#### Upload Files
```bash
POST /api/upload
Content-Type: multipart/form-data

curl -X POST \
  -F "files=@image1.jpg" \
  -F "files=@style.css" \
  http://localhost:4000/api/upload
```

#### List Files
```bash
GET /api/files?page=1&limit=20

curl http://localhost:4000/api/files
```

#### Get Content
```bash
GET /content/{filename}

curl http://localhost/content/image1-123456.jpg
```

### Analytics Endpoints

#### Real-time Metrics
```bash
GET /api/analytics/metrics/realtime

curl http://localhost:4000/api/analytics/metrics/realtime
```

#### Time Series Data
```bash
GET /api/analytics/metrics/timeseries?hours=24

curl http://localhost:4000/api/analytics/metrics/timeseries?hours=48
```

#### Geographic Distribution
```bash
GET /api/analytics/metrics/geography

curl http://localhost:4000/api/analytics/metrics/geography
```

#### Top Content
```bash
GET /api/analytics/content/top?limit=10

curl http://localhost:4000/api/analytics/content/top?limit=20
```

#### Server Performance
```bash
GET /api/analytics/servers/performance

curl http://localhost:4000/api/analytics/servers/performance
```

#### Daily Reports
```bash
GET /api/analytics/reports/daily/{date}

curl http://localhost:4000/api/analytics/reports/daily/2025-07-26
```

### Health Checks

All services provide health check endpoints:
```bash
# System health
curl http://localhost/health

# Individual services
curl http://localhost:3000/health  # Origin Server
curl http://localhost:4000/health  # API Gateway
curl http://localhost:5000/health  # Analytics
curl http://localhost:8080/health  # Edge Server US
curl http://localhost:8081/health  # Edge Server EU
```

## Performance Testing

The system includes comprehensive performance testing tools:

### Run All Tests
```bash
./scripts/test.sh
```

### Individual Test Categories

#### Cache Performance
```bash
# Tests cache hit/miss rates
curl http://localhost/content/test-file.jpg  # First request (MISS)
curl http://localhost/content/test-file.jpg  # Second request (HIT)
```

#### Load Testing
```bash
# Apache Bench (if installed)
ab -n 1000 -c 50 http://localhost/content/test-file.jpg

# Curl-based testing
for i in {1..100}; do
  curl -w "@curl-format.txt" -o /dev/null -s http://localhost/content/test-file.jpg
done
```

#### Geographic Performance
```bash
# Test different edge servers
curl -w "%{time_total}\n" http://localhost:8080/content/test-file.jpg
curl -w "%{time_total}\n" http://localhost:8081/content/test-file.jpg
```

### Test Results

After running tests, results are available in `./performance-results/`:
- `performance_report.html` - Complete HTML report
- `cache_performance.txt` - Cache metrics
- `load_test.txt` - Load testing results
- `system_health.txt` - Service status

## Monitoring & Analytics

### Real-time Dashboard

Access analytics through the API or build custom dashboards:

```javascript
// Example: Real-time metrics
fetch('/api/analytics/metrics/realtime')
  .then(response => response.json())
  .then(data => {
    console.log(`Cache Hit Rate: ${data.cache_hit_rate}%`);
    console.log(`Total Requests: ${data.total_requests}`);
    console.log(`Bytes Served: ${data.bytes_served}`);
  });
```

### Key Metrics to Monitor

1. **Cache Performance**
   - Hit/Miss ratios
   - Average response times
   - Cache efficiency

2. **Geographic Distribution**
   - Request origins
   - Regional performance
   - Traffic patterns

3. **Server Health**
   - CPU and memory usage
   - Response times
   - Error rates

4. **Content Analysis**
   - Most requested files
   - File type distribution
   - Bandwidth usage

### Setting Up Alerts

Monitor critical metrics using the health endpoints:

```bash
#!/bin/bash
# Simple monitoring script
while true; do
  if ! curl -f http://localhost/health > /dev/null 2>&1; then
    echo "ALERT: CDN system is down!"
    # Send notification
  fi
  sleep 60
done
```

## Troubleshooting

### Common Issues and Solutions

#### Services Won't Start
```bash
# Check Docker daemon
sudo systemctl status docker

# Check available resources
docker system df
docker system prune -f  # Clean up if needed

# Restart services individually
docker-compose restart origin-server
docker-compose restart edge-server-us
```

#### Database Connection Issues
```bash
# Check PostgreSQL logs
docker-compose logs postgres

# Test database connection
docker-compose exec postgres psql -U cdn_user -d cdn_db -c "SELECT 1;"

# Reset database if needed
docker-compose down postgres
docker volume rm cdn-system_postgres_data
docker-compose up -d postgres
```

#### Cache Problems
```bash
# Check Redis status
docker-compose exec redis-cluster redis-cli ping

# Clear all cache
docker-compose exec redis-cluster redis-cli FLUSHALL

# Monitor cache usage
docker-compose exec redis-cluster redis-cli INFO memory
```

#### High Memory Usage
```bash
# Check container resource usage
docker stats

# Reduce cache memory limits
# Edit docker-compose.yml:
command: redis-server --maxmemory 256mb --maxmemory-policy allkeys-lru
```

#### SSL Certificate Issues
```bash
# Check certificate validity
openssl x509 -in nginx/ssl/cdn.crt -text -noout

# Regenerate certificates
./scripts/setup.sh  # Recreates certificates
```

### Log Analysis
```bash
# View service logs
docker-compose logs -f origin-server
docker-compose logs -f edge-server-us
docker-compose logs -f analytics-service

# Search for errors
docker-compose logs | grep -i error
docker-compose logs | grep -i "cache miss"
```

### Performance Tuning

#### Optimize Cache Settings
```yaml
# In docker-compose.yml for Redis
command: redis-server --maxmemory 1g --maxmemory-policy allkeys-lru --tcp-keepalive 300
```

#### Adjust Nginx Configuration
```nginx
# In nginx/nginx.conf
worker_processes auto;
worker_connections 2048;
keepalive_timeout 120;
client_max_body_size 200M;
```

#### Scale Edge Servers
```bash
# Add more edge servers
docker-compose up -d --scale edge-server-us=3
```

## Learning Resources

### CDN Fundamentals
- [CloudFlare CDN Learning Center](https://www.cloudflare.com/learning/cdn/)
- [AWS CDN Documentation](https://docs.aws.amazon.com/cloudfront/)
- [MDN Web Docs - HTTP Caching](https://developer.mozilla.org/en-US/docs/Web/HTTP/Caching)

### Technology Deep Dives

#### Docker & Containerization
- [Docker Official Tutorial](https://docs.docker.com/get-started/)
- [Docker Compose Documentation](https://docs.docker.com/compose/)
- [Container Best Practices](https://docs.docker.com/develop/dev-best-practices/)

#### Node.js Development
- [Node.js Official Guide](https://nodejs.org/en/docs/guides/)
- [Express.js Documentation](https://expressjs.com/)
- [Node.js Performance Best Practices](https://nodejs.org/en/docs/guides/simple-profiling/)

#### Go Programming
- [Go by Example](https://gobyexample.com/)
- [Effective Go](https://golang.org/doc/effective_go)
- [Go Web Programming](https://github.com/astaxie/build-web-application-with-golang)

#### Python & FastAPI
- [FastAPI Documentation](https://fastapi.tiangolo.com/)
- [Python Async Programming](https://docs.python.org/3/library/asyncio.html)

#### Database Technologies
- [PostgreSQL Documentation](https://www.postgresql.org/docs/)
- [Redis Documentation](https://redis.io/documentation)
- [InfluxDB Documentation](https://docs.influxdata.com/)

#### Web Performance
- [Web Performance Optimization](https://developers.google.com/web/fundamentals/performance)
- [HTTP/2 Explained](https://http2-explained.haxx.se/)
- [Nginx Performance Tuning](https://nginx.org/en/docs/http/ngx_http_core_module.html)

### Advanced Topics

#### Microservices Architecture
- [Microservices Patterns](https://microservices.io/)
- [Service Mesh Introduction](https://istio.io/latest/docs/concepts/what-is-istio/)
- [API Gateway Patterns](https://microservices.io/patterns/apigateway.html)

#### Observability & Monitoring
- [Prometheus Documentation](https://prometheus.io/docs/)
- [Grafana Documentation](https://grafana.com/docs/)
- [OpenTelemetry](https://opentelemetry.io/docs/)

#### DevOps & Deployment
- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [CI/CD Best Practices](https://docs.gitlab.com/ee/ci/)
- [Infrastructure as Code](https://www.terraform.io/intro/index.html)

## Next Steps

After getting the system running, consider these enhancements:

### Performance Optimizations
1. Implement HTTP/2 Push for critical resources
2. Add Image Optimization with automatic format conversion
3. Implement Brotli Compression for better compression ratios
4. Add CDN Purge API for selective cache invalidation

### Scaling Improvements
1. Kubernetes Deployment for production orchestration
2. Multi-Region Deployment across cloud providers
3. Auto-scaling based on traffic patterns
4. Database Sharding for large-scale operations

### Advanced Features
1. Machine Learning for predictive caching
2. Real-time Streaming for live content
3. Edge Computing capabilities
4. Advanced Security with WAF integration

### Monitoring Enhancements
1. Custom Grafana Dashboards
2. Alerting Rules for operational issues
3. Log Aggregation with ELK stack
4. Distributed Tracing for request flows

---

This CDN system provides a solid foundation for learning distributed systems, caching strategies, and modern web performance optimization. Start with the basic setup and gradually explore the advanced features as you become more comfortable with the architecture.

Happy learning! 🎉