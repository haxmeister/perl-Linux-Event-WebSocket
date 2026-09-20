#!/usr/bin/env bash
set -euo pipefail

output="${1:-linux-event-window-depth.csv}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

echo 'server,type,bytes,clients,window,messages,seconds,msg_per_sec,payload_mib_per_sec' > "$output"

server_log=/tmp/websocket-window-depth-linux-event.log
: > "$server_log"

cleanup() {
    if [[ -n "${server_pid:-}" ]]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT

if [[ "$(nproc)" -ge 2 ]]; then
    taskset -c 0 env PORT=9501 BENCH_MODE=application perl -Iblib/lib bench/compare/servers/linux-event.pl >"$server_log" 2>&1 &
else
    env PORT=9501 BENCH_MODE=application perl -Iblib/lib bench/compare/servers/linux-event.pl >"$server_log" 2>&1 &
fi
server_pid=$!

for _ in {1..200}; do
    if timeout 0.1 bash -c "exec 3<>/dev/tcp/127.0.0.1/9501" 2>/dev/null; then
        break
    fi
    if ! kill -0 "$server_pid" 2>/dev/null; then
        cat "$server_log" >&2 || true
        exit 1
    fi
    sleep 0.05
done

run_case() {
    local clients="$1"
    local window="$2"
    local command=(
        node bench/compare/load.mjs
        --label linux_event
        --port 9501
        --mode application
        --type text
        --bytes 64
        --clients "$clients"
        --window "$window"
        --warmup 0.75
        --seconds 2
    )

    local row
    if [[ "$(nproc)" -ge 2 ]]; then
        row="$(taskset -c 1 "${command[@]}")"
    else
        row="$("${command[@]}")"
    fi
    echo "$row" | tee -a "$output"
}

for clients in 20 100 500 1000; do
    for window in 1 4 16; do
        for _ in 1 2 3 4 5; do
            run_case "$clients" "$window"
        done
    done
done

echo
echo "Linux::Event window-depth sweep complete: $output"
