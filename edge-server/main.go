// edge-server/main.go
package main

import (
    "encoding/json"
    "fmt"
    "io"
    "log"
    "net/http"
    "os"
    "strconv"
    "time"

    "github.com/gorilla/mux"
    "github.com/prometheus/client_golang/prometheus"
    "github.com/prometheus/client_golang/prometheus/promhttp"
    "github.com/go-redis/redis/v8"
    "context"
)

type EdgeServer struct {
    ID          string
    Region      string
    RedisClient *redis.Client
    OriginURL   string
    Cache       *Cache
    Metrics     *Metrics
}

type Metrics struct {
    RequestsTotal     prometheus.Counter
    CacheHits         prometheus.Counter
    CacheMisses       prometheus.Counter
    ResponseDuration  prometheus.Histogram
    OriginRequests    prometheus.Counter
}

type Cache struct {
    redis  *redis.Client
    ctx    context.Context
}

type CacheItem struct {
    Content     []byte            `json:"content"`
    Headers     map[string]string `json:"headers"`
    StatusCode  int               `json:"status_code"`
    Timestamp   int64             `json:"timestamp"`
    TTL         int64             `json:"ttl"`
}

func NewEdgeServer() *EdgeServer {
    edgeID := getEnv("EDGE_ID", "edge-1")
    region := getEnv("REGION", "us-east-1")
    redisURL := getEnv("REDIS_URL", "redis://localhost:6379")
    originURL := getEnv("ORIGIN_URL", "http://localhost:3000")

    // Redis client
    opt, err := redis.ParseURL(redisURL)
    if err != nil {
        log.Fatal("Failed to parse Redis URL:", err)
    }
    
    redisClient := redis.NewClient(opt)
    
    // Test Redis connection
    ctx := context.Background()
    _, err = redisClient.Ping(ctx).Result()
    if err != nil {
        log.Fatal("Failed to connect to Redis:", err)
    }

    // Initialize metrics
    metrics := &Metrics{
        RequestsTotal: prometheus.NewCounter(prometheus.CounterOpts{
            Name: "edge_requests_total",
            Help: "Total number of requests handled by edge server",
            ConstLabels: prometheus.Labels{"edge_id": edgeID, "region": region},
        }),
        CacheHits: prometheus.NewCounter(prometheus.CounterOpts{
            Name: "edge_cache_hits_total",
            Help: "Total number of cache hits",
            ConstLabels: prometheus.Labels{"edge_id": edgeID, "region": region},
        }),
        CacheMisses: prometheus.NewCounter(prometheus.CounterOpts{
            Name: "edge_cache_misses_total",
            Help: "Total number of cache misses",
            ConstLabels: prometheus.Labels{"edge_id": edgeID, "region": region},
        }),
        ResponseDuration: prometheus.NewHistogram(prometheus.HistogramOpts{
            Name: "edge_response_duration_seconds",
            Help: "Response duration in seconds",
            ConstLabels: prometheus.Labels{"edge_id": edgeID, "region": region},
        }),
        OriginRequests: prometheus.NewCounter(prometheus.CounterOpts{
            Name: "edge_origin_requests_total",
            Help: "Total number of requests to origin server",
            ConstLabels: prometheus.Labels{"edge_id": edgeID, "region": region},
        }),
    }

    // Register metrics
    prometheus.MustRegister(metrics.RequestsTotal)
    prometheus.MustRegister(metrics.CacheHits)
    prometheus.MustRegister(metrics.CacheMisses)
    prometheus.MustRegister(metrics.ResponseDuration)
    prometheus.MustRegister(metrics.OriginRequests)

    cache := &Cache{
        redis: redisClient,
        ctx:   ctx,
    }

    return &EdgeServer{
        ID:          edgeID,
        Region:      region,
        RedisClient: redisClient,
        OriginURL:   originURL,
        Cache:       cache,
        Metrics:     metrics,
    }
}

func (es *EdgeServer) handleContent(w http.ResponseWriter, r *http.Request) {
    start := time.Now()
    defer func() {
        es.Metrics.ResponseDuration.Observe(time.Since(start).Seconds())
    }()

    es.Metrics.RequestsTotal.Inc()

    // Generate cache key
    cacheKey := fmt.Sprintf("content:%s:%s", r.Method, r.URL.Path)
    
    // Try to get from cache first
    cached, err := es.Cache.Get(cacheKey)
    if err == nil && cached != nil {
        es.Metrics.CacheHits.Inc()
        
        // Set headers
        for key, value := range cached.Headers {
            w.Header().Set(key, value)
        }
        w.Header().Set("X-Cache", "HIT")
        w.Header().Set("X-Edge-Server", es.ID)
        w.WriteHeader(cached.StatusCode)
        w.Write(cached.Content)
        return
    }

    es.Metrics.CacheMisses.Inc()
    
    // Fetch from origin
    originResp, err := es.fetchFromOrigin(r)
    if err != nil {
        http.Error(w, "Failed to fetch from origin", http.StatusBadGateway)
        return
    }
    defer originResp.Body.Close()

    es.Metrics.OriginRequests.Inc()

    // Read response body
    body, err := io.ReadAll(originResp.Body)
    if err != nil {
        http.Error(w, "Failed to read origin response", http.StatusInternalServerError)
        return
    }

    // Prepare cache item
    headers := make(map[string]string)
    for key, values := range originResp.Header {
        if len(values) > 0 {
            headers[key] = values[0]
        }
    }

    cacheItem := &CacheItem{
        Content:    body,
        Headers:    headers,
        StatusCode: originResp.StatusCode,
        Timestamp:  time.Now().Unix(),
        TTL:        3600, // 1 hour default
    }

    // Determine TTL based on content type or path
    if contentType := originResp.Header.Get("Content-Type"); contentType != "" {
        switch {
        case contains(contentType, "image/"):
            cacheItem.TTL = 86400 * 30 // 30 days for images
        case contains(contentType, "text/css"), contains(contentType, "application/javascript"):
            cacheItem.TTL = 86400 // 1 day for CSS/JS
        case contains(contentType, "text/html"):
            cacheItem.TTL = 3600 // 1 hour for HTML
        }
    }

    // Cache the response
    es.Cache.Set(cacheKey, cacheItem, time.Duration(cacheItem.TTL)*time.Second)

    // Send response
    for key, value := range headers {
        w.Header().Set(key, value)
    }
    w.Header().Set("X-Cache", "MISS")
    w.Header().Set("X-Edge-Server", es.ID)
    w.WriteHeader(originResp.StatusCode)
    w.Write(body)
}

func (es *EdgeServer) fetchFromOrigin(r *http.Request) (*http.Response, error) {
    client := &http.Client{
        Timeout: 30 * time.Second,
    }

    // Create new request to origin
    originReq, err := http.NewRequest(r.Method, es.OriginURL+r.URL.Path, r.Body)
    if err != nil {
        return nil, err
    }

    // Copy headers
    for key, values := range r.Header {
        for _, value := range values {
            originReq.Header.Add(key, value)
        }
    }

    // Add edge server identification
    originReq.Header.Set("X-Edge-Server", es.ID)
    originReq.Header.Set("X-Edge-Region", es.Region)

    return client.Do(originReq)
}

func (c *Cache) Get(key string) (*CacheItem, error) {
    data, err := c.redis.Get(c.ctx, key).Result()
    if err != nil {
        return nil, err
    }

    var item CacheItem
    if err := json.Unmarshal([]byte(data), &item); err != nil {
        return nil, err
    }

    // Check if expired
    if time.Now().Unix() > item.Timestamp+item.TTL {
        c.redis.Del(c.ctx, key)
        return nil, redis.Nil
    }

    return &item, nil
}

func (c *Cache) Set(key string, item *CacheItem, ttl time.Duration) error {
    data, err := json.Marshal(item)
    if err != nil {
        return err
    }

    return c.redis.Set(c.ctx, key, data, ttl).Err()
}

func (es *EdgeServer) handleHealth(w http.ResponseWriter, r *http.Request) {
    status := map[string]interface{}{
        "status":    "healthy",
        "edge_id":   es.ID,
        "region":    es.Region,
        "timestamp": time.Now().Unix(),
    }

    // Check Redis connectivity
    _, err := es.RedisClient.Ping(es.Cache.ctx).Result()
    if err != nil {
        status["redis"] = "unhealthy"
        status["status"] = "degraded"
    } else {
        status["redis"] = "healthy"
    }

    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(status)
}

func (es *EdgeServer) handleMetrics(w http.ResponseWriter, r *http.Request) {
    promhttp.Handler().ServeHTTP(w, r)
}

func (es *EdgeServer) corsMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        w.Header().Set("Access-Control-Allow-Origin", "*")
        w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
        w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")

        if r.Method == "OPTIONS" {
            w.WriteHeader(http.StatusOK)
            return
        }

        next.ServeHTTP(w, r)
    })
}

func (es *EdgeServer) loggingMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        start := time.Now()
        
        next.ServeHTTP(w, r)
        
        log.Printf("[%s] %s %s %s - %v",
            es.ID,
            r.Method,
            r.URL.Path,
            r.RemoteAddr,
            time.Since(start),
        )
    })
}

func main() {
    server := NewEdgeServer()

    r := mux.NewRouter()
    
    // Apply middleware
    r.Use(server.corsMiddleware)
    r.Use(server.loggingMiddleware)

    // Routes
    r.HandleFunc("/health", server.handleHealth).Methods("GET")
    r.HandleFunc("/metrics", server.handleMetrics).Methods("GET")
    r.PathPrefix("/static/").HandlerFunc(server.handleContent).Methods("GET")
    r.PathPrefix("/content/").HandlerFunc(server.handleContent).Methods("GET", "HEAD")
    r.PathPrefix("/").HandlerFunc(server.handleContent)

    port := getEnv("PORT", "8080")
    log.Printf("Edge server %s starting on port %s in region %s", server.ID, port, server.Region)
    
    srv := &http.Server{
        Handler:      r,
        Addr:         ":" + port,
        WriteTimeout: 30 * time.Second,
        ReadTimeout:  30 * time.Second,
        IdleTimeout:  120 * time.Second,
    }

    log.Fatal(srv.ListenAndServe())
}

func getEnv(key, defaultValue string) string {
    if value := os.Getenv(key); value != "" {
        return value
    }
    return defaultValue
}

func contains(s, substr string) bool {
    return len(s) >= len(substr) && (s == substr || (len(s) > len(substr) && 
        (s[:len(substr)] == substr || s[len(s)-len(substr):] == substr || 
         (len(s) > len(substr) && s[1:len(substr)+1] == substr))))
}