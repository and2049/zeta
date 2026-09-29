import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { FakeOpenAI } from "./fake-openai";
import { Sandbox, jsonEvents } from "./harness";

let sb: Sandbox;
let llm: FakeOpenAI;

function config(permission: Array<{ action: string; pattern: string; effect: string }> = []) {
  sb.writeConfig({
    model: "fake/test-model",
    provider: { fake: { options: { baseURL: llm.baseURL } } },
    permission,
  });
}

type Hook = { matcher?: string; command: string; timeout?: number };
function hooks(dir: string, events: Record<string, Hook[]>) {
  mkdirSync(dir, { recursive: true });
  const body: Record<string, unknown> = {};
  for (const [event, list] of Object.entries(events)) {
    body[event] = list.map(({ matcher, command, timeout }) => ({ matcher, hooks: [{ type: "command", command, timeout }] }));
  }
  writeFileSync(join(dir, "hooks.json"), JSON.stringify({ hooks: body }));
}

function script(name: string, body: string) {
  const path = join(sb.root, name);
  writeFileSync(path, `#!/bin/sh\n${body}\n`, { mode: 0o755 });
  return path;
}

beforeEach(() => {
  sb = new Sandbox();
  llm = new FakeOpenAI();
  config();
});

afterEach(async () => {
  await sb.cleanup();
  llm.stop();
});

describe("command hooks", () => {
  test("session start and prompt context reach the model; PreToolUse blocks a command; Stop continues once", async () => {
    hooks(join(sb.project, ".zeta"), {
      SessionStart: [{ matcher: "startup", command: `echo '{"hookSpecificOutput":{"additionalContext":"started in '"$ZETA_PROJECT_DIR"'"}}'` }],
      UserPromptSubmit: [{ command: `echo '{"additionalContext":"remember the tests"}'` }],
      PreToolUse: [{ matcher: "Bash", command: script("pre.sh", `grep -q 'rm -rf' && { echo "destructive command" >&2; exit 2; }; exit 0`) }],
      Stop: [{ command: script("stop.sh", `grep -q '"stop_hook_active":false' && echo '{"decision":"block","reason":"run the tests"}'; exit 0`) }],
    });
    llm.reply(
      { calls: [{ id: "bash-1", name: "bash", args: { command: "rm -rf build" } }] },
      { text: "Not deleting." },
      { text: "Tests pass." },
    );
    const result = await sb.zeta(["run", "--json", "clean up"]);
    expect(result.code).toBe(0);
    const first = llm.requests[0].messages.filter((m: { role: string }) => m.role === "user").map((m: { content: unknown }) => JSON.stringify(m.content));
    expect(first.length).toBe(3);
    expect(first[0]).toContain(`started in ${sb.project}`);
    expect(first[1]).toContain("clean up");
    expect(first[2]).toContain("remember the tests");
    expect(llm.requests[1].messages.at(-1)).toEqual({ role: "tool", tool_call_id: "bash-1", content: "destructive command" });
    expect(llm.requests[2].messages.at(-1).content).toContain("run the tests");
    expect(llm.requests.length).toBe(3);
    const logged = sb.sessionMessages();
    expect(logged.filter((m) => (m as { origin?: string }).origin === "hook").length).toBe(3);
    expect(jsonEvents(result.stdout).some((e) => e.type === "prompt.blocked")).toBe(false);
  });

  test("UserPromptSubmit exit 2 blocks the prompt before the model sees it", async () => {
    hooks(join(sb.home, ".agents"), { UserPromptSubmit: [{ command: `grep -q secret && { echo "no secrets" >&2; exit 2; }; exit 0` }] });
    const result = await sb.zeta(["run", "--json", "my secret"]);
    expect(result.code).toBe(1);
    expect(result.stderr).toContain("prompt blocked: no secrets");
    expect(llm.requests.length).toBe(0);
    expect(jsonEvents(result.stdout).find((e) => e.type === "prompt.blocked")?.data).toMatchObject({ reason: "no secrets" });
  });

  test("PermissionRequest answers what rules would ask: allow runs, deny refuses with a reason", async () => {
    config([{ action: "*", pattern: "*", effect: "ask" }]);
    hooks(join(sb.env.XDG_CONFIG_HOME, "zeta"), {
      PermissionRequest: [
        { matcher: "Write", command: `echo '{"hookSpecificOutput":{"decision":{"behavior":"allow","updatedInput":{"path":"hooked.txt","content":"from hook"}}}}'` },
        { matcher: "bash", command: `echo '{"hookSpecificOutput":{"decision":{"behavior":"deny","message":"no shell today"}}}'` },
      ],
    });
    llm.reply(
      { calls: [{ id: "w", name: "write", args: { path: "model.txt", content: "from model" } }, { id: "b", name: "bash", args: { command: "true" } }] },
      { text: "Done." },
    );
    const result = await sb.zeta(["run", "--json", "write it"]);
    expect(result.code).toBe(0);
    expect(existsSync(join(sb.project, "model.txt"))).toBe(false);
    expect(await Bun.file(join(sb.project, "hooked.txt")).text()).toBe("from hook");
    const results = llm.requests[1].messages.filter((m: { role: string }) => m.role === "tool");
    expect(results.find((m: { tool_call_id: string }) => m.tool_call_id === "b").content).toBe("no shell today");
    expect(jsonEvents(result.stdout).some((e) => e.type === "permission.asked")).toBe(false);
  });

  test("arguments a permission hook rewrites are checked against the rules again", async () => {
    config([{ action: "*", pattern: "*", effect: "ask" }, { action: "write", pattern: "*secret*", effect: "deny" }]);
    hooks(join(sb.project, ".zeta"), {
      PermissionRequest: [{ matcher: "write", command: `echo '{"hookSpecificOutput":{"decision":{"behavior":"allow","updatedInput":{"path":"secret.txt","content":"x"}}}}'` }],
    });
    llm.reply({ calls: [{ id: "w", name: "write", args: { path: "notes.txt", content: "x" } }] }, { text: "unreachable" });
    const result = await sb.zeta(["run", "--json", "write"]);
    expect(existsSync(join(sb.project, "secret.txt"))).toBe(false);
    expect(existsSync(join(sb.project, "notes.txt"))).toBe(false);
    expect(sb.sessionMessages().find((m) => m.role === "tool_result")?.content[0].text).toBe("Tool execution denied by permission policy.");
    expect(result.code).toBe(1);
  });

  test("PostToolUseFailure sees a tool that failed", async () => {
    hooks(join(sb.project, ".zeta"), { PostToolUseFailure: [{ matcher: "Read", command: `grep -q FileNotFound && echo '{"additionalContext":"check the path"}'; exit 0` }] });
    llm.reply({ calls: [{ id: "r", name: "read", args: { path: "missing.txt" } }] }, { text: "ok" });
    expect((await sb.zeta(["run", "read it"])).code).toBe(0);
    const content: string = llm.requests[1].messages.at(-1).content;
    expect(content).toContain("FileNotFound");
    expect(content.endsWith("\n\ncheck the path")).toBe(true);
  });

  test("PostToolUse adds context to the result; a broken hooks.json shows in /registry diagnostics", async () => {
    hooks(join(sb.project, ".agents"), { PostToolUse: [{ matcher: "read", command: `echo '{"hookSpecificOutput":{"additionalContext":"file was read"}}'` }] });
    writeFileSync(join(sb.project, "a.txt"), "alpha\n");
    llm.reply({ calls: [{ id: "r", name: "read", args: { path: "a.txt" } }] }, { text: "ok" });
    expect((await sb.zeta(["run", "hi"])).code).toBe(0);
    expect(llm.requests[1].messages.at(-1).content).toBe("alpha\n\nfile was read");

    mkdirSync(join(sb.project, ".zeta"), { recursive: true });
    writeFileSync(join(sb.project, ".zeta", "hooks.json"), "{not json");
    const reload = await sb.api("/registry/reload", "POST", { location: sb.project });
    expect((await reload.json()).failures.length).toBe(1);
    const registry = await (await sb.api(`/registry?location=${encodeURIComponent(sb.project)}`)).json();
    expect(registry.diagnostics.some((d: string) => d.includes(".zeta/hooks.json") && d.includes("InvalidHooksFile"))).toBe(true);
    expect(registry.hooks.some((h: { plugin: string; point: string }) => h.plugin.endsWith(".agents/hooks.json") && h.point === "tool_post")).toBe(true);
  });
});
