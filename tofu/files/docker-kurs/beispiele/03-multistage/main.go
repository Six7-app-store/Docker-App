package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
)

func main() {
	host, _ := os.Hostname()
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "Hallo aus Go! Container %s\n", host)
	})
	log.Println("Server laeuft auf Port 8080")
	log.Fatal(http.ListenAndServe(":8080", nil))
}
