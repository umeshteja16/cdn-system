# Multi-stage build for Go edge server
FROM golang:1.22-alpine AS builder

WORKDIR /app

# Install build dependencies
RUN apk add --no-cache git ca-certificates tzdata

# Copy go mod files
COPY go.mod go.sum ./

# Download dependencies with verification disabled if needed
ENV GOSUMDB=off
RUN go mod download

# Verify dependencies
RUN go mod verify

# Copy source code
COPY . .

# Build the binary
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
    -ldflags='-w -s -extldflags "-static"' \
    -a -installsuffix cgo \
    -o edge-server .

# Final stage - minimal runtime ima
FROM alpine:3.18

# Install ca-certificates for HTTPS requests
RUN apk --no-cache add ca-certificates curl

WORKDIR /root/

# Copy the binary from builder stage
COPY --from=builder /app/edge-server .

# Create cache directory
RUN mkdir -p /cache

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

# Expose port
EXPOSE 8080

# Run the binary
CMD ["./edge-server"]