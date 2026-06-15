#!/usr/bin/env python3
"""
Claude Glass bridge - standalone Claude Code → glasses terminal mimic.

Reads Claude Code's OWN transcripts under ~/.claude/projects/<encoded-cwd>/<id>.jsonl
and serves the small HTTP contract the OpenEvenSdk / ClaudeGlass app already speaks:

    GET  /api/projects
    GET  /api/projects/{slug}/agent-sessions
    GET  /api/projects/{slug}/agent-sessions/{id}/transcript?limit=N
    POST /api/projects/{slug}/agent-sessions/{id}/respond     (no-op in standalone)
    POST /api/projects/{slug}/agent-sessions/spawn            (no-op in standalone)

No dependencies (Python 3 stdlib only). No extra services. Read-only: it mirrors the live
Claude Code transcript onto the lens. (Responding to permission prompts is a TTY
interaction Claude Code does not expose to outside processes, so /respond is a
benign no-op here - the terminal mimic is read-only.)

Run:    python3 bridge.py
Then put the printed URL + token into the app's Settings screen.
"""

import json
import os
import re
import secrets
import socket
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs, unquote

ROOT = os.path.expanduser("~/.claude/projects")
PORT = int(os.environ.get("CLAUDE_GLASS_PORT", "8787"))
TOKEN = os.environ.get("CLAUDE_GLASS_TOKEN") or secrets.token_hex(8)
# Only surface real working dirs; skip subagent/temp transcripts.
SKIP = ("orbit-agents", "-private-var-folders", "-tmp-", "-T-")
MAX_SESSIONS = 12


# ---- transcript reading -----------------------------------------------------

def _slug_to_name(slug: str) -> str:
    # "-Users-me-MyProject-main" -> "MyProject/main"
    p = slug.lstrip("-").replace("-", "/")
    base = p.rsplit("/", 2)[-2:] if "/" in p else [p]
    return "/".join(base) if base else p


def _project_dirs():
    """Real project dirs that have at least one .jsonl, newest-active first."""
    out = []
    if not os.path.isdir(ROOT):
        return out
    for name in os.listdir(ROOT):
        d = os.path.join(ROOT, name)
        if not os.path.isdir(d):
            continue
        if any(s in name for s in SKIP):
            continue
        files = [f for f in os.listdir(d) if f.endswith(".jsonl")]
        if not files:
            continue
        mtime = max(os.path.getmtime(os.path.join(d, f)) for f in files)
        out.append((name, mtime))
    out.sort(key=lambda x: x[1], reverse=True)
    return out


def _sessions_for(slug: str):
    d = os.path.join(ROOT, slug)
    if not os.path.isdir(d):
        return []
    rows = []
    for f in os.listdir(d):
        if not f.endswith(".jsonl"):
            continue
        path = os.path.join(d, f)
        try:
            st = os.stat(path)
        except OSError:
            continue
        rows.append((f[:-6], path, st.st_mtime, st.st_ctime))
    rows.sort(key=lambda r: r[2], reverse=True)
    rows = rows[:MAX_SESSIONS]
    now = time.time()
    sessions = []
    for sid, path, mtime, ctime in rows:
        age = now - mtime
        status = "working" if age < 30 else ("idle" if age < 3600 else "done")
        title = _title_for(path) or _slug_to_name(slug)
        sessions.append({
            "id": sid,
            "name": title,
            "title": title,
            "status": status,
            "created_at": int(ctime),
            "pending_action": None,
        })
    return sessions


def _title_for(path: str):
    """First ai-title in the file, if any (cheap scan of the head)."""
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as fh:
            for _ in range(40):
                line = fh.readline()
                if not line:
                    break
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                if d.get("type") == "ai-title":
                    for k in ("title", "content", "text"):
                        v = d.get(k)
                        if isinstance(v, str) and v.strip():
                            return v.strip()[:40]
    except OSError:
        return None
    return None


def _clean(s: str) -> str:
    s = re.sub(r"[─━╭╮│╰╯┌┐└┘]+", " ", s)
    s = re.sub(r"\s+", " ", s)
    return s.strip()


def _flatten(content):
    """A message's content -> list of {role/text/tool} dicts."""
    out = []
    if isinstance(content, str):
        t = _clean(content)
        if t:
            out.append({"text": t})
        return out
    if isinstance(content, list):
        for b in content:
            if not isinstance(b, dict):
                continue
            bt = b.get("type")
            if bt == "text":
                t = _clean(b.get("text", ""))
                if t:
                    out.append({"text": t})
            elif bt == "tool_use":
                name = b.get("name", "tool")
                inp = b.get("input", {})
                arg = ""
                if isinstance(inp, dict):
                    arg = _clean(str(inp.get("command")
                                     or inp.get("file_path")
                                     or inp.get("path")
                                     or inp.get("pattern") or ""))[:40]
                out.append({"tool": name, "text": arg})
            elif bt == "tool_result":
                c = b.get("content", "")
                if isinstance(c, list):
                    c = " ".join(x.get("text", "") for x in c if isinstance(x, dict))
                t = _clean(str(c))[:60]
                if t:
                    out.append({"tool": "result", "text": "→ " + t})
    return out


def _transcript(slug: str, sid: str, limit: int):
    path = os.path.join(ROOT, slug, sid + ".jsonl")
    if not os.path.isfile(path):
        return {"messages": [], "found": False}
    msgs = []
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                if d.get("type") not in ("user", "assistant"):
                    continue
                m = d.get("message")
                if not isinstance(m, dict):
                    continue
                role = m.get("role", d.get("type"))
                for part in _flatten(m.get("content")):
                    role_out = "tool" if "tool" in part else role
                    msgs.append({
                        "role": role_out,
                        "text": part.get("text", ""),
                        "tool": part.get("tool"),
                    })
    except OSError:
        return {"messages": [], "found": False}
    return {"messages": msgs[-limit:], "found": True}


# ---- HTTP -------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass  # quiet

    def _send(self, obj, code=200):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _auth_ok(self):
        if not TOKEN:
            return True
        return self.headers.get("Authorization", "") == f"Bearer {TOKEN}"

    def do_GET(self):
        if not self._auth_ok():
            return self._send({"error": "unauthorized"}, 401)
        u = urlparse(self.path)
        parts = [unquote(p) for p in u.path.strip("/").split("/")]
        # /api/projects
        if parts == ["api", "projects"]:
            return self._send([{"slug": s, "name": _slug_to_name(s)} for s, _ in _project_dirs()])
        # /api/projects/{slug}/agent-sessions[/{id}/transcript]
        if len(parts) >= 4 and parts[0] == "api" and parts[1] == "projects" and parts[3] == "agent-sessions":
            slug = parts[2]
            if len(parts) == 4:
                return self._send(_sessions_for(slug))
            if len(parts) == 6 and parts[5] == "transcript":
                q = parse_qs(u.query)
                limit = max(1, min(int((q.get("limit") or ["30"])[0]), 200))
                return self._send(_transcript(slug, parts[4], limit))
        self._send({"error": "not found", "path": u.path}, 404)

    def do_POST(self):
        if not self._auth_ok():
            return self._send({"error": "unauthorized"}, 401)
        parts = [unquote(p) for p in urlparse(self.path).path.strip("/").split("/")]
        # respond / spawn - no-op in read-only standalone mode (return a valid Session)
        if "agent-sessions" in parts:
            sid = parts[parts.index("agent-sessions") + 1] if parts[-1] in ("respond", "spawn") else (parts[-1] if parts[-1] != "agent-sessions" else "standalone")
            return self._send({"id": sid, "status": "idle"})
        self._send({"error": "not found"}, 404)


def _show_qr(payload: str) -> bool:
    """Best-effort: on macOS, render a QR PNG (CoreImage via `swift`) for the
    config payload and open it so the app can scan it. No-op / harmless if swift
    isn't available - the URL+token are printed regardless."""
    import shutil, subprocess, tempfile
    if not shutil.which("swift"):
        return False
    swift = r'''
import Foundation
#if canImport(AppKit)
import AppKit
import CoreImage
let msg = CommandLine.arguments[1].data(using: .utf8)!
guard let f = CIFilter(name: "CIQRCodeGenerator") else { exit(1) }
f.setValue(msg, forKey: "inputMessage")
f.setValue("M", forKey: "inputCorrectionLevel")
guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)) else { exit(1) }
let rep = NSBitmapImageRep(ciImage: out)
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: "/tmp/claude-glass-qr.png"))
#endif
'''
    try:
        tf = tempfile.NamedTemporaryFile(suffix=".swift", delete=False, mode="w")
        tf.write(swift); tf.close()
        subprocess.run(["swift", tf.name, payload], check=True, timeout=90,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["open", "/tmp/claude-glass-qr.png"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return True
    except Exception:
        return False


def _lan_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except OSError:
        return "127.0.0.1"


def main():
    ip = _lan_ip()
    n = len(_project_dirs())
    print("=" * 56)
    print("  Claude Glass bridge - standalone (no extra services)")
    print("=" * 56)
    print(f"  reading   : {ROOT}")
    print(f"  projects  : {n} active")
    print()
    payload = json.dumps({"url": f"http://{ip}:{PORT}", "token": TOKEN})
    print("  In the app's Settings → Scan QR (or type these):")
    print(f"    URL   :  http://{ip}:{PORT}")
    print(f"    Token :  {TOKEN}")
    print()
    if _show_qr(payload):
        print("  ✓ QR opened on screen - scan it in the app (Settings → Scan QR).")
    else:
        print("  (QR auto-open unavailable - type the URL/token above.)")
    print()
    print("  (phone + Mac must be on the same Wi-Fi)")
    print("  Ctrl-C to stop.")
    print("=" * 56)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nbridge stopped.")
