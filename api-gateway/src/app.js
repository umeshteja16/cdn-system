const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const morgan = require('morgan');
const rateLimit = require('express-rate-limit');

const app = express();
const PORT = process.env.PORT || 4000;

// Middleware
app.use(helmet());
app.use(cors());
app.use(morgan('combined'));
app.use(express.json({ limit: '10mb' }));
app.use(express.urlencoded({ extended: true }));

// Rate limiting
const limiter = rateLimit({
  windowMs: 15 * 60 * 1000, // 15 minutes
  max: 100 // limit each IP to 100 requests per windowMs
});
app.use('/api/', limiter);

// Health check
app.get('/health', (req, res) => {
  res.json({
    status: 'healthy',
    service: 'api-gateway',
    timestamp: new Date().toISOString(),
    version: '1.0.0'
  });
});

// API routes
app.get('/api/status', (req, res) => {
  res.json({
    status: 'API Gateway is running',
    timestamp: new Date().toISOString()
  });
});

// Analytics proxy
app.get('/api/analytics', async (req, res) => {
  try {
    // Proxy to analytics service
    const response = await fetch('http://analytics-service:5000/metrics/realtime');
    const data = await response.json();
    res.json(data);
  } catch (error) {
    res.status(500).json({ error: 'Analytics service unavailable' });
  }
});

// Error handling
app.use((error, req, res, next) => {
  console.error('API Gateway Error:', error);
  res.status(500).json({ 
    error: 'Internal server error',
    message: process.env.NODE_ENV === 'development' ? error.message : undefined
  });
});

// 404 handler
app.use((req, res) => {
  res.status(404).json({ error: 'Not found' });
});

app.listen(PORT, () => {
  console.log(`API Gateway running on port ${PORT}`);
});

module.exports = app;