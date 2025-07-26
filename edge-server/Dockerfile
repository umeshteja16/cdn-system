# edge-server/Dockerfile
FROM golang:1.21-alpine AS builder

WORKDIR /app

# Install build dependencies
RUN apk add --no-cache git ca-certificates

# Copy all source code first (this handles missing go.sum gracefully)
COPY . .

# Initialize go.sum if it doesn't exist and download dependencies
RUN go mod tidy && \
    go mod download && \
    go mod verify

# Build the application
RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o edge-server .

# Final stage
FROM alpine:latest

# Install runtime dependencies
RUN apk --no-cache add ca-certificates curl

WORKDIR /root/

# Copy binary from builder stage
COPY --from=builder /app/edge-server .

# Create non-root user
RUN adduser -D -s /bin/sh edge
USER edge

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

EXPOSE 8080

CMD ["./edge-server"]