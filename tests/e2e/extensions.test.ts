import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { cpSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { FakeOpenAI } from "./fake-openai";
import { Sandbox, jsonEvents, zetaBin } from "./harness";

let sb: Sandbox;
let llm: FakeOpenAI;
const example = join(import.meta.dir, "../../docs/examples/extensions/hello");

function install(name = "hello") {
  const dir = join(sb.project, ".zeta", "extensions", name);
  mkdirSync(join(sb.project, ".zeta", "extensions"), { recursive: true });
  cpSync(example, dir, { recursive: true });
  return dir;
}

function config(model = "fake/test-model") {
  sb.writeConfig({ model, provider: { fake: { options: { baseURL: llm.baseURL } } } });
}

async function listing(path: string) {
  return (await sb.api(`${path}${path.includes("?") ? "&" : "?"}location=${encodeURIComponent(sb.project)}`)).json();
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

describe("extensions", () => {
  test("an extension's tool runs and its tool_pre hook blocks", async () => {
    install();
    llm.reply(
      { calls: [{ id: "w", name: "word_count", args: { text: "one two three" } }, { id: "b", name: "bash", args: { command: "rm -rf /" } }] },
      { text: "done" },
    );
    const result = await sb.zeta(["run", "count"]);
    expect(result.code).toBe(0);
    const tools = llm.requests[1].messages.filter((m: { role: string }) => m.role === "tool");
    expect(tools.find((m: { tool_call_id: string }) => m.tool_call_id === "w").content).toBe("3");
    expect(tools.find((m: { tool_call_id: string }) => m.tool_call_id === "b").content).toBe("hello: refusing to delete everything");
    const status = (await listing("/extensions")).extensions;
    expect(status).toEqual([{ name: "hello", scope: "project", status: "running", source: join(sb.project, ".zeta/extensions/hello/zeta.json"), error: null }]);
    const registry = await listing("/registry");
    expect(registry.tools.some((t: { name: string; plugin: string }) => t.name === "word_count" && t.plugin === "hello")).toBe(true);
    expect(registry.plugins.some((p: { id: string; layer: string }) => p.id === "hello" && p.layer === "project")).toBe(true);
    const log = readFileSync(join(sb.env.XDG_STATE_HOME, "zeta", "server.log"), "utf8");
    expect(log).toContain("extension hello: hello is ready");
  });

  test("an extension's provider streams replies and tool calls", async () => {
    install();
    config("echo/echo-1");
    const plain = await sb.zeta(["run", "hello there"]);
    expect(plain.code).toBe(0);
    expect(plain.stdout).toContain("echo: hello there");
    expect(plain.stdout).not.toContain("[thinking");
    const thinking = await sb.zeta(["run", "--thinking", "high", "hello"]);
    expect(thinking.stdout).toContain("[thinking high] echo: hello");
    const counted = await sb.zeta(["run", "--json", "count: a b c d"]);
    expect(counted.code).toBe(0);
    const ends = jsonEvents(counted.stdout).filter((e) => e.type === "tool.execution.end");
    expect(ends[0].data.result?.content[0].text).toBe("4");
    expect(counted.stdout).toContain("The tool said: 4");
    const models = await listing("/models");
    expect(models.providers.some((p: { id: string; models: Array<{ id: string }> }) => p.id === "echo" && p.models[0].id === "echo-1")).toBe(true);
  });

  test("an extension's command becomes the session prompt, even as the first thing in a project", async () => {
    install();
    // Start the server from another directory, so this project is cold.
    const other = join(sb.root, "elsewhere");
    mkdirSync(other, { recursive: true });
    llm.reply({ text: "started" }, { text: "summary" });
    const started = Bun.spawn([zetaBin, "run", "start"], { cwd: other, env: sb.env, stdout: "ignore", stderr: "ignore" });
    expect(await started.exited).toBe(0);
    const session = await (await sb.api("/sessions", "POST", { location: sb.project })).json();
    const sent = await sb.api(`/sessions/${session.id}/command`, "POST", { name: "summarize", arguments: "src/a.zig" });
    expect(sent.status).toBe(200);
    for (let i = 0; i < 100 && llm.requests.length < 2; i++) await Bun.sleep(20);
    expect(JSON.stringify(llm.requests[1].messages.at(-1))).toContain("Summarize src/a.zig in three bullet points.");
    const commands = await listing("/commands");
    expect(commands.commands).toContainEqual({ name: "summarize", description: "Ask for a summary of a file", argumentHint: "<path>", source: "hello" });
  });

  test("tool requests carry their session and project; one extension runs in two projects", async () => {
    install();
    llm.reply({ calls: [{ id: "w", name: "where", args: {} }] }, { text: "done" });
    const result = await sb.zeta(["run", "--json", "where"]);
    expect(result.code).toBe(0);
    const session = jsonEvents(result.stdout)[0].session;
    expect(llm.requests[1].messages.at(-1).content).toBe(`${session} ${sb.project}`);
    const second = join(sb.root, "second");
    mkdirSync(join(second, ".zeta", "extensions"), { recursive: true });
    cpSync(example, join(second, ".zeta", "extensions", "hello"), { recursive: true });
    for (let i = 0; i < 100; i++) {
      const there = (await (await sb.api(`/extensions?location=${encodeURIComponent(second)}`)).json()).extensions;
      if (there[0]?.status === "running") break;
      await Bun.sleep(50);
    }
    const there = (await (await sb.api(`/extensions?location=${encodeURIComponent(second)}`)).json()).extensions;
    expect(there[0]).toMatchObject({ name: "hello", scope: "project", status: "running" });
    expect((await listing("/extensions")).extensions[0].status).toBe("running");
  });

  test("reload replaces an extension without losing its tools", async () => {
    install();
    llm.reply({ text: "one" });
    expect((await sb.zeta(["run", "hi"])).code).toBe(0);
    const reload = await (await sb.api("/registry/reload", "POST", { location: sb.project })).json();
    expect(reload.failures).toEqual([]);
    llm.reply({ calls: [{ id: "w", name: "word_count", args: { text: "a b" } }] }, { text: "done" });
    expect((await sb.zeta(["run", "again"])).code).toBe(0);
    expect(llm.requests[2].messages.at(-1).content).toBe("2");
    expect((await listing("/extensions")).extensions[0].status).toBe("running");
  });

  test("a crashing, silent or misnamed extension is failed and can be restarted", async () => {
    mkdirSync(join(sb.project, ".zeta", "extensions"), { recursive: true });
    const crash = join(sb.project, ".zeta", "extensions", "crash");
    writeFileSync(crash, "#!/bin/sh\necho 'oops' >&2\nexit 4\n", { mode: 0o755 });
    const other = install("other");
    writeFileSync(join(other, "zeta.json"), JSON.stringify({ name: "other", command: ["python3", "hello.py"] }));
    llm.reply({ text: "fine" });
    expect((await sb.zeta(["run", "hi"])).code).toBe(0);
    const status: Array<{ name: string; status: string; error: string }> = (await listing("/extensions")).extensions;
    expect(status.find((s) => s.name === "crash")!.status).toBe("failed");
    expect(status.find((s) => s.name === "other")!.error).toContain("registered as 'hello', expected 'other'");
    expect(readFileSync(join(sb.env.XDG_STATE_HOME, "zeta", "extensions", "crash.log"), "utf8")).toContain("oops");
    writeFileSync(join(other, "zeta.json"), JSON.stringify({ name: "hello", command: ["python3", "hello.py"] }));
    expect((await sb.api("/extensions/nope/restart", "POST", { location: sb.project })).status).toBe(404);
    const reload = await (await sb.api("/registry/reload", "POST", { location: sb.project })).json();
    expect(reload.failures).toEqual([]);
    for (let i = 0; i < 100; i++) {
      const now: Array<{ name: string; status: string }> = (await listing("/extensions")).extensions;
      if (now.find((s) => s.name === "hello")?.status === "running") break;
      await Bun.sleep(50);
    }
    expect((await listing("/extensions")).extensions.find((s: { name: string }) => s.name === "hello").status).toBe("running");
  });
  test("restart decodes an escaped extension name", async () => {
    const root = join(sb.project, ".zeta", "extensions");
    mkdirSync(root, { recursive: true });
    writeFileSync(join(root, "needs space"), "#!/bin/sh\nexit 1\n", { mode: 0o755 });
    llm.reply({ text: "ready" });
    expect((await sb.zeta(["run", "hi"])).code).toBe(0);
    const name = (await listing("/extensions")).extensions.find((e: { name: string }) => e.name === "needs space");
    expect(name.status).toBe("failed");
    const restarted = await sb.api(`/extensions/${encodeURIComponent(name.name)}/restart`, "POST", { location: sb.project });
    expect(restarted.status).toBe(200);
  });
});
