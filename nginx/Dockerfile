# nginx/Dockerfile
FROM nginx:alpine

# Install additional packages
RUN apk add --no-cache \
    openssl \
    curl

# Copy configuration
COPY nginx.conf /etc/nginx/nginx.conf

# Create SSL directory
RUN mkdir -p /etc/ssl/certs

# Generate self-signed certificate for development
RUN openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /etc/ssl/certs/cdn.key \
    -out /etc/ssl/certs/cdn.crt \
    -subj "/C=US/ST=State/L=City/O=Organization/CN=cdn.local"

# Create cache directories
RUN mkdir -p /var/cache/nginx/content
RUN chown -R nginx:nginx /var/cache/nginx

EXPOSE 80 443