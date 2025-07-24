FROM prom/prometheus:latest

# Copy configuration
COPY prometheus.yml /etc/prometheus/prometheus.yml

# Create data directory
USER root
RUN mkdir -p /prometheus-data && chown prometheus:prometheus /prometheus-data
USER prometheus

EXPOSE 9090