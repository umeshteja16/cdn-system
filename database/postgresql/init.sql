-- database/postgresql/init.sql
-- CDN System Database Initialization

-- Create extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";

-- Files table for storing uploaded file metadata
CREATE TABLE IF NOT EXISTS files (
    id SERIAL PRIMARY KEY,
    filename VARCHAR(255) NOT NULL UNIQUE,
    original_name VARCHAR(255) NOT NULL,
    mimetype VARCHAR(100) NOT NULL,
    size BIGINT NOT NULL,
    path TEXT NOT NULL,
    uploaded_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    metadata JSONB DEFAULT '{}',
    
    -- Indexes
    CONSTRAINT files_filename_unique UNIQUE (filename),
    CONSTRAINT files_size_positive CHECK (size > 0)
);

-- Edge servers table for tracking CDN nodes
CREATE TABLE IF NOT EXISTS edge_servers (
    id VARCHAR(50) PRIMARY KEY,
    region VARCHAR(50) NOT NULL,
    status VARCHAR(20) DEFAULT 'active',
    last_heartbeat TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Request logs table for analytics
CREATE TABLE IF NOT EXISTS request_logs (
    id BIGSERIAL PRIMARY KEY,
    file_id INTEGER REFERENCES files(id) ON DELETE SET NULL,
    edge_server_id VARCHAR(50) REFERENCES edge_servers(id) ON DELETE SET NULL,
    client_ip INET,
    user_agent TEXT,
    method VARCHAR(10) NOT NULL,
    path TEXT NOT NULL,
    status_code INTEGER NOT NULL,
    cache_status VARCHAR(10) DEFAULT 'MISS',
    response_time INTEGER, -- in milliseconds
    bytes_sent BIGINT DEFAULT 0,
    timestamp TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    
    -- Indexes for analytics queries
    CONSTRAINT request_logs_status_code_valid CHECK (status_code >= 100 AND status_code < 600),
    CONSTRAINT request_logs_cache_status_valid CHECK (cache_status IN ('HIT', 'MISS', 'STALE', 'BYPASS'))
);

-- User sessions table (optional)
CREATE TABLE IF NOT EXISTS user_sessions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    session_token VARCHAR(255) NOT NULL UNIQUE,
    client_ip INET,
    user_agent TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMP WITH TIME ZONE DEFAULT (CURRENT_TIMESTAMP + INTERVAL '24 hours'),
    metadata JSONB DEFAULT '{}'
);

-- Create indexes for better performance
CREATE INDEX IF NOT EXISTS idx_files_uploaded_at ON files(uploaded_at DESC);
CREATE INDEX IF NOT EXISTS idx_files_mimetype ON files(mimetype);
CREATE INDEX IF NOT EXISTS idx_files_size ON files(size);

CREATE INDEX IF NOT EXISTS idx_edge_servers_region ON edge_servers(region);
CREATE INDEX IF NOT EXISTS idx_edge_servers_status ON edge_servers(status);
CREATE INDEX IF NOT EXISTS idx_edge_servers_heartbeat ON edge_servers(last_heartbeat DESC);

CREATE INDEX IF NOT EXISTS idx_request_logs_timestamp ON request_logs(timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_request_logs_file_id ON request_logs(file_id);
CREATE INDEX IF NOT EXISTS idx_request_logs_edge_server ON request_logs(edge_server_id);
CREATE INDEX IF NOT EXISTS idx_request_logs_client_ip ON request_logs(client_ip);
CREATE INDEX IF NOT EXISTS idx_request_logs_status_code ON request_logs(status_code);
CREATE INDEX IF NOT EXISTS idx_request_logs_cache_status ON request_logs(cache_status);
CREATE INDEX IF NOT EXISTS idx_request_logs_composite ON request_logs(timestamp DESC, cache_status, status_code);

CREATE INDEX IF NOT EXISTS idx_user_sessions_token ON user_sessions(session_token);
CREATE INDEX IF NOT EXISTS idx_user_sessions_expires ON user_sessions(expires_at);

-- Insert default edge servers
INSERT INTO edge_servers (id, region, status) VALUES 
    ('edge-us-east-1', 'us-east-1', 'active'),
    ('edge-eu-west-1', 'eu-west-1', 'active')
ON CONFLICT (id) DO NOTHING;

-- Create updated_at trigger function
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ language 'plpgsql';

-- Apply trigger to files table
DROP TRIGGER IF EXISTS update_files_updated_at ON files;
CREATE TRIGGER update_files_updated_at 
    BEFORE UPDATE ON files 
    FOR EACH ROW 
    EXECUTE FUNCTION update_updated_at_column();

-- Create some useful views
CREATE OR REPLACE VIEW file_stats AS
SELECT 
    COUNT(*) as total_files,
    SUM(size) as total_size,
    AVG(size) as avg_size,
    COUNT(CASE WHEN mimetype LIKE 'image/%' THEN 1 END) as image_files,
    COUNT(CASE WHEN mimetype LIKE 'video/%' THEN 1 END) as video_files,
    COUNT(CASE WHEN mimetype LIKE 'text/%' THEN 1 END) as text_files
FROM files;

CREATE OR REPLACE VIEW request_summary AS
SELECT 
    DATE(timestamp) as date,
    COUNT(*) as total_requests,
    COUNT(CASE WHEN cache_status = 'HIT' THEN 1 END) as cache_hits,
    COUNT(CASE WHEN cache_status = 'MISS' THEN 1 END) as cache_misses,
    ROUND(
        (COUNT(CASE WHEN cache_status = 'HIT' THEN 1 END)::numeric / 
         COUNT(*)::numeric) * 100, 2
    ) as cache_hit_rate,
    SUM(bytes_sent) as total_bytes,
    AVG(response_time) as avg_response_time
FROM request_logs 
GROUP BY DATE(timestamp)
ORDER BY date DESC;

-- Grant permissions
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO cdn_user;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO cdn_user;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO cdn_user;

-- Display initialization summary
DO $$
BEGIN
    RAISE NOTICE 'CDN Database initialized successfully!';
    RAISE NOTICE 'Tables created: files, edge_servers, request_logs, user_sessions';
    RAISE NOTICE 'Views created: file_stats, request_summary';
    RAISE NOTICE 'Ready for CDN operations.';
END $$;