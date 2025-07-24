// origin-server/src/app.js
const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const morgan = require('morgan');
const multer = require('multer');
const path = require('path');
const fs = require('fs').promises;
const { Pool } = require('pg');
const Redis = require('ioredis');
const { InfluxDB, Point } = require('@influxdata/influxdb-client');

const app = express();
const PORT = process.env.PORT || 3000;

// Database connections
const pool = new Pool({
    connectionString: process.env.DB_URL || 'postgresql://cdn_user:cdn_password@localhost:5432/cdn_db'
});

const redis = new Redis(process.env.REDIS_URL || 'redis://localhost:6379');

// InfluxDB for analytics
const influxDB = new InfluxDB({
    url: process.env.INFLUX_URL || 'http://localhost:8086',
    token: process.env.INFLUX_TOKEN || 'your-token'
});
const writeApi = influxDB.getWriteApi('cdn-org', 'cdn-analytics');

// Middleware
app.use(helmet());
app.use(cors());
app.use(morgan('combined'));
app.use(express.json({ limit: '50mb' }));
app.use(express.urlencoded({ extended: true, limit: '50mb' }));

// File upload configuration
const storage = multer.diskStorage({
    destination: (req, file, cb) => {
        cb(null, './uploads/');
    },
    filename: (req, file, cb) => {
        const uniqueSuffix = Date.now() + '-' + Math.round(Math.random() * 1E9);
        cb(null, file.fieldname + '-' + uniqueSuffix + path.extname(file.originalname));
    }
});

const upload = multer({ 
    storage: storage,
    limits: {
        fileSize: 100 * 1024 * 1024 // 100MB limit
    },
    fileFilter: (req, file, cb) => {
        // Allow common web file types
        const allowedTypes = /jpeg|jpg|png|gif|webp|svg|css|js|html|pdf|mp4|webm/;
        const extname = allowedTypes.test(path.extname(file.originalname).toLowerCase());
        const mimetype = allowedTypes.test(file.mimetype);
        
        if (mimetype && extname) {
            return cb(null, true);
        } else {
            cb(new Error('File type not allowed'));
        }
    }
});

// Analytics middleware
const analyticsMiddleware = (req, res, next) => {
    const startTime = Date.now();
    
    res.on('finish', () => {
        const responseTime = Date.now() - startTime;
        
        // Write analytics data to InfluxDB
        const point = new Point('http_requests')
            .tag('method', req.method)
            .tag('status_code', res.statusCode.toString())
            .tag('user_agent', req.get('User-Agent') || 'unknown')
            .tag('edge_server', req.get('X-Edge-Server') || 'direct')
            .tag('edge_region', req.get('X-Edge-Region') || 'unknown')
            .intField('response_time', responseTime)
            .intField('bytes_sent', res.get('Content-Length') || 0)
            .stringField('path', req.path)
            .stringField('ip', req.ip);
        
        writeApi.writePoint(point);
        
        // Also cache hit rate data in Redis for quick access
        const cacheKey = `analytics:${new Date().toISOString().split('T')[0]}`;
        redis.hincrby(cacheKey, 'total_requests', 1);
        redis.hincrby(cacheKey, `status_${res.statusCode}`, 1);
        redis.expire(cacheKey, 86400 * 7); // Keep for 7 days
    });
    
    next();
};

app.use(analyticsMiddleware);

// Health check endpoint
app.get('/health', async (req, res) => {
    try {
        // Check database connection
        await pool.query('SELECT 1');
        
        // Check Redis connection
        await redis.ping();
        
        res.json({
            status: 'healthy',
            timestamp: new Date().toISOString(),
            services: {
                database: 'healthy',
                redis: 'healthy',
                influxdb: 'healthy'
            }
        });
    } catch (error) {
        res.status(503).json({
            status: 'unhealthy',
            error: error.message,
            timestamp: new Date().toISOString()
        });
    }
});

// Content upload endpoint
app.post('/upload', upload.array('files', 10), async (req, res) => {
    try {
        if (!req.files || req.files.length === 0) {
            return res.status(400).json({ error: 'No files uploaded' });
        }

        const uploadedFiles = [];
        
        for (const file of req.files) {
            // Store file metadata in database
            const query = `
                INSERT INTO files (filename, original_name, mimetype, size, path, uploaded_at)
                VALUES ($1, $2, $3, $4, $5, NOW())
                RETURNING id, filename
            `;
            
            const result = await pool.query(query, [
                file.filename,
                file.originalname,
                file.mimetype,
                file.size,
                file.path
            ]);
            
            uploadedFiles.push({
                id: result.rows[0].id,
                filename: result.rows[0].filename,
                original_name: file.originalname,
                size: file.size,
                mimetype: file.mimetype,
                url: `/content/${result.rows[0].filename}`
            });
        }
        
        res.json({
            message: 'Files uploaded successfully',
            files: uploadedFiles
        });
        
    } catch (error) {
        console.error('Upload error:', error);
        res.status(500).json({ error: 'Upload failed' });
    }
});

// Content serving endpoint
app.get('/content/:filename', async (req, res) => {
    try {
        const { filename } = req.params;
        
        // Get file metadata from database
        const query = 'SELECT * FROM files WHERE filename = $1';
        const result = await pool.query(query, [filename]);
        
        if (result.rows.length === 0) {
            return res.status(404).json({ error: 'File not found' });
        }
        
        const fileRecord = result.rows[0];
        const filePath = path.join(__dirname, '..', 'uploads', filename);
        
        try {
            await fs.access(filePath);
        } catch {
            return res.status(404).json({ error: 'File not found on disk' });
        }
        
        // Set appropriate headers
        res.set({
            'Content-Type': fileRecord.mimetype,
            'Content-Length': fileRecord.size,
            'Cache-Control': getCacheControl(fileRecord.mimetype),
            'ETag': `"${fileRecord.id}-${fileRecord.uploaded_at.getTime()}"`,
            'Last-Modified': fileRecord.uploaded_at.toUTCString()
        });
        
        // Handle conditional requests
        const ifNoneMatch = req.get('If-None-Match');
        const ifModifiedSince = req.get('If-Modified-Since');
        
        if (ifNoneMatch === `"${fileRecord.id}-${fileRecord.uploaded_at.getTime()}"`) {
            return res.status(304).end();
        }
        
        if (ifModifiedSince && new Date(ifModifiedSince) >= fileRecord.uploaded_at) {
            return res.status(304).end();
        }
        
        // Send file
        res.sendFile(filePath);
        
    } catch (error) {
        console.error('Content serving error:', error);
        res.status(500).json({ error: 'Failed to serve content' });
    }
});

// Static content endpoint
app.get('/static/:filename', async (req, res) => {
    try {
        const { filename } = req.params;
        const filePath = path.join(__dirname, '..', 'uploads', filename);
        
        // Check if file exists
        try {
            await fs.access(filePath);
        } catch {
            return res.status(404).json({ error: 'File not found' });
        }
        
        // Get file stats
        const stats = await fs.stat(filePath);
        const mimeType = getMimeType(filename);
        
        // Set headers for static content (longer cache)
        res.set({
            'Content-Type': mimeType,
            'Content-Length': stats.size,
            'Cache-Control': 'public, max-age=31536000, immutable',
            'ETag': `"${stats.mtime.getTime()}-${stats.size}"`,
            'Last-Modified': stats.mtime.toUTCString()
        });
        
        // Handle conditional requests
        const ifNoneMatch = req.get('If-None-Match');
        if (ifNoneMatch === `"${stats.mtime.getTime()}-${stats.size}"`) {
            return res.status(304).end();
        }
        
        res.sendFile(filePath);
        
    } catch (error) {
        console.error('Static content error:', error);
        res.status(500).json({ error: 'Failed to serve static content' });
    }
});

// File listing endpoint
app.get('/files', async (req, res) => {
    try {
        const page = parseInt(req.query.page) || 1;
        const limit = parseInt(req.query.limit) || 20;
        const offset = (page - 1) * limit;
        
        const query = `
            SELECT id, filename, original_name, mimetype, size, uploaded_at
            FROM files
            ORDER BY uploaded_at DESC
            LIMIT $1 OFFSET $2
        `;
        
        const countQuery = 'SELECT COUNT(*) FROM files';
        
        const [files, count] = await Promise.all([
            pool.query(query, [limit, offset]),
            pool.query(countQuery)
        ]);
        
        res.json({
            files: files.rows.map(file => ({
                ...file,
                url: `/content/${file.filename}`
            })),
            pagination: {
                page,
                limit,
                total: parseInt(count.rows[0].count),
                pages: Math.ceil(count.rows[0].count / limit)
            }
        });
        
    } catch (error) {
        console.error('File listing error:', error);
        res.status(500).json({ error: 'Failed to list files' });
    }
});

// Analytics endpoint
app.get('/analytics', async (req, res) => {
    try {
        const days = parseInt(req.query.days) || 7;
        const dates = [];
        
        for (let i = 0; i < days; i++) {
            const date = new Date();
            date.setDate(date.getDate() - i);
            dates.push(date.toISOString().split('T')[0]);
        }
        
        const analytics = {};
        
        for (const date of dates) {
            const cacheKey = `analytics:${date}`;
            const data = await redis.hgetall(cacheKey);
            analytics[date] = data;
        }
        
        res.json({
            period: `${days} days`,
            data: analytics
        });
        
    } catch (error) {
        console.error('Analytics error:', error);
        res.status(500).json({ error: 'Failed to get analytics' });
    }
});

// Cache invalidation endpoint
app.delete('/cache/:pattern', async (req, res) => {
    try {
        const { pattern } = req.params;
        const keys = await redis.keys(`content:*${pattern}*`);
        
        if (keys.length > 0) {
            await redis.del(...keys);
        }
        
        res.json({
            message: 'Cache invalidated',
            keys_deleted: keys.length
        });
        
    } catch (error) {
        console.error('Cache invalidation error:', error);
        res.status(500).json({ error: 'Failed to invalidate cache' });
    }
});

// Error handling middleware
app.use((error, req, res, next) => {
    console.error('Error:', error);
    
    if (error instanceof multer.MulterError) {
        if (error.code === 'LIMIT_FILE_SIZE') {
            return res.status(400).json({ error: 'File too large' });
        }
    }
    
    res.status(500).json({ 
        error: 'Internal server error',
        message: process.env.NODE_ENV === 'development' ? error.message : undefined
    });
});

// 404 handler
app.use((req, res) => {
    res.status(404).json({ error: 'Not found' });
});

// Utility functions
function getCacheControl(mimetype) {
    if (mimetype.startsWith('image/')) {
        return 'public, max-age=2592000'; // 30 days
    } else if (mimetype.includes('css') || mimetype.includes('javascript')) {
        return 'public, max-age=86400'; // 1 day
    } else if (mimetype.includes('html')) {
        return 'public, max-age=3600'; // 1 hour
    }
    return 'public, max-age=300'; // 5 minutes default
}

function getMimeType(filename) {
    const ext = path.extname(filename).toLowerCase();
    const mimeTypes = {
        '.jpg': 'image/jpeg',
        '.jpeg': 'image/jpeg',
        '.png': 'image/png',
        '.gif': 'image/gif',
        '.webp': 'image/webp',
        '.svg': 'image/svg+xml',
        '.css': 'text/css',
        '.js': 'application/javascript',
        '.html': 'text/html',
        '.pdf': 'application/pdf',
        '.mp4': 'video/mp4',
        '.webm': 'video/webm'
    };
    return mimeTypes[ext] || 'application/octet-stream';
}

// Graceful shutdown
process.on('SIGTERM', async () => {
    console.log('Received SIGTERM, shutting down gracefully');
    
    // Close InfluxDB write API
    writeApi.close();
    
    // Close Redis connection
    redis.disconnect();
    
    // Close database pool
    await pool.end();
    
    process.exit(0);
});

// Start server
app.listen(PORT, () => {
    console.log(`Origin server running on port ${PORT}`);
    console.log(`Environment: ${process.env.NODE_ENV || 'development'}`);
});

module.exports = app;