#!/usr/bin/env python3
"""Local settings UI for the RP425 driver.

Reads the options from the queue's PPD (so the UI never drifts from the driver),
shows/saves your per-user defaults with lpoptions, and exposes the rp425 tool's
printer actions. Stdlib only; listens on 127.0.0.1.

    python3 ui/server.py [--queue RP425] [--port 8425]
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PPD_CANDIDATES = ["/etc/cups/ppd/{queue}.ppd", os.path.join(ROOT, "ppd", "RP425.ppd")]
ACTIONS = {"calibrate": "Calibrate", "feed": "Feed one label", "config": "Print config label", "cancel": "Cancel buffered jobs"}
CUSTOM_SIZE = re.compile(r"^Custom\.(\d+(\.\d+)?)x(\d+(\.\d+)?)(in|mm|cm|pt)$")
SKIP = {"ColorModel", "Resolution"}  # single-choice, nothing to change


def run(cmd, stdin=None, timeout=60):
    p = subprocess.run(cmd, input=stdin, capture_output=True, text=True, timeout=timeout)
    return p.returncode, (p.stdout + p.stderr).strip()


def find_rp425():
    for c in (shutil.which("rp425"), os.path.join(ROOT, "build", "rp425")):
        if c and os.path.exists(c):
            return c


def parse_ppd(queue):
    """Returns ordered [{key, label, choices: [{value, label}], default}] from the PPD."""
    path = next((p.format(queue=queue) for p in PPD_CANDIDATES if os.access(p.format(queue=queue), os.R_OK)), None)
    if not path:
        sys.exit("no readable PPD found")
    opts, cur, defaults = [], None, {}
    with open(path, encoding="latin-1") as f:
        for line in f:
            if m := re.match(r"\*Default(\w+): (\S+)", line):
                defaults[m.group(1)] = m.group(2)
            elif m := re.match(r"\*OpenUI \*(\w+)/([^:]*): (\w+)", line):
                cur = {"key": m.group(1), "label": m.group(2), "type": m.group(3), "choices": []}
            elif line.startswith("*CloseUI"):
                if cur and cur["key"] not in SKIP:
                    opts.append(cur)
                cur = None
            elif cur and (m := re.match(r"\*%s (\S+?)/([^:]*):" % cur["key"], line)):
                cur["choices"].append({"value": m.group(1), "label": m.group(2)})
    for o in opts:
        o["default"] = defaults.get(o["key"])
    return opts


def current_values(queue):
    """The effective defaults for this user: PPD defaults overlaid with lpoptions."""
    rc, out = run(["lpoptions", "-p", queue, "-l"])
    vals = {}
    for line in out.splitlines():
        m = re.match(r"(\w+)/[^:]*:\s*(.*)", line)
        if m and (s := re.search(r"\*(\S+)", m.group(2))):
            vals[m.group(1)] = s.group(1)
    # -l prints a placeholder for custom sizes; the plain listing has the real values.
    for k, v in re.findall(r"(\w+)=(\S+)", run(["lpoptions", "-p", queue])[1]):
        if k in vals:
            vals[k] = v
    return vals


def validate(opts, values):
    """Only accept option/value pairs the PPD declares (plus a bounded custom size)."""
    known = {o["key"]: {c["value"] for c in o["choices"]} for o in opts}
    clean = {}
    for k, v in values.items():
        if k not in known:
            raise ValueError("unknown option %r" % k)
        if v in known[k] or (k == "PageSize" and CUSTOM_SIZE.match(v)):
            clean[k] = v
        else:
            raise ValueError("bad value %r for %s" % (v, k))
    return clean


class Handler(BaseHTTPRequestHandler):
    queue = "RP425"
    opts = []
    port = 0

    def log_message(self, *a):
        pass

    def reply(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def trusted(self):
        # Refuse DNS-rebinding and cross-site POSTs: this server can drive a printer.
        ok = {"127.0.0.1:%d" % self.port, "localhost:%d" % self.port}
        if self.headers.get("Host") not in ok:
            return False
        origin = self.headers.get("Origin")
        return origin is None or origin.split("://", 1)[-1] in ok

    def do_GET(self):
        if not self.trusted():
            return self.reply(403, {"error": "forbidden"})
        path = urlparse(self.path).path
        if path == "/":
            with open(os.path.join(HERE, "index.html"), "rb") as f:
                return self.reply(200, f.read(), "text/html; charset=utf-8")
        if path == "/api/state":
            rc, status = run(["lpstat", "-p", self.queue])
            return self.reply(200, {
                "queue": self.queue, "queueStatus": status if rc == 0 else "queue not found: " + status,
                "options": self.opts, "values": current_values(self.queue),
                "actions": ACTIONS, "hasTool": find_rp425() is not None,
            })
        self.reply(404, {"error": "not found"})

    def do_POST(self):
        if not self.trusted():
            return self.reply(403, {"error": "forbidden"})
        url = urlparse(self.path)
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        try:
            if url.path == "/api/save":
                values = validate(self.opts, json.loads(body))
                args = [a for k, v in values.items() for a in ("-o", "%s=%s" % (k, v))]
                rc, out = run(["lpoptions", "-p", self.queue] + args)
                return self.reply(200 if rc == 0 else 500, {"ok": rc == 0, "output": out or "Saved to ~/.cups/lpoptions"})
            if url.path == "/api/reset":
                args = [a for o in self.opts for a in ("-r", o["key"])]
                rc, out = run(["lpoptions", "-p", self.queue] + args)
                return self.reply(200, {"ok": rc == 0, "output": out or "Back to driver defaults"})
            if url.path.startswith("/api/action/"):
                name = url.path.rsplit("/", 1)[1]
                tool = find_rp425()
                if name not in ACTIONS or not tool:
                    return self.reply(400, {"ok": False, "output": "unknown action or rp425 tool not installed"})
                rc, out = run([tool, name])
                return self.reply(200, {"ok": rc == 0, "output": out or "Done"})
            if url.path == "/api/print":
                q = parse_qs(url.query)
                values = validate(self.opts, json.loads(q.get("options", ["{}"])[0]))
                copies = max(1, min(int(q.get("copies", ["1"])[0]), 99))
                suffix = os.path.splitext(q.get("name", [""])[0])[1][:8] or ".bin"
                if not re.match(r"^\.\w+$", suffix):
                    suffix = ".bin"
                with tempfile.TemporaryDirectory() as d:
                    fn = os.path.join(d, "label" + suffix)
                    with open(fn, "wb") as f:
                        f.write(body)
                    args = [a for k, v in values.items() for a in ("-o", "%s=%s" % (k, v))]
                    if q.get("raw", [""])[0]:
                        args += ["-o", "raw"]
                    rc, out = run(["lp", "-d", self.queue, "-n", str(copies), "-t", "RP425 UI"] + args + [fn])
                return self.reply(200 if rc == 0 else 500, {"ok": rc == 0, "output": out})
        except (ValueError, json.JSONDecodeError) as e:
            return self.reply(400, {"ok": False, "output": str(e)})
        except subprocess.TimeoutExpired:
            return self.reply(504, {"ok": False, "output": "command timed out"})
        self.reply(404, {"error": "not found"})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--queue", default="RP425")
    ap.add_argument("--port", type=int, default=8425)
    ap.add_argument("--no-open", action="store_true")
    a = ap.parse_args()
    Handler.queue, Handler.opts, Handler.port = a.queue, parse_ppd(a.queue), a.port
    srv = ThreadingHTTPServer(("127.0.0.1", a.port), Handler)
    url = "http://127.0.0.1:%d/" % a.port
    print("RP425 settings UI at", url, "(Ctrl-C to stop)")
    if not a.no_open:
        webbrowser.open(url)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
