// Fixed edge-server/main.go
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"context"

	"github.com/go-redis/redis/v8"
	"github.com/gorilla/mux"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
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
	RequestsTotal    prometheus.Counter
	CacheHits        prometheus.Counter
	CacheMisses      prometheus.Counter
	ResponseDuration prometheus.Histogram
	OriginRequests   prometheus.Counter
}

type Cache struct {
	redis *redis.Client
	ctx   context.Context
}

type CacheItem struct {
	Content    []byte            `json:"content"`
	Headers    map[string]string `json:"headers"`
	StatusCode int               `json:"status_code"`
	Timestamp  int64             `json:"timestamp"`
	TTL        int64             `json:"ttl"`
}

type AnalyticsData struct {
	Timestamp    int64  `json:"timestamp"`
	Method       string `json:"method"`
	Path         string `json:"path"`
	CacheStatus  string `json:"cache_status"`
	EdgeServer   string `json:"edge_server"`
	EdgeRegion   string `json:"edge_region"`
	ResponseTime int64  `json:"response_time"`
	BytesSent    int    `json:"bytes_sent"`
	ClientIP     string `json:"client_ip"`
	UserAgent    string `json:"user_agent"`
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
			Name:        "edge_requests_total",
			Help:        "Total number of requests handled by edge server",
			ConstLabels: prometheus.Labels{"edge_id": edgeID, "region": region},
		}),
		CacheHits: prometheus.NewCounter(prometheus.CounterOpts{
			Name:        "edge_cache_hits_total",
			Help:        "Total number of cache hits",
			ConstLabels: prometheus.Labels{"edge_id": edgeID, "region": region},
		}),
		CacheMisses: prometheus.NewCounter(prometheus.CounterOpts{
			Name:        "edge_cache_misses_total",
			Help:        "Total number of cache misses",
			ConstLabels: prometheus.Labels{"edge_id": edgeID, "region": region},
		}),
		ResponseDuration: prometheus.NewHistogram(prometheus.HistogramOpts{
			Name:        "edge_response_duration_seconds",
			Help:        "Response duration in seconds",
			ConstLabels: prometheus.Labels{"edge_id": edgeID, "region": region},
		}),
		OriginRequests: prometheus.NewCounter(prometheus.CounterOpts{
			Name:        "edge_origin_requests_total",
			Help:        "Total number of requests to origin server",
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

// Analytics tracking function
func (es *EdgeServer) trackAnalytics(r *http.Request, cacheStatus string, responseTime time.Duration, bytesSent int) {
	analyticsData := AnalyticsData{
		Timestamp:    time.Now().Unix(),
		Method:       r.Method,
		Path:         r.URL.Path,
		CacheStatus:  cacheStatus,
		EdgeServer:   es.ID,
		EdgeRegion:   es.Region,
		ResponseTime: responseTime.Milliseconds(),
		BytesSent:    bytesSent,
		ClientIP:     r.RemoteAddr,
		UserAgent:    r.Header.Get("User-Agent"),
	}

	// Send to analytics service asynchronously
	go func() {
		jsonData, err := json.Marshal(analyticsData)
		if err != nil {
			log.Printf("Failed to marshal analytics data: %v", err)
			return
		}

		resp, err := http.Post("http://analytics-service:5000/track", "application/json", bytes.NewBuffer(jsonData))
		if err != nil {
			log.Printf("Failed to send analytics: %v", err)
			return
		}
		defer resp.Body.Close()

		log.Printf("[%s] Analytics sent: %s - %s", es.ID, cacheStatus, r.URL.Path)
	}()
}

// FIXED: Complete handleContent function with proper cache logic
func (es *EdgeServer) handleContent(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	defer func() {
		es.Metrics.ResponseDuration.Observe(time.Since(start).Seconds())
	}()

	es.Metrics.RequestsTotal.Inc()

	// Generate cache key - clean the path for consistent caching
	cleanPath := strings.TrimPrefix(r.URL.Path, "/")
	cacheKey := fmt.Sprintf("content:%s:%s", r.Method, cleanPath)

	// Try to get from cache first
	cached, err := es.Cache.Get(cacheKey)
	if err == nil && cached != nil {
		es.Metrics.CacheHits.Inc()

		// Set headers from cache
		for key, value := range cached.Headers {
			w.Header().Set(key, value)
		}
		w.Header().Set("X-Cache", "HIT")
		w.Header().Set("X-Edge-Server", es.ID)
		w.Header().Set("X-Edge-Region", es.Region)
		w.WriteHeader(cached.StatusCode)
		w.Write(cached.Content)

		// Track cache HIT analytics
		es.trackAnalytics(r, "HIT", time.Since(start), len(cached.Content))

		log.Printf("[%s] Cache HIT for %s", es.ID, r.URL.Path)
		return
	}

	// Cache MISS - fetch from origin
	es.Metrics.CacheMisses.Inc()

	// Fetch from origin server
	originResp, err := es.fetchFromOrigin(r)
	if err != nil {
		log.Printf("[%s] Error fetching from origin: %v", es.ID, err)
		http.Error(w, "Failed to fetch from origin", http.StatusBadGateway)
		es.trackAnalytics(r, "ERROR", time.Since(start), 0)
		return
	}
	defer originResp.Body.Close()

	es.Metrics.OriginRequests.Inc()

	// Read response body
	body, err := io.ReadAll(originResp.Body)
	if err != nil {
		log.Printf("[%s] Error reading origin response: %v", es.ID, err)
		http.Error(w, "Failed to read origin response", http.StatusInternalServerError)
		es.trackAnalytics(r, "ERROR", time.Since(start), 0)
		return
	}

	// Prepare cache item with headers
	headers := make(map[string]string)
	for key, values := range originResp.Header {
		if len(values) > 0 {
			headers[key] = values[0]
		}
	}

	// Create cache item
	cacheItem := &CacheItem{
		Content:    body,
		Headers:    headers,
		StatusCode: originResp.StatusCode,
		Timestamp:  time.Now().Unix(),
		TTL:        es.determineTTL(originResp.Header.Get("Content-Type"), r.URL.Path),
	}

	// Cache the response if status is successful
	if originResp.StatusCode >= 200 && originResp.StatusCode < 400 {
		if err := es.Cache.Set(cacheKey, cacheItem, time.Duration(cacheItem.TTL)*time.Second); err != nil {
			log.Printf("[%s] Failed to cache response: %v", es.ID, err)
		}
	}

	// Send response to client
	for key, value := range headers {
		w.Header().Set(key, value)
	}
	w.Header().Set("X-Cache", "MISS")
	w.Header().Set("X-Edge-Server", es.ID)
	w.Header().Set("X-Edge-Region", es.Region)
	w.WriteHeader(originResp.StatusCode)
	w.Write(body)

	// Track cache MISS analytics
	es.trackAnalytics(r, "MISS", time.Since(start), len(body))

	log.Printf("[%s] Cache MISS for %s - Status: %d, Size: %d bytes",
		es.ID, r.URL.Path, originResp.StatusCode, len(body))
}

// Helper function to determine TTL based on content type and path
func (es *EdgeServer) determineTTL(contentType, path string) int64 {
	// Default TTL values in seconds
	switch {
	case strings.Contains(contentType, "image/"):
		return 86400 * 30 // 30 days for images
	case strings.Contains(contentType, "text/css"),
		strings.Contains(contentType, "application/javascript"):
		return 86400 // 1 day for CSS/JS
	case strings.Contains(contentType, "text/html"):
		return 3600 // 1 hour for HTML
	case strings.Contains(contentType, "application/json"):
		return 300 // 5 minutes for JSON API responses
	case strings.HasSuffix(path, ".pdf"):
		return 86400 * 7 // 1 week for PDFs
	case strings.Contains(contentType, "video/"):
		return 86400 * 90 // 90 days for videos
	default:
		return 3600 // 1 hour default
	}
}

func (es *EdgeServer) fetchFromOrigin(r *http.Request) (*http.Response, error) {
	client := &http.Client{
		Timeout: 30 * time.Second,
	}

	// Create new request to origin
	originReq, err := http.NewRequest(r.Method, es.OriginURL+r.URL.Path, r.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to create origin request: %v", err)
	}

	// Copy headers from original request
	for key, values := range r.Header {
		for _, value := range values {
			originReq.Header.Add(key, value)
		}
	}

	// Add edge server identification headers
	originReq.Header.Set("X-Edge-Server", es.ID)
	originReq.Header.Set("X-Edge-Region", es.Region)
	originReq.Header.Set("X-Forwarded-For", r.RemoteAddr)

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

	// Check origin server connectivity
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Get(es.OriginURL + "/health")
	if err != nil || resp.StatusCode != 200 {
		status["origin"] = "unhealthy"
		status["status"] = "degraded"
	} else {
		status["origin"] = "healthy"
		resp.Body.Close()
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
	log.Printf("Origin URL: %s", server.OriginURL)
	log.Printf("Redis URL: %s", getEnv("REDIS_URL", "redis://localhost:6379"))

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
