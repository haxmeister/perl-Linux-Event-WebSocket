package main

import (
	"flag"
	"fmt"
	"net/url"
	"os"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
)

func main() {
	label := flag.String("label", "gorilla_client", "result label")
	host := flag.String("host", "127.0.0.1", "server host")
	port := flag.Int("port", 9200, "server port")
	messageTypeName := flag.String("type", "binary", "text or binary")
	bytes := flag.Int("bytes", 64, "payload bytes")
	clients := flag.Int("clients", 1, "connection count")
	window := flag.Int("window", 32, "messages in flight per connection")
	warmup := flag.Float64("warmup", 0.5, "warmup seconds")
	seconds := flag.Float64("seconds", 1.5, "measurement seconds")
	flag.Parse()

	if *messageTypeName != "text" && *messageTypeName != "binary" {
		fmt.Fprintln(os.Stderr, "--type must be text or binary")
		os.Exit(2)
	}
	if *bytes < 1 || *clients < 1 || *window < 1 || *warmup < 0 || *seconds <= 0 {
		fmt.Fprintln(os.Stderr, "invalid benchmark option")
		os.Exit(2)
	}

	messageType := websocket.BinaryMessage
	if *messageTypeName == "text" {
		messageType = websocket.TextMessage
	}

	payload := make([]byte, *bytes)
	for i := range payload {
		payload[i] = 'x'
	}

	u := url.URL{
		Scheme:   "ws",
		Host:     fmt.Sprintf("%s:%d", *host, *port),
		Path:     "/benchmark",
		RawQuery: "type=" + *messageTypeName,
	}

	dialer := websocket.Dialer{
		HandshakeTimeout:  10 * time.Second,
		EnableCompression: false,
	}

	connections := make([]*websocket.Conn, 0, *clients)
	for i := 0; i < *clients; i++ {
		conn, _, err := dialer.Dial(u.String(), nil)
		if err != nil {
			fmt.Fprintf(os.Stderr, "connect failed: %v\n", err)
			os.Exit(1)
		}
		connections = append(connections, conn)
	}

	var count atomic.Int64
	var measuring atomic.Bool
	var stopping atomic.Bool
	errCh := make(chan error, 1)
	var wg sync.WaitGroup

	reportError := func(err error) {
		select {
		case errCh <- err:
		default:
		}
	}

	for _, conn := range connections {
		wg.Add(1)
		go func(conn *websocket.Conn) {
			defer wg.Done()

			for i := 0; i < *window; i++ {
				if err := conn.WriteMessage(messageType, payload); err != nil {
					reportError(err)
					return
				}
			}

			for {
				gotType, gotPayload, err := conn.ReadMessage()
				if err != nil {
					if !stopping.Load() {
						reportError(err)
					}
					return
				}

				if gotType != messageType {
					reportError(fmt.Errorf("message type mismatch"))
					return
				}
				if len(gotPayload) != *bytes {
					reportError(fmt.Errorf("message size mismatch"))
					return
				}

				if measuring.Load() {
					count.Add(1)
				}

				if err := conn.WriteMessage(messageType, payload); err != nil {
					if !stopping.Load() {
						reportError(err)
					}
					return
				}
			}
		}(conn)
	}

	warmupTimer := time.NewTimer(time.Duration(*warmup * float64(time.Second)))
	select {
	case err := <-errCh:
		fmt.Fprintf(os.Stderr, "warmup failed: %v\n", err)
		os.Exit(1)
	case <-warmupTimer.C:
	}

	count.Store(0)
	start := time.Now()
	measuring.Store(true)

	measureTimer := time.NewTimer(time.Duration(*seconds * float64(time.Second)))
	select {
	case err := <-errCh:
		fmt.Fprintf(os.Stderr, "benchmark failed: %v\n", err)
		os.Exit(1)
	case <-measureTimer.C:
	}

	measuring.Store(false)
	elapsed := time.Since(start).Seconds()
	stopping.Store(true)

	for _, conn := range connections {
		_ = conn.Close()
	}
	wg.Wait()

	messages := count.Load()
	rate := float64(messages) / elapsed
	mib := rate * float64(*bytes) / (1024 * 1024)

	fmt.Printf("%s,%s,%d,%d,%d,%d,%.6f,%.0f,%.2f\n",
		*label, *messageTypeName, *bytes, *clients, *window,
		messages, elapsed, rate, mib)
}
