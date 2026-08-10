FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y haproxy keepalived curl iproute2 procps && rm -rf /var/lib/apt/lists/*
RUN mkdir -p /run/haproxy
COPY start.sh /start.sh
RUN chmod +x /start.sh
CMD ["/start.sh"]
