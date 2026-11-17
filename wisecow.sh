#!/usr/bin/env bash
# Wisecow — serves a fortune through cowsay over HTTP.
# Adapted from https://github.com/nyrahul/wisecow
# Change vs upstream: the response FIFO lives in /tmp so the app runs with a
# read-only root filesystem (an emptyDir is mounted at /tmp by the Deployment).
set -euo pipefail

SRVPORT="${SRVPORT:-4499}"
RSPFILE=/tmp/response

cleanup() { rm -f "$RSPFILE"; }
trap cleanup EXIT

rm -f "$RSPFILE"
mkfifo "$RSPFILE"

get_api() {
    read -r line
    echo "$line"
}

handleRequest() {
    get_api
    mod=$(fortune)

    cat <<EOF > "$RSPFILE"
HTTP/1.1 200 OK
Content-Type: text/html; charset=utf-8
Connection: close

<pre>$(cowsay "$mod")</pre>
EOF
}

prerequisites() {
    command -v cowsay  >/dev/null 2>&1 || { echo "cowsay not found"  >&2; exit 1; }
    command -v fortune >/dev/null 2>&1 || { echo "fortune not found" >&2; exit 1; }
    command -v nc      >/dev/null 2>&1 || { echo "netcat not found"  >&2; exit 1; }
}

main() {
    prerequisites
    echo "Wisdom served on port=$SRVPORT..."

    while true; do
        cat "$RSPFILE" | nc -lN "$SRVPORT" | handleRequest
        sleep 0.05
    done
}

main
