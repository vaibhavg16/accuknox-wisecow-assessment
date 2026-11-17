# Wisecow application image
# Debian slim (not Alpine): fortune-mod/cowsay ship glibc-oriented packages.
FROM debian:bookworm-slim

# Runtime dependencies + fortune databases + curl for the healthcheck
RUN apt-get update && apt-get install -y --no-install-recommends \
        fortune-mod \
        fortunes \
        fortunes-min \
        cowsay \
        netcat-openbsd \
        curl \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Fixed UID/GID so the kubelet can enforce runAsNonRoot before start-up.
# No login shell: the container only needs to exec wisecow.sh.
RUN groupadd -r -g 10001 wisecow \
 && useradd -r -u 10001 -g wisecow -s /usr/sbin/nologin -d /app wisecow

# Debian installs cowsay and fortune into /usr/games, not /usr/bin
ENV PATH="/usr/games:${PATH}"

WORKDIR /app
COPY wisecow.sh .
RUN chmod +x wisecow.sh && chown -R 10001:10001 /app

USER 10001
EXPOSE 4499

# HTTP probe, not a bare TCP connect: the single-threaded accept loop makes a
# TCP-only probe unreliable (it consumes the pending connection).
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -fsS --max-time 4 http://127.0.0.1:4499/ >/dev/null || exit 1

ENTRYPOINT ["./wisecow.sh"]
