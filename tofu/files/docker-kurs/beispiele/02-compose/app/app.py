"""Kleine Web-App: zaehlt Aufrufe in Redis."""

import os
import socket
from http.server import BaseHTTPRequestHandler, HTTPServer

import redis

db = redis.Redis(host=os.environ.get("REDIS_HOST", "localhost"), port=6379)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        aufrufe = db.incr("aufrufe")
        text = f"Hallo! Aufruf Nr. {aufrufe} - beantwortet von Container {socket.gethostname()}\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.end_headers()
        self.wfile.write(text.encode())


if __name__ == "__main__":
    print("Web-App laeuft auf Port 5000", flush=True)
    HTTPServer(("0.0.0.0", 5000), Handler).serve_forever()
