-- database/postgresql/init.sql
-- CDN Database Schema

-- Create extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Files table for content metadata
CREATE TABLE IF NOT EXISTS files (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    filename VARCHAR(255) NOT NULL UNIQUE,
    original_name VARCHAR(255) NOT NULL,
    mimetype VARCHAR(100) NOT NULL,
    size BIGINT NOT NULL,
    path TEXT NOT NULL,
    checksum VARCHAR(64),
    uploaded_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    created_by UUID,
    tags TEXT[],
    metadata JSONB
);

-- Index for faster queries
CREATE INDEX IF NOT EXISTS idx_files_filename ON files(filename);
CREATE INDEX IF NOT EXISTS idx_files_mimetype ON files(mimetype);
CREATE INDEX IF NOT EXISTS idx_files_uploaded_at ON files(uploaded_at DESC);
CREATE INDEX IF NOT EXISTS idx_files_size ON files(size);
CREATE INDEX IF NOT EXISTS idx_files_tags ON files USING GIN(tags);
CREATE INDEX IF NOT EXISTS idx_files_metadata ON files USING GIN(metadata);

-- Users table for authentication
CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    username VARCHAR(50) NOT NULL UNIQUE,
    email VARCHAR(255) NOT NULL UNIQUE,
    password_hash VARCHAR(255) NOT NULL,
    role VARCHAR(20) DEFAULT 'user' CHECK (role IN ('admin', 'user', 'readonly')),
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    last_login TIMESTAMP WITH TIME ZONE,
    api_key VARCHAR(255) UNIQUE
);

CREATE INDEX IF NOT EXISTS idx_users_username ON users(username);
CREATE INDEX IF NOT EXISTS idx_users_email ON users(email);
CREATE INDEX IF NOT EXISTS idx_users_api_key ON users(api_key);

-- API Keys table
CREATE TABLE IF NOT EXISTS api_keys (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    key_hash VARCHAR(255) NOT NULL UNIQUE,
    name VARCHAR(100) NOT NULL,
    permissions JSONB DEFAULT '{}',
    expires_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    last_used TIMESTAMP WITH TIME ZONE,
    is_active BOOLEAN DEFAULT true
);

CREATE INDEX IF NOT EXISTS idx_api_keys_user_id ON api_keys(user_id);
CREATE INDEX IF NOT EXISTS idx_api_keys_hash ON api_keys(key_hash);

-- Edge servers registration table
CREATE TABLE IF NOT EXISTS edge_servers (
    id VARCHAR(50) PRIMARY KEY,
    region VARCHAR(50) NOT NULL,
    ip_address INET NOT NULL,
    port INTEGER DEFAULT 8080,
    status VARCHAR(20) DEFAULT 'active' CHECK (status IN ('active', 'inactive', 'maintenance')),
    last_heartbeat TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    metadata JSONB DEFAULT '{}'
);

CREATE INDEX IF NOT EXISTS idx_edge_servers_region ON edge_servers(region);
CREATE INDEX IF NOT EXISTS idx_edge_servers_status ON edge_servers(status);
CREATE INDEX IF NOT EXISTS idx_edge_servers_heartbeat ON edge_servers(last_heartbeat DESC);

-- Cache invalidation requests
CREATE TABLE IF NOT EXISTS cache_invalidations (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    pattern VARCHAR(255) NOT NULL,
    reason TEXT,
    requested_by UUID REFERENCES users(id),
    requested_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    completed_at TIMESTAMP WITH TIME ZONE,
    status VARCHAR(20) DEFAULT 'pending' CHECK (status IN ('pending', 'processing', 'completed', 'failed')),
    affected_files INTEGER DEFAULT 0,
    error_message TEXT
);

CREATE INDEX IF NOT EXISTS idx_cache_invalidations_status ON cache_invalidations(status);
CREATE INDEX IF NOT EXISTS idx_cache_invalidations_requested_at ON cache_invalidations(requested_at DESC);

-- Analytics summary table (for quick queries)
CREATE TABLE IF NOT EXISTS analytics_daily (
    date DATE PRIMARY KEY,
    total_requests BIGINT DEFAULT 0,
    total_bytes BIGINT DEFAULT 0,
    cache_hits BIGINT DEFAULT 0,
    cache_misses BIGINT DEFAULT 0,
    unique_ips INTEGER DEFAULT 0,
    avg_response_time NUMERIC(10,2) DEFAULT 0,
    top_files JSONB DEFAULT '[]',
    top_regions JSONB DEFAULT '[]',
    status_codes JSONB DEFAULT '{}',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_analytics_daily_date ON analytics_daily(date DESC);

-- Content delivery logs (for detailed analytics)
CREATE TABLE IF NOT EXISTS request_logs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    timestamp TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    file_id UUID REFERENCES files(id),
    edge_server_id VARCHAR(50) REFERENCES edge_servers(id),
    client_ip INET NOT NULL,
    user_agent TEXT,
    referer TEXT,
    method VARCHAR(10) NOT NULL,
    status_code INTEGER NOT NULL,
    bytes_sent BIGINT DEFAULT 0,
    response_time INTEGER DEFAULT 0, -- milliseconds
    cache_status VARCHAR(10) CHECK (cache_status IN ('HIT', 'MISS', 'BYPASS')),
    region VARCHAR(50),
    country_code VARCHAR(2)
);

-- Partition by month for better performance
CREATE INDEX IF NOT EXISTS idx_request_logs_timestamp ON request_logs(timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_request_logs_file_id ON request_logs(file_id);
CREATE INDEX IF NOT EXISTS idx_request_logs_edge_server ON request_logs(edge_server_id);
CREATE INDEX IF NOT EXISTS idx_request_logs_client_ip ON request_logs(client_ip);

-- File versions table (for content versioning)
CREATE TABLE IF NOT EXISTS file_versions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    file_id UUID REFERENCES files(id) ON DELETE CASCADE,
    version_number INTEGER NOT NULL,
    filename VARCHAR(255) NOT NULL,
    size BIGINT NOT NULL,
    checksum VARCHAR(64) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    created_by UUID REFERENCES users(id),
    is_current BOOLEAN DEFAULT false,
    change_description TEXT,
    
    UNIQUE(file_id, version_number)
);

CREATE INDEX IF NOT EXISTS idx_file_versions_file_id ON file_versions(file_id);
CREATE INDEX IF NOT EXISTS idx_file_versions_current ON file_versions(file_id, is_current) WHERE is_current = true;

-- Configuration settings table
CREATE TABLE IF NOT EXISTS settings (
    key VARCHAR(100) PRIMARY KEY,
    value JSONB NOT NULL,
    description TEXT,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_by UUID REFERENCES users(id)
);

-- Insert default settings
INSERT INTO settings (key, value, description) VALUES 
('cache_ttl_images', '2592000', 'Cache TTL for images in seconds (default: 30 days)'),
('cache_ttl_css_js', '86400', 'Cache TTL for CSS/JS files in seconds (default: 1 day)'),
('cache_ttl_html', '3600', 'Cache TTL for HTML files in seconds (default: 1 hour)'),
('max_file_size', '104857600', 'Maximum file size in bytes (default: 100MB)'),
('allowed_origins', '["*"]', 'Allowed origins for CORS'),
('rate_limit_requests', '1000', 'Rate limit: requests per hour per IP'),
('enable_compression', 'true', 'Enable gzip compression')
ON CONFLICT (key) DO NOTHING;

-- Functions for analytics
CREATE OR REPLACE FUNCTION update_analytics_daily()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO analytics_daily (date, total_requests, total_bytes)
    VALUES (CURRENT_DATE, 1, COALESCE(NEW.bytes_sent, 0))
    ON CONFLICT (date) DO UPDATE SET
        total_requests = analytics_daily.total_requests + 1,
        total_bytes = analytics_daily.total_bytes + COALESCE(NEW.bytes_sent, 0),
        cache_hits = analytics_daily.cache_hits + CASE WHEN NEW.cache_status = 'HIT' THEN 1 ELSE 0 END,
        cache_misses = analytics_daily.cache_misses + CASE WHEN NEW.cache_status = 'MISS' THEN 1 ELSE 0 END,
        updated_at = NOW();
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger for automatic analytics updates
CREATE TRIGGER update_analytics_daily_trigger
    AFTER INSERT ON request_logs
    FOR EACH ROW
    EXECUTE FUNCTION update_analytics_daily();

-- Function to clean old logs (retention policy)
CREATE OR REPLACE FUNCTION cleanup_old_logs()
RETURNS INTEGER AS $$
DECLARE
    deleted_count INTEGER;
BEGIN
    DELETE FROM request_logs 
    WHERE timestamp < NOW() - INTERVAL '90 days';
    
    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN deleted_count;
END;
$$ LANGUAGE plpgsql;

-- Function to update file versions
CREATE OR REPLACE FUNCTION update_file_version()
RETURNS TRIGGER AS $$
BEGIN
    -- Set previous version as not current
    UPDATE file_versions 
    SET is_current = false 
    WHERE file_id = NEW.id;
    
    -- Insert new version
    INSERT INTO file_versions (file_id, version_number, filename, size, checksum, is_current, created_by)
    VALUES (
        NEW.id,
        COALESCE((SELECT MAX(version_number) + 1 FROM file_versions WHERE file_id = NEW.id), 1),
        NEW.filename,
        NEW.size,
        NEW.checksum,
        true,
        NEW.created_by
    );
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger for file versioning
CREATE TRIGGER file_version_trigger
    AFTER INSERT OR UPDATE ON files
    FOR EACH ROW
    EXECUTE FUNCTION update_file_version();

-- Create default admin user (password: admin123)
INSERT INTO users (username, email, password_hash, role) VALUES 
('admin', 'admin@cdn.local', crypt('admin123', gen_salt('bf')), 'admin')
ON CONFLICT (username) DO NOTHING;

-- Create sample edge servers
INSERT INTO edge_servers (id, region, ip_address, port) VALUES 
('edge-1', 'us-east-1', '10.0.1.10', 8080),
('edge-2', 'us-west-1', '10.0.2.10', 8080),
('edge-3', 'eu-west-1', '10.0.3.10', 8080)
ON CONFLICT (id) DO NOTHING;

-- Views for common queries
CREATE OR REPLACE VIEW file_stats AS
SELECT 
    f.id,
    f.filename,
    f.original_name,
    f.mimetype,
    f.size,
    f.uploaded_at,
    COALESCE(rl.request_count, 0) as total_requests,
    COALESCE(rl.total_bytes_served, 0) as total_bytes_served,
    COALESCE(rl.last_accessed, NULL) as last_accessed
FROM files f
LEFT JOIN (
    SELECT 
        file_id,
        COUNT(*) as request_count,
        SUM(bytes_sent) as total_bytes_served,
        MAX(timestamp) as last_accessed
    FROM request_logs
    WHERE timestamp > NOW() - INTERVAL '30 days'
    GROUP BY file_id
) rl ON f.id = rl.file_id;

CREATE OR REPLACE VIEW daily_analytics AS
SELECT 
    date,
    total_requests,
    total_bytes,
    cache_hits,
    cache_misses,
    CASE 
        WHEN total_requests > 0 
        THEN ROUND((cache_hits::numeric / total_requests::numeric) * 100, 2)
        ELSE 0 
    END as cache_hit_rate,
    unique_ips,
    avg_response_time
FROM analytics_daily
ORDER BY date DESC;

-- Indexes for performance
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_request_logs_timestamp_partial 
ON request_logs(timestamp) WHERE timestamp > NOW() - INTERVAL '7 days';

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_request_logs_composite 
ON request_logs(file_id, timestamp, cache_status);

-- Stored procedures for common operations
CREATE OR REPLACE FUNCTION get_popular_files(days_back INTEGER DEFAULT 7, limit_count INTEGER DEFAULT 10)
RETURNS TABLE(
    file_id UUID,
    filename VARCHAR,
    request_count BIGINT,
    total_bytes BIGINT,
    cache_hit_rate NUMERIC
) AS $
BEGIN
    RETURN QUERY
    SELECT 
        f.id,
        f.filename,
        COUNT(rl.id) as request_count,
        SUM(rl.bytes_sent) as total_bytes,
        ROUND(
            (COUNT(CASE WHEN rl.cache_status = 'HIT' THEN 1 END)::numeric / 
             COUNT(rl.id)::numeric) * 100, 2
        ) as cache_hit_rate
    FROM files f
    JOIN request_logs rl ON f.id = rl.file_id
    WHERE rl.timestamp > NOW() - (days_back || ' days')::INTERVAL
    GROUP BY f.id, f.filename
    ORDER BY request_count DESC
    LIMIT limit_count;
END;
$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION get_edge_server_performance(server_id VARCHAR DEFAULT NULL)
RETURNS TABLE(
    id VARCHAR,
    region VARCHAR,
    total_requests BIGINT,
    avg_response_time NUMERIC,
    cache_hit_rate NUMERIC,
    last_heartbeat TIMESTAMP WITH TIME ZONE
) AS $
BEGIN
    RETURN QUERY
    SELECT 
        es.id,
        es.region,
        COALESCE(rl.request_count, 0) as total_requests,
        COALESCE(rl.avg_response_time, 0) as avg_response_time,
        COALESCE(rl.cache_hit_rate, 0) as cache_hit_rate,
        es.last_heartbeat
    FROM edge_servers es
    LEFT JOIN (
        SELECT 
            edge_server_id,
            COUNT(*) as request_count,
            AVG(response_time) as avg_response_time,
            ROUND(
                (COUNT(CASE WHEN cache_status = 'HIT' THEN 1 END)::numeric / 
                 COUNT(*)::numeric) * 100, 2
            ) as cache_hit_rate
        FROM request_logs
        WHERE timestamp > NOW() - INTERVAL '24 hours'
        GROUP BY edge_server_id
    ) rl ON es.id = rl.edge_server_id
    WHERE (server_id IS NULL OR es.id = server_id)
    ORDER BY total_requests DESC;
END;
$ LANGUAGE plpgsql;

COMMIT;