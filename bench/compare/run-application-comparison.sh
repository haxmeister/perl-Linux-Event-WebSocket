#!/usr/bin/env bash
set -euo pipefail

output="${1:-application-comparison.csv}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

echo 'server,type,bytes,clients,window,messages,seconds,msg_per_sec,payload_mib_per_sec' > "$output"

server_pid=''
server_name=''
server_log=''

cleanup_server() {
    if [[ -n "${server_pid}" ]]; then
        kill "${server_pid}" 2>/dev/null || true
        wait "${server_pid}" 2>/dev/null || true
        server_pid=''
    fi
}

trap cleanup_server EXIT

have_cpu_pair=0
if [[ "$(nproc)" -ge 2 ]]; then
    have_cpu_pair=1
fi

wait_port() {
    local port="$1"

    for _ in {1..200}; do
        if timeout 0.1 bash -c "exec 3<>/dev/tcp/127.0.0.1/$port" 2>/dev/null; then
            return 0
        fi

        if ! kill -0 "$server_pid" 2>/dev/null; then
            echo "$server_name exited before accepting connections" >&2
            cat "$server_log" >&2 || true
            return 1
        fi

        sleep 0.05
    done

    echo "$server_name did not listen on port $port" >&2
    cat "$server_log" >&2 || true
    return 1
}

start_server() {
    local name="$1"
    local port="$2"
    shift 2

    cleanup_server

    server_name="$name"
    server_log="/tmp/websocket-bench-${name}.log"
    : > "$server_log"

    if [[ "$have_cpu_pair" -eq 1 ]]; then
        taskset -c 0 env PORT="$port" "$@" >"$server_log" 2>&1 &
    else
        env PORT="$port" "$@" >"$server_log" 2>&1 &
    fi
    server_pid=$!

    wait_port "$port"
}

run_case() {
    local name="$1"
    local port="$2"
    local type="$3"
    local bytes="$4"
    local clients="$5"
    local window="$6"

    local command=(
        node bench/compare/load.mjs
        --label "$name"
        --port "$port"
        --mode application
        --type "$type"
        --bytes "$bytes"
        --clients "$clients"
        --window "$window"
        --warmup 0.5
        --seconds 1.5
    )

    local row
    if [[ "$have_cpu_pair" -eq 1 ]]; then
        row="$(taskset -c 1 "${command[@]}")"
    else
        row="$("${command[@]}")"
    fi

    echo "$row" | tee -a "$output"
}

run_matrix() {
    local name="$1"
    local port="$2"

    for bytes in 256 1024 16384; do
        for _ in 1 2 3 4 5; do
            run_case "$name" "$port" text "$bytes" 20 4
        done
    done
}

start_server linux_event 9301 env BENCH_MODE=application perl -Iblib/lib bench/compare/servers/linux-event.pl
run_matrix linux_event 9301

start_server mojolicious 9302 perl bench/compare/servers/mojo.pl
run_matrix mojolicious 9302

start_server node_ws 9303 node bench/compare/servers/node.mjs
run_matrix node_ws 9303

start_server gorilla 9304 env GOMAXPROCS=1 /tmp/gorilla-websocket-bench
run_matrix gorilla 9304

cleanup_server

echo
echo "Application comparison complete: $output"
