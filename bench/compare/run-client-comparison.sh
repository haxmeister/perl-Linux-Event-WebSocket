#!/usr/bin/env bash
set -euo pipefail

output="${1:-client-comparison.csv}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

echo 'client,type,bytes,clients,window,messages,seconds,msg_per_sec,payload_mib_per_sec' > "$output"

server_pid=''
server_log='/tmp/websocket-client-comparison-server.log'

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

if [[ "$have_cpu_pair" -eq 1 ]]; then
    taskset -c 0 env PORT=9200 node bench/compare/servers/node.mjs >"$server_log" 2>&1 &
else
    env PORT=9200 node bench/compare/servers/node.mjs >"$server_log" 2>&1 &
fi
server_pid=$!

for _ in {1..200}; do
    if timeout 0.1 bash -c "exec 3<>/dev/tcp/127.0.0.1/9200" 2>/dev/null; then
        break
    fi
    if ! kill -0 "$server_pid" 2>/dev/null; then
        cat "$server_log" >&2 || true
        exit 1
    fi
    sleep 0.05
done

run_case() {
    local name="$1"
    local type="$2"
    local bytes="$3"
    local clients="$4"
    local window="$5"

    local command
    case "$name" in
        linux_event_client)
            command=(perl -Iblib/lib bench/compare/clients/linux-event.pl)
            ;;
        mojolicious_client)
            command=(perl bench/compare/clients/mojo.pl)
            ;;
        node_ws_client)
            command=(node bench/compare/load.mjs)
            ;;
        gorilla_client)
            command=(env GOMAXPROCS=1 /tmp/gorilla-websocket-client-bench)
            ;;
        *)
            echo "unknown client: $name" >&2
            exit 2
            ;;
    esac

    command+=(
        --label "$name"
        --host 127.0.0.1
        --port 9200
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

    for type in binary text; do
        run_case "$name" "$type" 64 1 32
        run_case "$name" "$type" 1024 1 32
        run_case "$name" "$type" 16384 1 32
        run_case "$name" "$type" 64 10 8
        run_case "$name" "$type" 64 100 8
    done
}

run_matrix linux_event_client
run_matrix mojolicious_client
run_matrix node_ws_client
run_matrix gorilla_client

cleanup_server

echo
echo "Client comparison complete: $output"
