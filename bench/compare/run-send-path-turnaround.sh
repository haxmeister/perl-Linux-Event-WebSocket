#!/usr/bin/env bash
set -euo pipefail

output="${1:-send-path-turnaround.csv}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

echo 'path,bytes,clients,window,messages,seconds,msg_per_sec,payload_mib_per_sec' > "$output"

server_pid=''
cleanup() {
    if [[ -n "${server_pid}" ]]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
        server_pid=''
    fi
}
trap cleanup EXIT

start_server() {
    local path="$1"
    local port="$2"
    cleanup
    : > "/tmp/websocket-send-path-${path}.log"
    if [[ "$(nproc)" -ge 2 ]]; then
        taskset -c 0 env PORT="$port" SEND_PATH="$path" perl -Iblib/lib bench/compare/servers/linux-event-send-path.pl >"/tmp/websocket-send-path-${path}.log" 2>&1 &
    else
        env PORT="$port" SEND_PATH="$path" perl -Iblib/lib bench/compare/servers/linux-event-send-path.pl >"/tmp/websocket-send-path-${path}.log" 2>&1 &
    fi
    server_pid=$!
    for _ in {1..200}; do
        if timeout 0.1 bash -c "exec 3<>/dev/tcp/127.0.0.1/$port" 2>/dev/null; then
            return
        fi
        if ! kill -0 "$server_pid" 2>/dev/null; then
            cat "/tmp/websocket-send-path-${path}.log" >&2 || true
            exit 1
        fi
        sleep 0.05
    done
    echo "server did not start: $path" >&2
    exit 1
}

run_case() {
    local path="$1"
    local port="$2"
    local clients="$3"
    local window="$4"
    local command=(
        node bench/compare/load.mjs
        --label "$path"
        --port "$port"
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
    echo "$row" | awk -F, 'BEGIN{OFS=","}{print $1,$3,$4,$5,$6,$7,$8,$9}' | tee -a "$output"
}

port=9601
for path in public engine native_deferred native_immediate preframed; do
    start_server "$path" "$port"
    for clients in 20 100 1000; do
        for window in 1 4; do
            for _ in 1 2 3 4 5; do
                run_case "$path" "$port" "$clients" "$window"
            done
        done
    done
    port=$((port + 1))
done

cleanup
echo
echo "Send-path turnaround comparison complete: $output"
