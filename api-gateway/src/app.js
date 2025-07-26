// api-gateway/src/app.js
const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const rateLimit = require('express-rate-limit');
const { createProxyMiddleware } = require('http-proxy-middleware');

const app = express();
const PORT = process.env.PORT || 4000;

// Security middleware
app.use(helmet());
app.use(cors({
    origin: process.env.ALLOWED_ORIGINS ? process.env.ALLOWED_ORIGINS.split(',') : '*',
    methods: ['GET', 'POST', 'PUT', 'DELETE', 'OPTIONS'],
    allowedHeaders: ['Content-Type', 'Authorization', 'X-Requested-With']
}));

// Rate limiting
const limiter = rateLimit({
    windowMs: 15 * 60 * 1000, // 15 minutes
    max: 100, // limit each IP to 100 requests per windowMs
    message: {
        error: 'Too many requests from this IP, please try again later.'
    }
});
app.use(limiter);

// JSON parsing
app.use(express.json({ limit: '10mb' }));
app.use(express.urlencoded({ extended: true, limit: '10mb' }));

// Health check
app.get('/health', (req, res) => {
    res.json({
        status: 'healthy',
        timestamp: new Date().toISOString(),
        service: 'api-gateway'
    });
});

// Proxy to origin server for content operations
app.use('/api/content', createProxyMiddleware({
    target: process.env.ORIGIN_URL || 'http://origin-server:3000',
    changeOrigin: true,
    pathRewrite: {
        '^/api/content': '/content'
    },
    onProxyReq: (proxyReq, req, res) => {
        proxyReq.setHeader('X-Gateway', 'api-gateway');
    }
}));

// Proxy to origin server for upload operations
app.use('/api/upload', createProxyMiddleware({
    target: process.env.ORIGIN_URL || 'http://origin-server:3000',
    changeOrigin: true,
    pathRewrite: {
        '^/api/upload': '/upload'
    },
    onProxyReq: (proxyReq, req, res) => {
        proxyReq.setHeader('X-Gateway', 'api-gateway');
    }
}));

// Proxy to origin server for file listing
app.use('/api/files', createProxyMiddleware({
    target: process.env.ORIGIN_URL || 'http://origin-server:3000',
    changeOrigin: true,
    pathRewrite: {
        '^/api/files': '/files'
    },
    onProxyReq: (proxyReq, req, res) => {
        proxyReq.setHeader('X-Gateway', 'api-gateway');
    }
}));

// Proxy to analytics service
app.use('/api/analytics', createProxyMiddleware({
    target: process.env.ANALYTICS_URL || 'http://analytics-service:5000',
    changeOrigin: true,
    pathRewrite: {
        '^/api/analytics': ''
    },
    onProxyReq: (proxyReq, req, res) => {
        proxyReq.setHeader('X-Gateway', 'api-gateway');
    }
}));

// API Documentation endpoint
app.get('/api', (req, res) => {
    res.json({
        name: 'CDN API Gateway',
        version: '1.0.0',
        endpoints: {
            health: 'GET /health',
            content: {
                upload: 'POST /api/upload',
                get: 'GET /api/content/{filename}',
                list: 'GET /api/files',
                delete_cache: 'DELETE /api/cache/{pattern}'
            },
            analytics: {
                realtime: 'GET /api/analytics/metrics/realtime',
                timeseries: 'GET /api/analytics/metrics/timeseries',
                geography: 'GET /api/analytics/metrics/geography',
                top_content: 'GET /api/analytics/content/top',
                server_performance: 'GET /api/analytics/servers/performance',
                daily_report: 'GET /api/analytics/reports/daily/{date}'
            }
        }
    });
});

// Error handling middleware
app.use((error, req, res, next) => {
    console.error('Gateway Error:', error);
    res.status(500).json({
        error: 'Gateway error',
        message: process.env.NODE_ENV === 'development' ? error.message : 'Internal server error'
    });
});

// 404 handler
app.use((req, res) => {
    res.status(404).json({
        error: 'Not found',
        path: req.path
    });
});

// Start server
app.listen(PORT, () => {
    console.log(`API Gateway running on port ${PORT}`);
    console.log(`Proxying to:`);
    console.log(`  Origin: ${process.env.ORIGIN_URL || 'http://origin-server:3000'}`);
    console.log(`  Analytics: ${process.env.ANALYTICS_URL || 'http://analytics-service:5000'}`);
});

module.exports = app;