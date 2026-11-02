#!/usr/bin/env python3
"""A JSON-RPC listener that notes each request's method, never its parameters."""
import http.server
import json
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers.get("content-length", 0))))
        with open(sys.argv[2], "a") as log:
            print(request.get("method"), file=log)
        body = json.dumps({"jsonrpc": "2.0", "result": "0", "id": request.get("id")}).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
