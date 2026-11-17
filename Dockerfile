# Wisecow Application Dockerfile
FROM debian:bookworm-slim

# Runtime dependencies + fortune databases + curl for healthcheck
RUN apt-get update && apt-get install -y --no-install-recommends \
    fortune-mod \
    fortunes \
    fortunes-min \
    cowsay \
    netcat-openbsd \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Non-root user with fixed UID for K8s runAsNonRoot
RUN groupadd -r -g 10001 wisecow && \
    useradd -r -u 10001 -g wisecow -s /usr/sbin/nologin -d /app wisecow

# Debian installs cowsay/fortune in /usr/games
ENV PATH="/usr/games:${PATH}"

WORKDIR /app
COPY wisecow.sh .
RUN chmod +x wisecow.sh && chown -R wisecow:wisecow /app

USER 10001
EXPOSE 4499

# HTTP healthcheck (TCP connect hangs on this app)
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -fsS --max-time 4 http://localhost:4499/ >/dev/null || exit 1

ENTRYPOINT ["./wisecow.sh"]
