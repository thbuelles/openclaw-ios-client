#!/usr/bin/env python3
from __future__ import annotations

import base64
import json
import os
import shutil
import subprocess
from datetime import datetime
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = "0.0.0.0"
PORT = 8787
OPENCLAW_BIN = shutil.which("openclaw") or "/usr/local/bin/openclaw"
RUN_PATH = ":".join([
    "/usr/local/bin",
    "/opt/homebrew/bin",
    "/usr/bin",
    "/bin",
    "/usr/sbin",
    "/sbin",
])
UPLOAD_DIR = Path("/Users/bici/.openclaw/workspace/thb-bici/ios-ui/uploads")
UPLOAD_DIR.mkdir(parents=True, exist_ok=True)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format: str, *args):
        print(f"[bridge] {self.address_string()} - {format % args}")

    def _send(self, code: int, payload: dict):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self._send(200, {"ok": True, "service": "chat-bridge", "openclawBin": OPENCLAW_BIN, "path": RUN_PATH})
            return
        self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/chat":
            self._send(404, {"error": "not found"})
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length)
            req = json.loads(raw.decode("utf-8"))

            text = str(req.get("text", "")).strip()
            session = str(req.get("session", "ios-ui")).strip() or "ios-ui"
            image_b64 = req.get("imageBase64")
            image_mime = str(req.get("imageMimeType", "image/jpeg")).strip() or "image/jpeg"

            if not text and not image_b64:
                self._send(400, {"error": "empty text"})
                return

            if image_b64:
                ext = "jpg" if "jpeg" in image_mime else "png"
                stamp = datetime.utcnow().strftime("%Y%m%d-%H%M%S-%f")
                image_path = UPLOAD_DIR / f"photo-{stamp}.{ext}"

                payload = image_b64.split(",", 1)[-1]
                image_data = base64.b64decode(payload)
                image_path.write_bytes(image_data)

                instruction = (
                    "User attached an image. Please inspect it with the read tool at this exact path and include visual details in your answer.\n"
                    f"Image path: {image_path}\n"
                )
                text = (text + "\n\n" + instruction).strip() if text else instruction

            cmd = [
                OPENCLAW_BIN,
                "agent",
                "--agent",
                "main",
                "--session-id",
                session,
                "--message",
                text,
                "--thinking",
                "minimal",
                "--timeout",
                "45",
                "--json",
            ]

            env = os.environ.copy()
            env["PATH"] = RUN_PATH + (":" + env["PATH"] if env.get("PATH") else "")
            p = subprocess.run(cmd, capture_output=True, text=True, timeout=55, env=env)
            out = (p.stdout or "").strip()
            err = (p.stderr or "").strip()

            if p.returncode != 0:
                self._send(500, {"reply": f"openclaw error: {err or out or 'unknown'}"})
                return

            reply = out
            try:
                parsed = json.loads(out)

                payloads = (((parsed.get("result") or {}).get("payloads")) or [])
                payload_text = None
                if isinstance(payloads, list) and payloads:
                    first = payloads[0]
                    if isinstance(first, dict):
                        payload_text = first.get("text")

                reply = (
                    payload_text
                    or parsed.get("reply")
                    or parsed.get("message")
                    or parsed.get("output")
                    or out
                )
            except Exception:
                pass

            self._send(200, {"reply": reply if str(reply).strip() else "(no reply)"})
        except subprocess.TimeoutExpired:
            self._send(
                504,
                {
                    "reply": "bridge timeout waiting for openclaw. try: openclaw gateway start",
                },
            )
        except Exception as e:
            self._send(500, {"reply": f"bridge exception: {e}"})


def main():
    print(f"chat bridge listening on http://{HOST}:{PORT}")
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
