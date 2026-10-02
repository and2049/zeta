#!/usr/bin/env python3
"""Ask before tool calls: a permission policy as a zeta extension.

zeta runs every tool call without asking. This extension adds a `tool_pre`
hook that checks each call against ordered rules and asks the user (through
whichever client is attached) when a rule says so. Settings come from
`plugin.permissions` in zeta.jsonc:

    {"plugin": {"permissions": {
      "outside": "ask",
      "rules": [
        {"tool": "bash", "pattern": "*", "effect": "ask"},
        {"tool": "bash", "pattern": "git status*", "effect": "allow"},
        {"tool": "write", "pattern": "*/.env", "effect": "deny"}
      ]}}}

- rules: checked in order, the last match wins; no match allows. `tool` and
  `pattern` are shell-style wildcards (`*` also matches `/`). The pattern is
  matched against the file path (absolute, symlinks resolved) for read,
  write and edit, the command for bash, the URL for webfetch, and the
  arguments as JSON for anything else.
- outside: what happens when read, write or edit touch a file outside the
  project, or a bash command names a path outside it ("ask" by default,
  "allow" or "deny"). The bash check is a best effort: it looks at the words
  of the command, not at what the command does.

An answer of "for this session" allows the same tool and pattern again in
that session without asking. A denial ends the turn. With no client to ask
(e.g. `zeta run` without a terminal), asking counts as a denial.
"""
import fnmatch
import json
import os
import shlex
import sys
import threading

write_lock = threading.Lock()
calls_lock = threading.Lock()
calls = {}  # call id -> [threading.Event, reply]
next_call = [0]
settings = {"rules": [], "outside": "ask"}
remembered = set()  # (session, tool, pattern) allowed for the session


def send(message):
    with write_lock:
        sys.stdout.write(json.dumps(message) + "\n")
        sys.stdout.flush()


def call(method, params):
    """Calls zeta and waits for the result."""
    with calls_lock:
        next_call[0] += 1
        call_id = "c%d" % next_call[0]
        waiter = calls[call_id] = [threading.Event(), None]
    send({"type": "call", "id": call_id, "method": method, "params": params})
    waiter[0].wait()
    with calls_lock:
        del calls[call_id]
    reply = waiter[1]
    if "error" in reply:
        raise RuntimeError(reply["error"])
    return reply.get("result")


def inside(path, root):
    return path == root or path.startswith(root.rstrip("/") + "/")


def resolve(location, path):
    return os.path.realpath(os.path.join(location, os.path.expanduser(path)))


def target(name, arguments, location):
    if name in ("read", "write", "edit") and isinstance(arguments.get("path"), str):
        return resolve(location, arguments["path"])
    if name == "bash" and isinstance(arguments.get("command"), str):
        return arguments["command"]
    if name == "webfetch" and isinstance(arguments.get("url"), str):
        return arguments["url"]
    return json.dumps(arguments, sort_keys=True)


def saved_output(path):
    """A tool result zeta saved beside a session log, which `read` pages
    through: `<data>/sessions/<project>/<session>.artifacts/<call>.txt`."""
    parts = path.split("/")
    return any(p.endswith(".artifacts") for p in parts) and "sessions" in parts


def outside_paths(name, arguments, location):
    """Paths outside the project the call names."""
    root = os.path.realpath(location)
    if name in ("read", "write", "edit"):
        path = target(name, arguments, location)
        return [] if inside(path, root) or (name == "read" and saved_output(path)) else [path]
    if name != "bash":
        return []
    try:
        words = shlex.split(arguments.get("command", ""), comments=True)
    except ValueError:
        words = arguments.get("command", "").split()
    found = []
    for word in words:
        # Redirections such as `>/tmp/out` or `2>>log` name a path too.
        word = word.lstrip("0123456789<>&")
        if not (word.startswith(("/", "~", "..")) or "/../" in word):
            continue
        path = resolve(location, word)
        if not inside(path, root) and path not in found:
            found.append(path)
    return found


def decide(name, pattern):
    effect = "allow"
    for rule in settings.get("rules", []):
        if fnmatch.fnmatchcase(name, rule.get("tool", "*")) and fnmatch.fnmatchcase(pattern, rule.get("pattern", "*")):
            effect = rule.get("effect", "allow")
    return effect


def ask_user(params, message, detail_key):
    scope = params["scope"]
    if (scope["session"],) + detail_key in remembered:
        return True
    answer = call("ask", {
        "kind": "select",
        "message": message,
        "options": [
            {"value": "once", "label": "Allow once"},
            {"value": "session", "label": "Allow for this session"},
            {"value": "deny", "label": "Deny"},
        ],
        "session": scope["session"],
        "location": params["location"],
        "request": params["request"],
    })
    choice = answer.get("content") if answer.get("action") == "accept" else "deny"
    if choice == "session":
        remembered.add((scope["session"],) + detail_key)
    return choice in ("once", "session")


def tool_pre(params):
    call_ = params["call"]
    name, location = call_["name"], params["location"]
    arguments = call_["arguments"] if isinstance(call_["arguments"], dict) else {}
    pattern = target(name, arguments, location)
    checks = []
    effect = decide(name, pattern)
    if effect == "deny":
        return {"action": "deny", "reason": "A permission rule denies this %s call." % name}
    if effect == "ask":
        checks.append(("Allow %s: %s" % (name, pattern), (name, pattern)))
    outside = settings.get("outside", "ask")
    for path in outside_paths(name, arguments, location):
        if outside == "deny":
            return {"action": "deny", "reason": "%s is outside the project." % path}
        if outside == "ask":
            checks.append(("Allow %s outside the project: %s" % (name, path), ("outside", os.path.dirname(path))))
    for message, key in checks:
        if not ask_user(params, message, key):
            return {"action": "deny", "reason": "The user denied this %s call." % name}
    return {"action": "continue"}


def handle(message):
    params = message["params"]
    params["request"] = message["id"]
    try:
        if message["method"] == "hook" and params["point"] == "tool_pre":
            result = tool_pre(params)
        else:
            result = {"action": "continue"}
        send({"type": "response", "id": message["id"], "result": result})
    except Exception as failure:  # A failing tool_pre hook blocks the call.
        send({"type": "response", "id": message["id"], "error": str(failure)})


def main():
    send({"type": "register", "name": "permissions", "hooks": ["tool_pre"]})
    for line in sys.stdin:
        if not line.strip():
            continue
        message = json.loads(line)
        kind = message["type"]
        if kind == "ready":
            settings.update(message.get("options") or {})
        elif kind == "ping":
            send({"type": "pong"})
        elif kind == "request":
            threading.Thread(target=handle, args=(message,), daemon=True).start()
        elif kind == "result":
            with calls_lock:
                waiter = calls.get(message["id"])
            if waiter:
                waiter[1] = message
                waiter[0].set()
        elif kind == "shutdown":
            break


if __name__ == "__main__":
    main()
