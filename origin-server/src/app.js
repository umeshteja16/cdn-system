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

// Database connections with better error handling
const pool = new Pool({
    connectionString: process.env.DB_URL || 'postgresql://cdn_user:cdn_password@postgres:5432/cdn_db'
});

const redis = new Redis(process.env.REDIS_URL || 'redis://redis-cluster:6379');

// InfluxDB for analytics
const influxDB = new InfluxDB({
    url: process.env.INFLUX_URL || 'http://influxdb:8086',
    token: process.env.INFLUX_TOKEN || 'admin-token'
});
const writeApi = influxDB.getWriteApi(process.env.INFLUX_ORG || 'cdn-org', process.env.INFLUX_BUCKET || 'cdn-metrics');

// Test database connection
async function testDatabaseConnection() {
    try {
        const client = await pool.connect();
        await client.query('SELECT 1');
        client.release();
        console.log('✅ Database connection successful');
        return true;
    } catch (error) {
        console.error('❌ Database connection failed:', error.message);
        return false;
    }
}

// Test connections on startup
(async () => {
    await testDatabaseConnection();
    try {
        await redis.ping();
        console.log('✅ Redis connection successful');
    } catch (error) {
        console.error('❌ Redis connection failed:', error.message);
    }
})();

// Middleware
app.use(helmet());
app.use(cors());
app.use(morgan('combined'));
app.use(express.json({ limit: '50mb' }));
app.use(express.urlencoded({ extended: true, limit: '50mb' }));

// Ensure uploads directory exists
const uploadsDir = path.join(__dirname, '..', 'uploads');
async function ensureUploadsDir() {
    try {
        await fs.mkdir(uploadsDir, { recursive: true });
        console.log('✅ Uploads directory ready:', uploadsDir);
    } catch (error) {
        console.error('❌ Failed to create uploads directory:', error);
        process.exit(1);
    }
}
ensureUploadsDir();

// FIXED: Improved multer configuration with better error handling
const storage = multer.diskStorage({
    destination: async (req, file, cb) => {
        try {
            // Ensure directory exists
            await fs.access(uploadsDir);
            cb(null, uploadsDir);
        } catch (error) {
            console.error('❌ Upload directory not accessible:', error);
            // Try to create it if it doesn't exist
            try {
                await fs.mkdir(uploadsDir, { recursive: true });
                cb(null, uploadsDir);
            } catch (createError) {
                console.error('❌ Failed to create upload directory:', createError);
                cb(createError);
            }
        }
    },
    filename: (req, file, cb) => {
        // Generate unique filename
        const uniqueSuffix = Date.now() + '-' + Math.round(Math.random() * 1E9);
        const ext = path.extname(file.originalname);
        const name = path.basename(file.originalname, ext);
        cb(null, `${name}-${uniqueSuffix}${ext}`);
    }
});

const upload = multer({ 
    storage: storage,
    limits: {
        fileSize: 100 * 1024 * 1024, // 100MB limit
        files: 10 // Max 10 files per request
    },
    fileFilter: (req, file, cb) => {
        // Allow common web file types
        const allowedExtensions = /\.(jpeg|jpg|png|gif|webp|svg|css|js|html|pdf|mp4|webm|txt|json|xml)$/i;
        const extname = allowedExtensions.test(path.extname(file.originalname));
        
        if (extname) {
            return cb(null, true);
        } else {
            const error = new Error('File type not allowed');
            error.code = 'INVALID_FILE_TYPE';
            cb(error);
        }
    }
});

//BUG- counting refreshes as cache misses

// Analytics middleware
const analyticsMiddleware = (req, res, next) => {
    const startTime = Date.now();
    
    const originalEnd = res.end;
    
    res.end = function(chunk, encoding) {
        const responseTime = Date.now() - startTime;
        
        let cacheStatus = 'MISS';
        const edgeServer = req.get('X-Edge-Server');
        const xCache = req.get('X-Cache') || res.get('X-Cache');
        
        if (xCache) {
            cacheStatus = xCache.toUpperCase();
        } else if (edgeServer) {
            cacheStatus = 'MISS';
        }
        
        // Write analytics data to InfluxDB
        const point = new Point('http_requests')
            .tag('method', req.method)
            .tag('status_code', res.statusCode.toString())
            .tag('user_agent', req.get('User-Agent') || 'unknown')
            .tag('edge_server', edgeServer || 'direct')
            .tag('edge_region', req.get('X-Edge-Region') || 'unknown')
            .tag('cache_status', cacheStatus)
            .intField('response_time', responseTime)
            .intField('bytes_sent', res.get('Content-Length') || chunk?.length || 0)
            .stringField('path', req.path)
            .stringField('ip', req.ip);
        
        writeApi.writePoint(point);
        
        // Update Redis cache
        const cacheKey = `analytics:${new Date().toISOString().split('T')[0]}`;
        
        redis.hincrby(cacheKey, 'total_requests', 1);
        redis.hincrby(cacheKey, `status_${res.statusCode}`, 1);
        redis.hincrby(cacheKey, `cache_${cacheStatus.toLowerCase()}`, 1);
        redis.hincrby(cacheKey, 'total_bytes', res.get('Content-Length') || chunk?.length || 0);
        redis.expire(cacheKey, 86400 * 7);
        
        originalEnd.call(this, chunk, encoding);
    };
    
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
        
        // Check uploads directory
        await fs.access(uploadsDir);
        
        res.json({
            status: 'healthy',
            timestamp: new Date().toISOString(),
            services: {
                database: 'healthy',
                redis: 'healthy',
                influxdb: 'healthy',
                uploads_dir: 'accessible'
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

// FIXED: Improved upload endpoint with comprehensive error handling
app.post('/upload', (req, res) => {
    console.log('📤 Upload request received');
    
    upload.array('files', 10)(req, res, async (err) => {
        if (err) {
            console.error('❌ Multer error:', err);
            
            if (err instanceof multer.MulterError) {
                switch (err.code) {
                    case 'LIMIT_FILE_SIZE':
                        return res.status(400).json({ 
                            error: 'File too large', 
                            message: 'Maximum file size is 100MB' 
                        });
                    case 'LIMIT_FILE_COUNT':
                        return res.status(400).json({ 
                            error: 'Too many files', 
                            message: 'Maximum 10 files per request' 
                        });
                    case 'LIMIT_UNEXPECTED_FILE':
                        return res.status(400).json({ 
                            error: 'Unexpected field', 
                            message: 'Use "files" field name for uploads' 
                        });
                    default:
                        return res.status(400).json({ 
                            error: 'Upload error', 
                            message: err.message 
                        });
                }
            } else if (err.code === 'INVALID_FILE_TYPE') {
                return res.status(400).json({ 
                    error: 'Invalid file type', 
                    message: 'Allowed types: images, CSS, JS, HTML, PDF, videos' 
                });
            } else {
                return res.status(500).json({ 
                    error: 'Server error', 
                    message: 'Failed to process upload' 
                });
            }
        }
        
        try {
            if (!req.files || req.files.length === 0) {
                return res.status(400).json({ 
                    error: 'No files uploaded',
                    message: 'Please select files to upload'
                });
            }

            console.log(`📁 Processing ${req.files.length} files`);
            const uploadedFiles = [];
            
            for (const file of req.files) {
                console.log(`📄 Processing: ${file.originalname} (${file.size} bytes)`);
                
                try {
                    // Verify file was written successfully
                    await fs.access(file.path);
                    const stats = await fs.stat(file.path);
                    
                    if (stats.size !== file.size) {
                        throw new Error('File size mismatch - upload may be corrupted');
                    }
                    
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
                    
                    console.log(`✅ File saved: ${file.originalname}`);
                    
                } catch (fileError) {
                    console.error(`❌ Error processing ${file.originalname}:`, fileError);
                    // Clean up failed file
                    try {
                        await fs.unlink(file.path);
                    } catch (unlinkError) {
                        console.error('Failed to cleanup file:', unlinkError);
                    }
                }
            }
            
            if (uploadedFiles.length === 0) {
                return res.status(500).json({ 
                    error: 'Upload failed', 
                    message: 'No files were saved successfully' 
                });
            }
            
            console.log(`✅ Successfully uploaded ${uploadedFiles.length} files`);
            res.json({
                message: 'Files uploaded successfully',
                count: uploadedFiles.length,
                files: uploadedFiles
            });
            
        } catch (error) {
            console.error('❌ Upload processing error:', error);
            res.status(500).json({ 
                error: 'Server error',
                message: 'Failed to process uploaded files',
                details: process.env.NODE_ENV === 'development' ? error.message : undefined
            });
        }
    });
});

// Content serving endpoint
app.get('/content/:filename', async (req, res) => {
    try {
        const { filename } = req.params;
        
        console.log(`📥 Serving content: ${filename}`);
        
        // Get file metadata from database
        const query = 'SELECT * FROM files WHERE filename = $1';
        const result = await pool.query(query, [filename]);
        
        if (result.rows.length === 0) {
            console.log(`❌ File not found in database: ${filename}`);
            return res.status(404).json({ error: 'File not found' });
        }
        
        const fileRecord = result.rows[0];
        const filePath = path.join(uploadsDir, filename);
        
        try {
            await fs.access(filePath);
        } catch {
            console.log(`❌ File not found on disk: ${filename}`);
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
        console.log(`✅ Serving file: ${filename}`);
        res.sendFile(filePath);
        
    } catch (error) {
        console.error('❌ Content serving error:', error);
        res.status(500).json({ error: 'Failed to serve content' });
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
        console.error('❌ File listing error:', error);
        res.status(500).json({ error: 'Failed to list files' });
    }
});

// Error handling middleware
app.use((error, req, res, next) => {
    console.error('❌ Unhandled error:', error);
    
    res.status(500).json({ 
        error: 'Internal server error',
        message: process.env.NODE_ENV === 'development' ? error.message : 'Something went wrong'
    });
});

// 404 handler
app.use((req, res) => {
    res.status(404).json({ error: 'Endpoint not found' });
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

// Graceful shutdown
process.on('SIGTERM', async () => {
    console.log('🛑 Received SIGTERM, shutting down gracefully');
    
    writeApi.close();
    redis.disconnect();
    await pool.end();
    
    process.exit(0);
});

// Start server
app.listen(PORT, () => {
    console.log(`🚀 Origin server running on port ${PORT}`);
    console.log(`📁 Upload directory: ${uploadsDir}`);
    console.log(`🌍 Environment: ${process.env.NODE_ENV || 'development'}`);
});

module.exports = app;
