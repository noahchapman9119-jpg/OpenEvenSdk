# Claude Glass bridge (standalone)

Mirrors your live **Claude Code** sessions onto the Even G2 glasses - no extra services, no
dependencies. It reads Claude Code's own transcripts (`~/.claude/projects/`) and
serves the small HTTP contract the iOS app speaks.

## Run

```
python3 claude-glass-bridge/bridge.py
```

It prints a URL + token. Put both into the app's **Settings** screen, tap the
**bridge** chip to connect. Phone and Mac must be on the same Wi-Fi.

Optional env: `CLAUDE_GLASS_PORT` (default 8787), `CLAUDE_GLASS_TOKEN` (default: a
random one printed at startup).

## What you get on the glasses

- **Home** - list of your recent Claude Code sessions (working / idle / done).
- **Detail** - pick a session (tap = next, double-tap = select on the touch-bar).
- **Terminal** - a live mirror of that session's transcript (assistant text,
  tool calls, results). This is the "even terminal mimic."

## Limits (read-only)

Responding to Claude Code permission prompts is a terminal interaction Claude Code
does not expose to outside processes, so the **Respond / Allow / Deny** path is a
no-op in standalone mode - the mirror is read-only. (The app's approval UI still
works against a full read/write bridge if you ever point it at one.)
