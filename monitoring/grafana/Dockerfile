FROM grafana/grafana:latest

# Copy dashboards and provisioning
COPY dashboards/ /etc/grafana/provisioning/dashboards/
COPY provisioning/ /etc/grafana/provisioning/

# Set permissions
USER root
RUN chown -R grafana:grafana /etc/grafana/provisioning
USER grafana

EXPOSE 3000