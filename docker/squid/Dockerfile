FROM ubuntu/squid:latest
RUN apt-get update && apt-get install -y squid-openssl && rm -rf /var/lib/apt/lists/*
RUN mkdir -p /etc/squid/certs
COPY start.sh /start.sh
RUN chmod +x /start.sh
ENTRYPOINT ["/start.sh"]
CMD []
