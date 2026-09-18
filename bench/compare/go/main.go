package main

import (
	"fmt"
	"log"
	"net/http"
	"os"

	"github.com/gorilla/websocket"
)

var upgrader = websocket.Upgrader{
	ReadBufferSize:    4096,
	WriteBufferSize:   4096,
	EnableCompression: false,
	CheckOrigin: func(r *http.Request) bool {
		return true
	},
}

func benchmark(w http.ResponseWriter, r *http.Request) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	defer conn.Close()
	conn.SetReadLimit(32 * 1024 * 1024)

	for {
		messageType, payload, err := conn.ReadMessage()
		if err != nil {
			return
		}
		if err := conn.WriteMessage(messageType, payload); err != nil {
			return
		}
	}
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "9104"
	}

	log.SetOutput(os.Stderr)
	http.HandleFunc("/benchmark", benchmark)
	fmt.Printf("READY 127.0.0.1:%s\n", port)

	server := &http.Server{
		Addr: "127.0.0.1:" + port,
	}
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
}
