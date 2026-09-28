import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { FakeOpenAI, type ToolCall } from "./fake-openai";
import { Sandbox, jsonEvents, type AgentEvent } from "./harness";

let sb: Sandbox;
let llm: FakeOpenAI;

function config(permission: Array<{ action: string; pattern: string; effect: string }> = []) {
  sb.writeConfig({
    model: "fake/test-model",
    provider: { fake: { options: { baseURL: llm.baseURL } } },
    permission,
  });
}

function call(id: string, name: string, args: string | Record<string, unknown>): ToolCall {
  return { id, name, args, chunks: 5 };
}

async function run() {
  const result = await sb.zeta(["run", "--json", "exercise tools"]);
  const events = jsonEvents(result.stdout);
  return { ...result, events };
}

function assertToolEvents(events: AgentEvent[], id: string, name: string, error: boolean) {
  const start = events.findIndex((event) => event.type === "tool.execution.start" && event.data.toolCallId === id);
  const end = events.findIndex((event) => event.type === "tool.execution.end" && event.data.toolCallId === id);
  expect(start).toBeGreaterThan(-1);
  expect(end).toBeGreaterThan(start);
  expect(events[start].data.toolName).toBe(name);
  expect(events[end].data.toolName).toBe(name);
  expect(events[end].data.isError).toBe(error);
  const logged = sb.sessionMessages().find((message) => message.role === "tool_result" && message.toolCallId === id);
  expect(logged?.toolName).toBe(name);
  // Session JSONL elides false; execution events always carry the boolean.
  expect(logged?.isError ?? false).toBe(error);
  expect(logged?.content[0].text).toBe(events[end].data.result?.content[0].text);
  return logged?.content[0].text ?? "";
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

describe("tool continuation and log", () => {
  test("fragmented read arguments produce a logged result seen by the model", async () => {
    writeFileSync(join(sb.project, "input.txt"), "read sentinel\n");
    llm.reply({ calls: [call("read-1", "read", { path: "input.txt" })] }, { text: "I found the sentinel." });
    const { code, events } = await run();
    expect(code).toBe(0);
    expect(llm.requests[0].tools.some((tool: { function: { name: string } }) => tool.function.name === "read")).toBe(true);
    expect(llm.requests[0].tools.some((tool: { function: { name: string } }) => tool.function.name === "webfetch")).toBe(true);
    expect(llm.requests[0].tools.some((tool: { function: { name: string } }) => tool.function.name === "zeta_inspect")).toBe(false);
    expect(llm.requests[1].messages.at(-1)).toEqual({ role: "tool", tool_call_id: "read-1", content: "read sentinel" });
    expect(assertToolEvents(events, "read-1", "read", false)).toContain("read sentinel");
    const messages = sb.sessionMessages();
    expect(messages.map((message) => message.role)).toEqual(["user", "assistant", "tool_result", "assistant"]);
    expect(messages[1].content.find((part) => part.type === "toolCall")?.arguments).toEqual({ path: "input.txt" });
    expect(events.findIndex((event) => event.type === "message.end" && event.data.message?.role === "assistant"))
      .toBeLessThan(events.findIndex((event) => event.type === "tool.execution.start"));
  });

  test("invalid schema arguments do not cause side effects", async () => {
    llm.reply({ calls: [call("bad-shape", "write", { path: "bad.txt", content: 42 })] }, { text: "No file written." });
    const { code, events } = await run();
    expect(code).toBe(0);
    expect(assertToolEvents(events, "bad-shape", "write", true)).toContain("Invalid tool arguments");
    expect(existsSync(join(sb.project, "bad.txt"))).toBe(false);
    expect(llm.requests[1].messages.at(-1).role).toBe("tool");
  });

  test("malformed JSON arguments never invoke a mutating tool", async () => {
    llm.reply({ calls: [call("bad-json", "write", '{"path":"also-bad.txt","content":')] }, { text: "No file written." });
    const { code, events } = await run();
    expect(code).toBe(0);
    expect(assertToolEvents(events, "bad-json", "write", true)).toContain("malformed JSON");
    expect(existsSync(join(sb.project, "also-bad.txt"))).toBe(false);
  });

  test("write and edit operate on a real project file", async () => {
    llm.reply(
      { calls: [call("write-1", "write", { path: "nested/output.txt", content: "alpha beta\n" })] },
      { calls: [call("edit-1", "edit", { path: "nested/output.txt", edits: [{ oldText: "alpha", newText: "gamma" }, { oldText: "beta", newText: "delta" }] })] },
      { text: "Done." },
    );
    const { code, events } = await run();
    expect(code).toBe(0);
    expect(readFileSync(join(sb.project, "nested/output.txt"), "utf8")).toBe("gamma delta\n");
    expect(assertToolEvents(events, "write-1", "write", false)).toContain("Successfully wrote");
    expect(assertToolEvents(events, "edit-1", "edit", false)).toContain("replaced 2 block");
    expect(llm.requests[2].messages.at(-1).content).toContain("replaced 2 block");
  });

  test("bash runs a command in the project and returns its output", async () => {
    writeFileSync(join(sb.project, "input.txt"), "shell sentinel\n");
    llm.reply({ calls: [call("bash-1", "bash", { command: "cat input.txt" })] }, { text: "Done." });
    const { code, events } = await run();
    expect(code).toBe(0);
    expect(assertToolEvents(events, "bash-1", "bash", false)).toContain("shell sentinel");
    expect(llm.requests[1].messages.at(-1).content).toContain("shell sentinel");
  });

  test("length-truncated tool calls return errors without executing", async () => {
    llm.reply({ calls: [call("truncated", "write", { path: "must-not-exist", content: "oops" })], finish_reason: "length" }, { text: "Retry later." });
    const { code, events } = await run();
    expect(code).toBe(0);
    expect(assertToolEvents(events, "truncated", "write", true)).toContain("not executed");
    expect(existsSync(join(sb.project, "must-not-exist"))).toBe(false);
  });

  test("parallel reads retain source order in model history and event log", async () => {
    writeFileSync(join(sb.project, "a.txt"), "first result\n");
    writeFileSync(join(sb.project, "b.txt"), "second result\n");
    llm.reply({ calls: [call("first", "read", { path: "a.txt" }), call("second", "read", { path: "b.txt" })] }, { text: "Read both." });
    const { code, events } = await run();
    expect(code).toBe(0);
    expect(assertToolEvents(events, "first", "read", false)).toContain("first result");
    expect(assertToolEvents(events, "second", "read", false)).toContain("second result");
    expect(sb.sessionMessages().filter((message) => message.role === "tool_result").map((message) => message.toolCallId))
      .toEqual(["first", "second"]);
    expect(llm.requests[1].messages.filter((message: { role: string }) => message.role === "tool").map((message: { tool_call_id: string }) => message.tool_call_id))
      .toEqual(["first", "second"]);
  });

  test.each(["ask", "deny"])("%s permission fails closed without a client and stops the turn", async (effect) => {
    config([{ action: "write", pattern: "*", effect }]);
    llm.reply({ calls: [call("blocked", "write", { path: "forbidden", content: "no" })] }, { text: "Should never be requested." });
    const { code, stderr, events } = await run();
    expect(code).toBe(1);
    expect(stderr).toContain("the run stopped before a final reply: Tool execution denied by permission policy.");
    expect(assertToolEvents(events, "blocked", "write", true)).toMatch(/denied/i);
    expect(existsSync(join(sb.project, "forbidden"))).toBe(false);
    expect(llm.requests).toHaveLength(1);
    expect(events.filter((event) => event.type === "turn.end")).toHaveLength(1);
  });

  test("webfetch follows a redirect and decodes a gzip HTML response", async () => {
    const fixture = Bun.serve({
      hostname: "127.0.0.1",
      port: 0,
      fetch: (req) => new URL(req.url).pathname === "/start"
        ? new Response(null, { status: 302, headers: { location: "/page" } })
        : new Response(Bun.gzipSync("<h1>Fixture heading</h1><p>Fixture body</p>"), { headers: { "content-type": "text/html", "content-encoding": "gzip" } }),
    });
    try {
      llm.reply({ calls: [call("fetch-1", "webfetch", { url: `http://127.0.0.1:${fixture.port}/start` })] }, { text: "Fetched." });
      const { code, events } = await run();
      expect(code).toBe(0);
      expect(assertToolEvents(events, "fetch-1", "webfetch", false)).toContain("Fixture heading");
      expect(llm.requests[1].messages.at(-1).content).toContain("Fixture body");
    } finally {
      fixture.stop(true);
    }
  });

  test("webfetch checks permission for each redirect hop", async () => {
    config([{ action: "webfetch", pattern: "*secret*", effect: "deny" }]);
    const paths: string[] = [];
    const fixture = Bun.serve({
      hostname: "127.0.0.1",
      port: 0,
      fetch: (req) => {
        const path = new URL(req.url).pathname;
        paths.push(path);
        return path === "/start"
          ? new Response(null, { status: 302, headers: { location: "/secret" } })
          : new Response("secret contents");
      },
    });
    try {
      llm.reply({ calls: [call("fetch-1", "webfetch", { url: `http://127.0.0.1:${fixture.port}/start` })] }, { text: "Should never be requested." });
      const { events } = await run();
      expect(assertToolEvents(events, "fetch-1", "webfetch", true)).toMatch(/denied/i);
      expect(paths).toEqual(["/start"]);
      expect(llm.requests).toHaveLength(1);
    } finally {
      fixture.stop(true);
    }
  });

  test("skill metadata is lazy; its SKILL.md body is loaded only on request", async () => {
    const dir = join(sb.project, ".agents", "skills", "test-skill");
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "SKILL.md"), "---\nname: test-skill\ndescription: Testing skill discovery\n---\n\nSecret skill instructions.\n");
    llm.reply({ calls: [call("skill-1", "skill", { name: "test-skill" })] }, { text: "Loaded." });
    const { code, events } = await run();
    expect(code).toBe(0);
    expect(llm.requests[0].messages[0].content).toContain("test-skill");
    expect(llm.requests[0].messages[0].content).not.toContain("Secret skill instructions");
    expect(assertToolEvents(events, "skill-1", "skill", false)).toContain("Secret skill instructions");
    expect(llm.requests[1].messages.at(-1).content).toContain("Secret skill instructions");
  });

  test("zeta_inspect returns a summary and one section of the live registry", async () => {
    sb.writeConfig({ model: "fake/test-model", provider: { fake: { options: { baseURL: llm.baseURL } } }, inspect_tool: true });
    llm.reply(
      { calls: [call("inspect-1", "zeta_inspect", {}), call("inspect-2", "zeta_inspect", { section: "config" })] },
      { text: "Inspected." },
    );
    const { code, events } = await run();
    expect(code).toBe(0);
    expect(llm.requests[0].tools.some((tool: { function: { name: string } }) => tool.function.name === "zeta_inspect")).toBe(true);
    const summary = JSON.parse(assertToolEvents(events, "inspect-1", "zeta_inspect", false));
    expect(summary.counts.tools).toBeGreaterThanOrEqual(7);
    expect(summary.sections).toContain("hooks");
    const config = JSON.parse(assertToolEvents(events, "inspect-2", "zeta_inspect", false));
    expect(config.config.model).toBe("fake/test-model");
    expect(config.provenance.model).toBe("user");
  });
});
