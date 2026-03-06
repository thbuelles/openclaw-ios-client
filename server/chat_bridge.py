#!/usr/bin/env python3
from __future__ import annotations

import base64
import json
import os
import shutil
import subprocess
import time
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib import error as urlerror
from urllib import request as urlrequest
from urllib.parse import parse_qs, urlparse

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
UPLOAD_DIR = Path("/Users/bici/.openclaw/workspace/thb-bici/openclaw-ios-client/uploads")
UPLOAD_DIR.mkdir(parents=True, exist_ok=True)

PUSH_REG_PATH = Path("/Users/bici/.openclaw/workspace/.secrets/ios_push_devices.json")
PUSH_REG_PATH.parent.mkdir(parents=True, exist_ok=True)

EVENTS_PATH = Path("/Users/bici/.openclaw/workspace/.secrets/ios_events.jsonl")
EVENTS_PATH.parent.mkdir(parents=True, exist_ok=True)
MAX_EVENTS = 1000


def _load_push_registry() -> list[dict]:
    if not PUSH_REG_PATH.exists():
        return []
    try:
        data = json.loads(PUSH_REG_PATH.read_text())
        if isinstance(data, list):
            return [x for x in data if isinstance(x, dict)]
    except Exception:
        pass
    return []


def _save_push_registry(items: list[dict]) -> None:
    PUSH_REG_PATH.write_text(json.dumps(items, indent=2) + "\n")


def _upsert_push_token(token: str, app_version: str, os_version: str, remote_ip: str) -> None:
    token = token.strip().lower()
    if not token:
        return
    items = _load_push_registry()
    now = datetime.utcnow().isoformat() + "Z"
    found = False
    for item in items:
        if item.get("deviceToken") == token:
            item["appVersion"] = app_version
            item["osVersion"] = os_version
            item["lastSeenAt"] = now
            item["lastSeenFrom"] = remote_ip
            found = True
            break
    if not found:
        items.append(
            {
                "deviceToken": token,
                "appVersion": app_version,
                "osVersion": os_version,
                "registeredAt": now,
                "lastSeenAt": now,
                "lastSeenFrom": remote_ip,
            }
        )
    _save_push_registry(items)


def _make_apns_jwt() -> str:
    key_id = os.environ.get("APNS_KEY_ID", "").strip()
    team_id = os.environ.get("APNS_TEAM_ID", "").strip()
    key_path = os.environ.get("APNS_PRIVATE_KEY_PATH", "").strip()

    if not key_id or not team_id or not key_path:
        raise RuntimeError("missing APNS_KEY_ID/APNS_TEAM_ID/APNS_PRIVATE_KEY_PATH")

    try:
        import jwt  # type: ignore
    except Exception as exc:
        raise RuntimeError("missing dependency: pyjwt[crypto]") from exc

    private_key = Path(key_path).read_text()
    now = int(time.time())
    token = jwt.encode(
        {"iss": team_id, "iat": now},
        private_key,
        algorithm="ES256",
        headers={"alg": "ES256", "kid": key_id},
    )
    return token


def _send_apns_push(device_token: str, title: str, body: str) -> None:
    topic = os.environ.get("APNS_TOPIC", "").strip()
    if not topic:
        raise RuntimeError("missing APNS_TOPIC (your app bundle id)")

    auth = _make_apns_jwt()
    payload = {
        "aps": {
            "alert": {"title": title, "body": body},
            "sound": "default",
            "badge": 1,
        }
    }

    req = urlrequest.Request(
        url=f"https://api.push.apple.com/3/device/{device_token}",
        data=json.dumps(payload).encode("utf-8"),
        method="POST",
        headers={
            "authorization": f"bearer {auth}",
            "apns-topic": topic,
            "apns-push-type": "alert",
            "content-type": "application/json",
        },
    )
    try:
        with urlrequest.urlopen(req, timeout=10) as resp:
            if resp.status // 100 != 2:
                raise RuntimeError(f"APNs status {resp.status}")
    except urlerror.HTTPError as exc:
        details = exc.read().decode("utf-8", errors="ignore") if exc.fp else ""
        raise RuntimeError(f"APNs HTTPError {exc.code}: {details}") from exc


def _load_events() -> list[dict]:
    if not EVENTS_PATH.exists():
        return []
    rows: list[dict] = []
    try:
        for line in EVENTS_PATH.read_text().splitlines():
            if not line.strip():
                continue
            row = json.loads(line)
            if isinstance(row, dict):
                rows.append(row)
    except Exception:
        return []
    return rows


def _append_event(*, event_type: str, title: str, message: str, session: str | None = None) -> dict:
    ts = datetime.utcnow().isoformat() + "Z"
    event_id = f"{int(time.time() * 1000)}-{os.urandom(3).hex()}"
    row = {
        "id": event_id,
        "ts": ts,
        "type": event_type,
        "title": title,
        "message": message,
        "session": session,
    }

    events = _load_events()
    events.append(row)
    if len(events) > MAX_EVENTS:
        events = events[-MAX_EVENTS:]

    EVENTS_PATH.write_text("\n".join(json.dumps(x) for x in events) + "\n")
    return row


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
        parsed = urlparse(self.path)

        if parsed.path == "/health":
            self._send(
                200,
                {
                    "ok": True,
                    "service": "chat-bridge",
                    "openclawBin": OPENCLAW_BIN,
                    "path": RUN_PATH,
                    "pushRegisteredDevices": len(_load_push_registry()),
                },
            )
            return

        if parsed.path == "/events":
            since = (parse_qs(parsed.query).get("since") or [""])[0].strip()
            events = _load_events()
            if since:
                idx = next((i for i, row in enumerate(events) if str(row.get("id", "")) == since), -1)
                if idx >= 0:
                    events = events[idx + 1 :]
            self._send(200, {"events": events})
            return

        self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path == "/register_push":
            try:
                length = int(self.headers.get("Content-Length", "0"))
                raw = self.rfile.read(length)
                req = json.loads(raw.decode("utf-8"))
                token = str(req.get("deviceToken", "")).strip()
                if not token:
                    self._send(400, {"ok": False, "error": "missing deviceToken"})
                    return

                _upsert_push_token(
                    token=token,
                    app_version=str(req.get("appVersion", "")).strip() or "unknown",
                    os_version=str(req.get("osVersion", "")).strip() or "unknown",
                    remote_ip=self.client_address[0],
                )
                self._send(200, {"ok": True, "registered": len(_load_push_registry())})
                return
            except Exception as e:
                self._send(500, {"ok": False, "error": str(e)})
                return

        if self.path == "/push":
            try:
                admin_token = os.environ.get("PUSH_ADMIN_TOKEN", "").strip()
                if admin_token:
                    header = self.headers.get("X-Push-Token", "").strip()
                    if header != admin_token:
                        self._send(401, {"ok": False, "error": "unauthorized"})
                        return

                length = int(self.headers.get("Content-Length", "0"))
                raw = self.rfile.read(length)
                req = json.loads(raw.decode("utf-8"))
                title = str(req.get("title", "bici")).strip() or "bici"
                message = str(req.get("message", "")).strip()
                if not message:
                    self._send(400, {"ok": False, "error": "missing message"})
                    return

                devices = _load_push_registry()
                if not devices:
                    self._send(200, {"ok": True, "sent": 0, "errors": ["no registered devices"]})
                    return

                sent = 0
                errors: list[str] = []
                for item in devices:
                    token = str(item.get("deviceToken", "")).strip()
                    if not token:
                        continue
                    try:
                        _send_apns_push(token, title=title, body=message)
                        sent += 1
                    except Exception as exc:
                        errors.append(str(exc))

                _append_event(
                    event_type="push",
                    title=title,
                    message=message,
                    session=None,
                )

                self._send(200, {"ok": True, "sent": sent, "errors": errors})
                return
            except Exception as e:
                self._send(500, {"ok": False, "error": str(e)})
                return

        if self.path != "/chat":
            self._send(404, {"error": "not found"})
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length)
            req = json.loads(raw.decode("utf-8"))

            text = str(req.get("text", "")).strip()
            # Avoid lock contention on a single shared session file.
            # If client does not provide a session id, use a per-request one.
            session = str(req.get("session", "")).strip()
            if not session:
                session = f"ios-ui-{datetime.utcnow().strftime('%Y%m%d%H%M%S%f')}"
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
                "60",
                "--json",
            ]

            env = os.environ.copy()
            env["PATH"] = RUN_PATH + (":" + env["PATH"] if env.get("PATH") else "")
            p = subprocess.run(cmd, capture_output=True, text=True, timeout=75, env=env)
            out = (p.stdout or "").strip()
            err = (p.stderr or "").strip()

            if p.returncode != 0 and "session file locked" in f"{out}\n{err}":
                # Retry once with a fresh session id to avoid lock contention.
                retry_session = f"{session}-retry-{datetime.utcnow().strftime('%H%M%S%f')}"
                retry_cmd = cmd.copy()
                try:
                    idx = retry_cmd.index("--session-id")
                    retry_cmd[idx + 1] = retry_session
                except Exception:
                    pass
                p = subprocess.run(retry_cmd, capture_output=True, text=True, timeout=75, env=env)
                out = (p.stdout or "").strip()
                err = (p.stderr or "").strip()

            if p.returncode != 0:
                # Return 200 so iOS UI can show the message instead of generic NSURLError -1011.
                failure_reply = f"openclaw error: {err or out or 'unknown'}"
                _append_event(
                    event_type="assistant_error",
                    title="bici",
                    message=failure_reply,
                    session=session,
                )
                self._send(200, {"reply": failure_reply})
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

            final_reply = reply if str(reply).strip() else "(no reply)"
            _append_event(
                event_type="assistant_reply",
                title="bici",
                message=final_reply,
                session=session,
            )
            self._send(200, {"reply": final_reply})
        except subprocess.TimeoutExpired:
            # Return 200 so client can render a readable timeout message.
            self._send(
                200,
                {
                    "reply": "bridge timeout waiting for openclaw. try again, or run: openclaw gateway start",
                },
            )
        except Exception as e:
            self._send(500, {"reply": f"bridge exception: {e}"})


def main():
    print(f"chat bridge listening on http://{HOST}:{PORT}")
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
