#!/usr/bin/env python3
"""A zeta extension using only the Python standard library.

It adds a tool (word_count), a slash command (/summarize), a hook that
blocks one dangerous shell command, and a model provider (echo/echo-1) that
answers without a network. The protocol is described in extensions.md: one
JSON object per line on stdin and stdout; logs go to stderr.
"""
import json
import sys
import threading

write_lock = threading.Lock()


def send(message):
    with write_lock:
        sys.stdout.write(json.dumps(message) + "\n")
        sys.stdout.flush()


def respond(request_id, result=None, error=None):
    message = {"type": "response", "id": request_id}
    if error is not None:
        message["error"] = error
    else:
        message["result"] = result
    send(message)


def event(request_id, payload):
    send({"type": "event", "id": request_id, "event": payload})


def tool(params):
    if params["name"] == "word_count":
        return {"text": str(len(params["arguments"]["text"].split()))}
    if params["name"] == "where":
        return {"text": params["session"] + " " + params["location"]}
    return {"text": "unknown tool " + params["name"], "isError": True}


def command(params):
    path = params["arguments"].strip() or "the current file"
    return {"text": "Summarize " + path + " in three bullet points."}


def hook(params):
    if params["point"] == "tool_pre":
        call = params["call"]
        if call["name"] == "bash" and "rm -rf /" in call["arguments"].get("command", ""):
            return {"action": "block", "reason": "hello: refusing to delete everything"}
    return {"action": "continue"}


def text_of(message):
    return "".join(part.get("text", "") for part in message["content"] if part["type"] == "text")


def stream(request_id, params):
    """echo-1 repeats the last prompt, or calls word_count when asked to."""
    last = params["messages"][-1]
    if last["role"] == "tool_result":
        event(request_id, {"text": "The tool said: " + text_of(last)})
        respond(request_id, {"stop": "stop"})
        return
    prompt = text_of(last)
    if prompt.startswith("count: "):
        arguments = json.dumps({"text": prompt[len("count: "):]})
        event(request_id, {"toolCall": {"index": 0, "id": "call_1", "name": "word_count", "arguments": arguments}})
        event(request_id, {"usage": {"input": len(prompt), "output": 1}})
        respond(request_id, {"stop": "tool_use"})
        return
    if params.get("thinking"):
        event(request_id, {"text": "[thinking " + params["thinking"] + "] "})
    for word in ("echo: " + prompt).split(" "):
        event(request_id, {"text": word + " "})
    event(request_id, {"usage": {"input": len(prompt), "output": len(prompt)}})
    respond(request_id, {"stop": "stop"})


def handle(message):
    method = message["method"]
    params = message["params"]
    request_id = message["id"]
    try:
        if method == "tool":
            respond(request_id, tool(params))
        elif method == "command":
            respond(request_id, command(params))
        elif method == "hook":
            respond(request_id, hook(params))
        elif method == "stream":
            stream(request_id, params)
        else:
            respond(request_id, error="unknown method " + method)
    except Exception as failure:  # Report instead of dying.
        respond(request_id, error=str(failure))


def main():
    send({
        "type": "register",
        "name": "hello",
        "tools": [{
            "name": "word_count",
            "description": "Count the words in a text.",
            "parameters": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]},
            "sideEffect": "none",
        }, {
            "name": "where",
            "description": "Tell which session and project the call is for.",
            "parameters": {"type": "object"},
            "sideEffect": "none",
        }],
        "commands": [{"name": "summarize", "description": "Ask for a summary of a file", "argumentHint": "<path>"}],
        "hooks": ["tool_pre"],
        "providers": [{"id": "echo", "name": "Echo", "models": [{"id": "echo-1", "name": "Echo 1", "context": 8192, "reasoning": True}]}],
    })
    for line in sys.stdin:
        if not line.strip():
            continue
        message = json.loads(line)
        kind = message["type"]
        if kind == "ready":
            send({"type": "call", "id": "hello-ready", "method": "log", "params": {"level": "info", "message": "hello is ready"}})
        elif kind == "ping":
            send({"type": "pong"})
        elif kind == "request":
            threading.Thread(target=handle, args=(message,), daemon=True).start()
        elif kind == "shutdown":
            break
        # "result" answers our calls and "cancel" needs no reply here.
    print("hello: stopping", file=sys.stderr)


if __name__ == "__main__":
    main()
