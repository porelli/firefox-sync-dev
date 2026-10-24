"""A webhook receiver for the end-to-end tests: the destinations of ADMIN_NOTIFY in the
test stacks (tests/compose/sync.yml, tests/compose/fxa.yml).

Records every POST and PUT (method, path, headers, body) and answers 200, 500 under /fail.
GET /_received: the requests as JSON, oldest first; DELETE /_received: forgets them.
"""

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

RECEIVED = []
LOCK = threading.Lock()


class Sink(BaseHTTPRequestHandler):
    def record(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode("utf-8", "replace")
        with LOCK:
            RECEIVED.append({"method": self.command, "path": self.path, "headers": dict(self.headers.items()), "body": body})
        self.answer(500 if self.path.startswith("/fail") else 200, b"ok")

    do_POST = do_PUT = record

    def answer(self, status, body, kind="text/plain"):
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path != "/_received":
            return self.answer(404, b"not found")
        with LOCK:
            body = json.dumps(RECEIVED).encode()
        self.answer(200, body, "application/json")

    def do_DELETE(self):
        with LOCK:
            RECEIVED.clear()
        self.answer(204, b"")

    def log_message(self, *args):
        pass


ThreadingHTTPServer(("", 8000), Sink).serve_forever()
