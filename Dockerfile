# Wisecow Application Dockerfile
# Multi-stage build for minimal production image

FROM debian:bookworm-slim AS base

# Install runtime dependencies + fortune databases
RUN apt-get update && apt-get install -y --no-install-recommends \
    fortune-mod \
    fortunes \
    fortunes-min \
    cowsay \
    netcat-openbsd \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user for security
RUN groupadd -r wisecow && useradd -r -g wisecow -s /bin/bash -d /app wisecow

# Add /usr/games to PATH for cowsay/fortune (Debian installs them there)
ENV PATH="/usr/games:${PATH}"

WORKDIR /app
COPY wisecow.sh .
RUN chmod +x wisecow.sh && chown -R wisecow:wisecow /app

USER wisecow
EXPOSE 4499

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD nc -z localhost 4499 || exit 1

ENTRYPOINT ["./wisecow.sh"]
