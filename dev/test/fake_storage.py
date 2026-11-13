"""In-memory stand-in for Cloudflare R2 and the GitHub API, used by run-tests.ps1.

It checks that storage requests carry a signature, not that the signature is valid
(sm-sync.ps1 -Action selftest covers the signing maths). It implements the conditional
writes the tool relies on: If-Match and If-None-Match on PUT.

usage: fake_storage.py <port> [zip served as the v9.9.9 release]
"""
import hashlib
import json
import sys
from urllib.parse import parse_qs, urlsplit
from xml.sax.saxutils import escape
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STORE = {}
ZIP = sys.argv[2] if len(sys.argv) > 2 else None


def etag(data):
    return '"' + hashlib.md5(data).hexdigest() + '"'


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _signed(self):
        ok = self.headers.get("Authorization", "").startswith("AWS4-HMAC-SHA256") and self.headers.get("x-amz-date")
        if not ok:
            self._reply(403, b"<Error><Code>AccessDenied</Code></Error>")
        return ok

    def _reply(self, status, body=b"", length=None, send_body=True, tag=None):
        self.send_response(status)
        self.send_header("Content-Length", str(len(body) if length is None else length))
        if tag:
            self.send_header("ETag", tag)
        self.end_headers()
        if send_body:
            self.wfile.write(body)

    def do_PUT(self):
        data = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if not self._signed():
            return
        current = STORE.get(self.path)
        if self.headers.get("If-None-Match") == "*" and current is not None:
            return self._reply(412, b"<Error><Code>PreconditionFailed</Code></Error>")
        wanted = self.headers.get("If-Match")
        if wanted and (current is None or etag(current) != wanted):
            return self._reply(412, b"<Error><Code>PreconditionFailed</Code></Error>")
        STORE[self.path] = data
        self._reply(200, tag=etag(data))

    def do_DELETE(self):
        if self._signed():
            STORE.pop(self.path, None)
            self._reply(204)

    def do_GET(self):
        if self.path == "/_keys":
            return self._reply(200, "\n".join(sorted(STORE)).encode())
        if self.path.startswith("/repos/"):
            # A public repository: no key needed, but a stale key is refused the way GitHub does.
            if self.headers.get("Authorization") not in (None, "Bearer good-token"):
                return self._reply(401, b"{}")
            if "/tags" in self.path:
                return self._reply(200, json.dumps([{"name": "v0.0.1"}, {"name": "v9.9.9"}, {"name": "junk"}]).encode())
            if self.path.endswith("/zipball/v9.9.9") and ZIP:
                with open(ZIP, "rb") as f:
                    return self._reply(200, f.read())
            return self._reply(404, b"{}")
        parts = urlsplit(self.path)
        query = parse_qs(parts.query)
        if query.get("list-type") == ["2"]:
            # ListObjectsV2: /<bucket>?list-type=2&prefix=...
            if not self._signed():
                return
            start = parts.path.rstrip("/") + "/"
            prefix = query.get("prefix", [""])[0]
            keys = sorted(k[len(start):] for k in STORE if k.startswith(start) and k[len(start):].startswith(prefix))
            body = "<ListBucketResult>" + "".join("<Contents><Key>%s</Key></Contents>" % escape(k) for k in keys) + "</ListBucketResult>"
            return self._reply(200, body.encode())
        if self._signed():
            if self.path in STORE:
                self._reply(200, STORE[self.path], tag=etag(STORE[self.path]))
            else:
                self._reply(404, b"<Error><Code>NoSuchKey</Code></Error>")

    def do_HEAD(self):
        if self._signed():
            if self.path in STORE:
                self._reply(200, length=len(STORE[self.path]), send_body=False, tag=etag(STORE[self.path]))
            else:
                self._reply(404, send_body=False)


ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
