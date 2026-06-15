#!/usr/bin/env python3
"""
Claude Glass bridge - SDK-owned sessions (start / dictate / approve) over the
same stdlib HTTP contract the app already speaks. No extra services.

The bridge OWNS the Claude Code sessions it starts (via the Claude Agent SDK), so
it can stream output, send follow-up prompts (dictation), and - crucially - pause
on a tool-permission request and resume on the user's Allow/Deny from the glasses.

Requires:  pip3 install claude-agent-sdk   (needs the `claude` CLI on PATH + logged in)
Run:       CLAUDE_GLASS_CWD=/path/to/repo python3 bridge_sdk.py
"""
import asyncio, json, os, secrets, threading, time, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs, unquote

from claude_agent_sdk import (
    ClaudeSDKClient, ClaudeAgentOptions,
    PermissionResultAllow, PermissionResultDeny,
    AssistantMessage, UserMessage, ResultMessage, SystemMessage,
    TextBlock, ToolUseBlock, ToolResultBlock,
)

PORT  = int(os.environ.get("CLAUDE_GLASS_PORT", "8787"))
TOKEN = os.environ.get("CLAUDE_GLASS_TOKEN") or secrets.token_hex(8)
CWD   = os.environ.get("CLAUDE_GLASS_CWD", os.path.expanduser("~"))
APPROVAL_TIMEOUT = 120.0   # auto-deny if the glasses never answer

# ---- one asyncio loop in a daemon thread; SDK calls marshalled onto it --------
LOOP = asyncio.new_event_loop()
threading.Thread(target=lambda: (asyncio.set_event_loop(LOOP), LOOP.run_forever()),
                 daemon=True).start()
def run_coro(coro, timeout=180):
    return asyncio.run_coroutine_threadsafe(coro, LOOP).result(timeout)


# ---- tool-call summarizer - ported from @evenrealities/even-terminal -----------
# (dist/claude/summarize.js) so the glasses show the SAME clean one-line labels
# as the official Even terminal app instead of raw command/path dumps.
def _one(v):
    return re.sub(r"\s+", " ", str(v)).strip() if v is not None else ""

def _trunc(v, n):
    t = _one(v)
    return (t[:n] + "...") if len(t) > n else t

def _fname(p):
    if not p: return "file"
    parts = re.split(r"[\\/]", str(p))
    return parts[-1] or str(p)

def summarize_tool(name, inp):
    if not isinstance(inp, dict): inp = {}
    g = inp.get
    if name == "Bash":
        return "Bash " + _trunc(g("description") or g("command") or "command", 50)
    if name == "Read":
        nm = _fname(g("file_path")); off = g("offset"); lim = g("limit")
        if off is not None and lim is not None: return f"Read {nm} (lines {off}-{off + lim})"
        if lim is not None: return f"Read {nm} ({lim} lines)"
        return f"Read {nm}"
    if name == "Edit" or name == "MultiEdit":
        nm = _fname(g("file_path"))
        added = len((g("new_string") or "").split("\n")) if g("new_string") else 0
        removed = len((g("old_string") or "").split("\n")) if g("old_string") else 0
        d = added - removed
        if d > 0: return f"Edit {nm} +{d} lines"
        if d < 0: return f"Edit {nm} {d} lines"
        return f"Edit {nm} ~{added} lines"
    if name == "Write":
        nm = _fname(g("file_path")); lines = len((g("content") or "").split("\n")) if g("content") else 0
        return f"Write {nm} ({lines} lines)"
    if name == "Glob": return "Glob " + _trunc(g("pattern"), 40)
    if name == "Grep": return 'Grep "' + _trunc(g("pattern"), 25) + '"'
    if name in ("Agent", "Task"): return "Agent " + _trunc(g("description") or "", 40)
    if name == "TodoWrite": return "TodoWrite update tasks"
    if name == "WebSearch": return 'Search "' + _trunc(g("query") or "", 30) + '"'
    if name == "WebFetch": return "Fetch " + _trunc(g("url") or "", 40)
    if name == "ExitPlanMode": return "ExitPlanMode"
    if name == "AskUserQuestion": return "AskUserQuestion"
    disp = "Agent" if name.startswith("Task") else name
    detail = g("subject") or g("description") or g("content") or g("action") or ""
    return f"{disp} {_trunc(detail, 40)}".strip() if detail else disp


class Sess:
    """One SDK client + its live transcript buffer + its current pending approval."""
    def __init__(self, sid, name):
        self.id = sid; self.name = name
        self.client = None
        self.status = "starting"
        self.created = time.time(); self.touched = time.time()
        self.lines = []          # [{"role","text","tool"}]
        self.pending = None       # {"request_id","tool","input","title","event","decision"}
        self.reader = None

SESS = {}

def _add(s, role, text, tool=None):
    s.lines.append({"role": role, "text": (text or "")[:400], "tool": tool})
    s.lines[:] = s.lines[-200:]; s.touched = time.time()

async def _can_use_tool(s, tool_name, input_data, context):
    """The SDK parks here until the glasses POST /respond. This IS the approval gate."""
    rid = uuid.uuid4().hex
    ev = asyncio.Event()
    s.pending = {"request_id": rid, "tool": tool_name, "input": input_data,
                 "title": getattr(context, "title", None) or tool_name,
                 "event": ev, "decision": None}
    s.status = "awaiting"
    try:
        await asyncio.wait_for(ev.wait(), timeout=APPROVAL_TIMEOUT)
    except asyncio.TimeoutError:
        s.pending = None; s.status = "working"
        _add(s, "tool", "→ (approval timed out → denied)", tool="result")
        return PermissionResultDeny(message="timed out waiting for glasses")
    decision = s.pending["decision"]; s.pending = None; s.status = "working"
    if decision == "allow":
        return PermissionResultAllow(updated_input=input_data)
    return PermissionResultDeny(message="denied from glasses")

async def _drain(s):
    """Continuously pull messages → live transcript buffer."""
    try:
        async for msg in s.client.receive_messages():
            if isinstance(msg, AssistantMessage):
                for b in msg.content:
                    if isinstance(b, TextBlock):
                        _add(s, "assistant", b.text)
                    elif isinstance(b, ToolUseBlock):
                        inp = b.input if isinstance(b.input, dict) else {}
                        _add(s, "tool", "> " + summarize_tool(b.name, inp))   # clean one-liner
            elif isinstance(msg, UserMessage):
                pass   # tool_result echoes - skipped for a clean sidebar-style view
            elif isinstance(msg, ResultMessage):
                s.status = "idle"
    except Exception as e:
        _add(s, "assistant", f"[stream ended: {e}]"); s.status = "done"

async def _spawn(prompt, name):
    sid = "glass-" + uuid.uuid4().hex[:8]
    s = Sess(sid, name or "glass"); SESS[sid] = s
    opts = ClaudeAgentOptions(
        cwd=CWD,
        permission_mode="acceptEdits",                   # like @evenrealities/even-terminal
        can_use_tool=lambda t, i, c: _can_use_tool(s, t, i, c),
    )
    s.client = ClaudeSDKClient(options=opts)
    await s.client.connect()
    s.status = "busy"; _add(s, "user", prompt)
    s.reader = asyncio.create_task(_drain(s))
    await s.client.query(prompt)
    return s

async def _reply(sid, text):
    s = SESS.get(sid)
    if not s or not s.client:
        raise KeyError(sid)
    _add(s, "user", text); s.status = "busy"
    await s.client.query(text)
    return s

async def _respond(sid, choice):
    s = SESS.get(sid)
    if s and s.pending:
        s.pending["decision"] = "allow" if choice in ("allow", "allowAlways") else "deny"
        s.pending["event"].set()
    return s


def _pending_action(s):
    if not s.pending:
        return None
    inp = s.pending["input"]
    detail = inp.get("command") or inp.get("file_path") or inp.get("path") or str(inp)
    return f"{s.pending['title']}: {str(detail)[:60]}"

def session_json(s):
    return {"id": s.id, "name": s.name, "title": s.name, "status": s.status,
            "created_at": int(s.created), "pending_action": _pending_action(s)}

def transcript_json(s, limit):
    return {"found": True,
            "messages": [{"role": l["role"], "text": l["text"], "tool": l["tool"]}
                         for l in s.lines[-limit:]]}


# ---- read-only view of EXISTING on-disk Claude Code sessions (merged in) -----
# So the app shows the user's real sessions too, not just bridge-spawned ones.
import re
CLAUDE_DIR = os.path.expanduser("~/.claude/projects")
SKIP = ("orbit-agents", "-private-var-folders", "-tmp-", "-T-")

def _dclean(s):
    s = re.sub(r"[─━╭╮│╰╯┌┐└┘]+", " ", s); return re.sub(r"\s+", " ", s).strip()

def _dtitle(path):
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as fh:
            for _ in range(40):
                line = fh.readline()
                if not line: break
                try: d = json.loads(line)
                except ValueError: continue
                if d.get("type") == "ai-title":
                    for k in ("title", "content", "text"):
                        v = d.get(k)
                        if isinstance(v, str) and v.strip(): return v.strip()[:40]
    except OSError: return None
    return None

def disk_sessions(limit=12):
    out = []
    if not os.path.isdir(CLAUDE_DIR): return out
    now = time.time(); files = []
    for name in os.listdir(CLAUDE_DIR):
        if any(x in name for x in SKIP): continue
        d = os.path.join(CLAUDE_DIR, name)
        if not os.path.isdir(d): continue
        for f in os.listdir(d):
            if f.endswith(".jsonl"):
                pth = os.path.join(d, f)
                try: st = os.stat(pth)
                except OSError: continue
                files.append((f[:-6], pth, st.st_mtime, st.st_ctime, name))
    files.sort(key=lambda r: r[2], reverse=True)
    for sid, _pth, mtime, ctime, proj in files[:limit]:
        age = now - mtime
        status = "working" if age < 30 else ("idle" if age < 3600 else "done")
        title = _dtitle(_pth) or proj.lstrip("-").replace("-", "/").rsplit("/", 1)[-1]
        out.append({"id": sid, "name": title, "title": title, "status": status,
                    "created_at": int(ctime), "pending_action": None})
    return out

def disk_transcript(sid, limit):
    if not os.path.isdir(CLAUDE_DIR): return None
    for name in os.listdir(CLAUDE_DIR):
        pth = os.path.join(CLAUDE_DIR, name, sid + ".jsonl")
        if not os.path.isfile(pth): continue
        msgs = []
        try:
            with open(pth, "r", encoding="utf-8", errors="ignore") as fh:
                for line in fh:
                    line = line.strip()
                    if not line: continue
                    try: d = json.loads(line)
                    except ValueError: continue
                    if d.get("type") not in ("user", "assistant"): continue
                    m = d.get("message")
                    if not isinstance(m, dict): continue
                    role = m.get("role", d.get("type")); c = m.get("content")
                    if isinstance(c, str):
                        t = _dclean(c)
                        if t: msgs.append({"role": role, "text": t, "tool": None})
                    elif isinstance(c, list):
                        for b in c:
                            if not isinstance(b, dict): continue
                            bt = b.get("type")
                            if bt == "text":
                                t = _dclean(b.get("text", ""))
                                if t: msgs.append({"role": role, "text": t, "tool": None})
                            elif bt == "tool_use":
                                inp = b.get("input", {}) if isinstance(b.get("input"), dict) else {}
                                msgs.append({"role": "tool", "text": "> " + summarize_tool(b.get("name", "tool"), inp), "tool": None})
                            # tool_result echoes skipped - clean sidebar-style view
        except OSError: return None
        return {"messages": msgs[-limit:], "found": True}
    return None


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def _send(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def _auth(self):
        return (not TOKEN) or self.headers.get("Authorization", "") == f"Bearer {TOKEN}"
    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        try: return json.loads(self.rfile.read(n) or b"{}")
        except Exception: return {}

    def do_GET(self):
        if not self._auth(): return self._send({"error": "unauthorized"}, 401)
        u = urlparse(self.path); p = [unquote(x) for x in u.path.strip("/").split("/")]
        if p == ["api", "projects"]:
            return self._send([{"slug": "_", "name": os.path.basename(CWD.rstrip("/")) or "glass"}])
        if len(p) >= 4 and p[0] == "api" and p[1] == "projects" and p[3] == "agent-sessions":
            if len(p) == 4:
                sdk = [session_json(s) for s in sorted(SESS.values(), key=lambda x: x.created, reverse=True)]
                disk = [d for d in disk_sessions() if d["id"] not in SESS]   # merge existing CC sessions (read-only)
                return self._send(sdk + disk)
            sid = p[4]; s = SESS.get(sid)
            if len(p) == 6 and p[5] == "transcript":
                q = parse_qs(u.query); lim = max(1, min(int((q.get("limit") or ["30"])[0]), 200))
                if s: return self._send(transcript_json(s, lim))
                return self._send(disk_transcript(sid, lim) or {"messages": [], "found": False})
            if len(p) == 6 and p[5] == "pending":
                if s and s.pending:
                    return self._send({"request_id": s.pending["request_id"], "tool": s.pending["tool"],
                                       "input": s.pending["input"], "title": s.pending["title"]})
                return self._send({})
        return self._send({"error": "not found", "path": u.path}, 404)

    def do_POST(self):
        if not self._auth(): return self._send({"error": "unauthorized"}, 401)
        p = [unquote(x) for x in urlparse(self.path).path.strip("/").split("/")]
        body = self._body()
        try:
            if p[-1] == "spawn":
                s = run_coro(_spawn(body.get("prompt", ""), body.get("name", "glass")))
                return self._send(session_json(s))
            if "agent-sessions" in p and p[-1] == "reply":
                sid = p[p.index("agent-sessions") + 1]
                s = run_coro(_reply(sid, body.get("text", "")))
                return self._send(session_json(s))
            if "agent-sessions" in p and p[-1] == "respond":
                sid = p[p.index("agent-sessions") + 1]
                run_coro(_respond(sid, body.get("choice", "deny")))
                s = SESS.get(sid)
                return self._send(session_json(s) if s else {"id": sid, "status": "idle"})
        except Exception as e:
            return self._send({"error": str(e)}, 500)
        return self._send({"error": "not found"}, 404)


def main():
    print(f"Claude Glass SDK bridge  port={PORT}  token={TOKEN}  cwd={CWD}")
    print("  spawn/reply/respond/pending live; Ctrl-C to stop.")
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()

if __name__ == "__main__":
    try: main()
    except KeyboardInterrupt: print("\nbridge stopped.")
