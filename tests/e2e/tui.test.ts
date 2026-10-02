import { afterEach, beforeEach, expect, test } from "bun:test";
import { cpSync, existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { Sandbox, zetaBin } from "./harness";
import { FakeOpenAI } from "./fake-openai";
import { Tui, waitFor } from "./tui-harness";

let sb: Sandbox;
let llm: FakeOpenAI;
let ui: Tui | undefined;
let observedSession: string | undefined;
let eventAbort: AbortController | undefined;
beforeEach(() => {
  sb = new Sandbox();
  llm = new FakeOpenAI();
  sb.writeConfig({ model: "fake/base", provider: { fake: { options: { baseURL: llm.baseURL } } } });
});
afterEach(async () => { eventAbort?.abort(); eventAbort = undefined; observedSession = undefined; await ui?.close(); ui = undefined; await sb.cleanup(); llm.stop(); });

async function observeSessionCreation() {
  Bun.spawn([zetaBin, "serve"], { cwd: sb.project, env: sb.env, stdout: "ignore", stderr: "ignore" });
  await waitFor(() => existsSync(sb.discoveryPath), "server discovery");
  eventAbort = new AbortController();
  const { url, password } = sb.discovery();
  const response = await fetch(`${url}/event`, { headers: { authorization: `Basic ${btoa(`zeta:${password}`)}` }, signal: eventAbort.signal });
  const reader = response.body!.getReader();
  let ready!: () => void;
  const connected = new Promise<void>((resolve) => { ready = resolve; });
  void (async () => {
    let buffer = "";
    try {
      while (true) {
        const { value, done } = await reader.read();
        if (done) break;
        buffer += new TextDecoder().decode(value);
        let end: number;
        while ((end = buffer.indexOf("\n\n")) >= 0) {
          const frame = buffer.slice(0, end); buffer = buffer.slice(end + 2);
          const data = frame.split("\n").find((line) => line.startsWith("data: "))?.slice(6);
          if (!data) continue;
          const event = JSON.parse(data);
          if (event.type === "server.connected") ready();
          if (event.type === "session.created") observedSession = event.session;
        }
      }
    } catch { /* The test closes the feed on cleanup. */ }
  })();
  await connected;
}

async function start(model = "fake/base") {
  await observeSessionCreation();
  ui = new Tui(sb);
  await ui.ready();
  await waitFor(() => observedSession !== undefined, "new TUI session");
  await waitFor(() => ui!.screen().includes(model), "hydrated TUI model");
  return ui;
}
async function sessions(): Promise<any[]> {
  const persisted = await (await sb.api("/sessions")).json();
  return persisted.length ? persisted : observedSession ? [{ id: observedSession }] : [];
}
async function state(): Promise<any> {
  const list = await sessions();
  return (await sb.api(`/sessions/${list[0].id}`)).json();
}

test("TUI restores a waiting image input only after removal succeeds", async () => {
  sb.writeConfig({ model: "fake/vision", provider: { fake: { options: { baseURL: llm.baseURL }, models: { vision: { attachment: true } } } } });
  const t = await start("fake/vision");
  const id = (await sessions())[0].id;
  let release!: () => void;
  const paused = new Promise<void>((resolve) => { release = resolve; });
  llm.reply({ text: "still working", chunks: 2, afterFirstChunk: paused });
  try {
    t.send("start work\r");
    await waitFor(() => llm.requests.length === 1, "active turn");
    await waitFor(() => !t.screen().includes("> start work"), "submitted editor cleared");
    const admitted = await sb.api(`/sessions/${id}/prompt`, "POST", { text: "RESTORED_INPUT", delivery: "queue", images: [{ mimeType: "image/png", data: "YWJj" }] });
    expect(admitted.status).toBe(200);
    await waitFor(() => t.screen().includes("RESTORED_INPUT"), "waiting input dock");
    t.send("/pending\r");
    await Bun.sleep(100);
    t.send("\r");
    await waitFor(async () => (await state()).inbox.length === 0, "removed waiting input");
    await waitFor(() => t.screen().includes("RESTORED_INPUT") && t.screen().includes("📎"), "restored text and image");
    expect(llm.requests).toHaveLength(1);
    expect(await t.quit()).toBe(0);
  } finally { release(); }
}, 15000);

test("TUI Ctrl+C clears input and never exits; Ctrl+Q exits and restores terminal", async () => {
  const t = await start();
  expect(t.title()).toBe("zeta");
  t.send("discard me\x03\x03\x03");
  await Bun.sleep(100);
  expect(t.process.exitCode).toBeNull();
  llm.reply({ text: "cleared correctly" });
  t.send("keep me\r");
  await waitFor(() => llm.requests.some((r) => r.messages.some((m: any) => m.content === "keep me")), "submitted text");
  expect(llm.requests.every((r) => !JSON.stringify(r.messages).includes("discard me"))).toBe(true);
  await waitFor(async () => !(await state()).running, "idle response");
  await waitFor(() => t.title() === "ζ Test conversation", "session tab title");
  expect(await t.quit()).toBe(0);
  expect(t.output).toContain("\x1b[?1049l\x1b[23;0t");
  expect(t.flags()).toEqual(t.original);
  expect(t.output).not.toContain("leaked:");
  expect((await sb.api("/health")).status).toBe(200);
}, 15000);

test("TUI completes commands and file references without submitting them", async () => {
  writeFileSync(join(sb.project, "reference.txt"), "local reference");
  const t = await start();
  t.send("/ren");
  await waitFor(() => t.screen().includes("Rename this session"), "command completion opens while typing");
  t.send("\t");
  await waitFor(() => t.screen().includes(" /rename") && !t.screen().includes("Rename this session"), "completed command");
  t.send("\x03read @ref");
  await waitFor(() => t.screen().includes("reference.txt"), "file completion");
  t.send("\t");
  await waitFor(() => t.screen().includes("read @reference.txt"), "inserted file reference");
  expect(llm.requests).toHaveLength(0);
  llm.reply({ text: "reference acknowledged" });
  t.send("\r");
  await waitFor(() => llm.requests.some((r) => r.messages.some((m: any) => m.content === "read @reference.txt")), "submitted reference");
  expect(await t.quit()).toBe(0);
}, 15000);

test("TUI answers a plugin's question while the event feed stays live", async () => {
  mkdirSync(join(sb.project, ".zeta", "extensions"), { recursive: true });
  cpSync(join(import.meta.dir, "../../docs/examples/extensions/permissions"), join(sb.project, ".zeta", "extensions", "permissions"), { recursive: true });
  sb.writeConfig({ model: "fake/base", provider: { fake: { options: { baseURL: llm.baseURL } } }, plugin: { permissions: { rules: [{ tool: "write", pattern: "*", effect: "ask" }] } } });
  const t = await start();
  llm.reply({ calls: [{ id: "approval", name: "write", args: { path: "approved.txt", content: "yes" } }] }, { text: "approved result" });
  t.send("write with approval\r");
  await waitFor(() => t.screen().includes("Allow write:") && t.screen().includes("Allow for this session"), "question panel");
  t.send("1");
  await waitFor(() => existsSync(join(sb.project, "approved.txt")), "approved tool execution");
  await waitFor(async () => !(await state()).running, "approval completion");
  const open = await (await sb.api(`/questions?location=${encodeURIComponent(sb.project)}`)).json();
  expect(open.questions).toHaveLength(0);
  expect(await t.quit()).toBe(0);
}, 15000);

test("TUI declines a yes/no question with n and the turn ends", async () => {
  mkdirSync(join(sb.project, ".zeta"), { recursive: true });
  writeFileSync(join(sb.project, ".zeta", "hooks.json"), JSON.stringify({ hooks: { PreToolUse: [{ matcher: "bash", hooks: [{ type: "command", command: `echo '{"hookSpecificOutput":{"permissionDecision":"ask","permissionDecisionReason":"Run a command?"}}'` }] }] } }));
  const t = await start();
  llm.reply({ calls: [{ id: "ask", name: "bash", args: { command: "touch ran.txt" } }] }, { text: "unreachable" });
  t.send("run it\r");
  await waitFor(() => t.screen().includes("Run a command?"), "yes/no question");
  t.send("n");
  await waitFor(async () => !(await state()).running, "denied turn");
  expect(existsSync(join(sb.project, "ran.txt"))).toBe(false);
  expect(llm.requests).toHaveLength(1);
  expect(await t.quit()).toBe(0);
}, 15000);

test("zeta run asks a plugin's question on its terminal", async () => {
  mkdirSync(join(sb.project, ".zeta"), { recursive: true });
  writeFileSync(join(sb.project, ".zeta", "hooks.json"), JSON.stringify({ hooks: { PreToolUse: [{ matcher: "write", hooks: [{ type: "command", command: `echo '{"hookSpecificOutput":{"permissionDecision":"ask"}}'` }] }] } }));
  llm.reply({ calls: [{ id: "w", name: "write", args: { path: "from-run.txt", content: "ok" } }] }, { text: "written" });
  const t = new Tui(sb, ["run", "write it"]);
  ui = t;
  await waitFor(() => t.output.includes("Allow? [y/N]: "), "terminal question");
  expect(t.output).toContain("Allow this write call?");
  t.send("y\r");
  await waitFor(() => t.process.exitCode !== null, "run exit");
  expect(t.process.exitCode).toBe(0);
  expect(existsSync(join(sb.project, "from-run.txt"))).toBe(true);
}, 15000);

test("TUI attaches an image and sends it with the editor text", async () => {
  sb.writeConfig({ model: "fake/vision", provider: { fake: { options: { baseURL: llm.baseURL }, models: { vision: { name: "Vision", attachment: true } } } } });
  const encoded = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2nAAAAABJRU5ErkJggg==";
  writeFileSync(join(sb.project, "pixel.png"), Buffer.from(encoded, "base64"));
  const t = await start("fake/vision");
  t.send("/attach pixel.png\r");
  await waitFor(() => t.screen().includes("📎") && t.screen().includes("pixel.png"), "attachment chip");
  llm.reply({ text: "pixel described" });
  t.send("describe image\r");
  await waitFor(() => llm.requests.length > 0, "image request");
  const parts = llm.requests[0].messages.at(-1).content;
  expect(parts[0]).toEqual({ type: "text", text: "describe image" });
  expect(parts[1].image_url.url).toBe(`data:image/png;base64,${encoded}`);
  expect(await t.quit()).toBe(0);
}, 15000);

test("TUI paste is multiline data, resize stays interactive, and SIGTERM restores terminal", async () => {
  const t = await start();
  llm.reply({ text: "pasted" });
  t.send("\x1b[200~first line\nsecond line\x1b[201~");
  await waitFor(() => {
    const lines = t.screen().split("\n");
    const first = lines.findIndex((line) => line.includes("first line"));
    const second = lines.findIndex((line) => line.includes("second line"));
    return first >= 0 && second > first;
  }, "visible multiline editor");
  expect(llm.requests).toHaveLength(0);
  t.terminal.resize(36, 12);
  t.send("\r");
  await waitFor(() => llm.requests.some((r) => r.messages.some((m: any) => m.content === "first line\nsecond line")), "multiline paste");
  t.process.kill("SIGTERM");
  await waitFor(() => t.process.exitCode !== null, "signal exit");
  expect(t.output).toContain("\x1b[?1049l");
  expect(t.flags()).toEqual(t.original);
}, 15000);

test("TUI reconnects after server restart and continues the selected session", async () => {
  const t = await start();
  const id = (await sessions())[0].id;
  llm.reply({ text: "before restart" });
  t.send("first turn\r");
  await waitFor(async () => {
    const s = await state();
    return !s.running && s.messages.some((m: any) => m.role === "assistant");
  }, "first turn complete");
  const oldPid = sb.discovery().pid;
  expect((await sb.zeta(["server", "stop"])).code).toBe(0);
  await waitFor(() => existsSync(sb.discoveryPath) && sb.discovery().pid !== oldPid, "server reattach");
  // Wait for snapshot hydration, then send a follow-up through the same UI.
  await Bun.sleep(300);
  llm.reply({ text: "after restart" });
  t.send("second turn\r");
  await waitFor(() => llm.requests.some((r) => r.messages.some((m: any) => m.content === "second turn")), "post-restart prompt");
  const request = llm.requests.findLast((r) => r.messages.some((m: any) => m.content === "second turn"));
  expect(request.messages.filter((m: any) => m.content === "first turn")).toHaveLength(1);
  expect((await sessions()).some((s: any) => s.id === id)).toBe(true);
  expect(await t.quit()).toBe(0);
}, 15000);

test("TUI /delete replaces the session and keeps running", async () => {
  const t = await start();
  const before = (await sessions())[0].id;
  t.send("/delete\r");
  await waitFor(async () => {
    const list = await sessions();
    return list.length === 1 && list[0].id !== before;
  }, "replacement session");
  await waitFor(() => t.screen().includes("fake/base"), "hydrated replacement");
  expect(t.process.exitCode).toBeNull();
  expect(await t.quit()).toBe(0);
}, 15000);

test("TUI shows provider failure details and remains interactive", async () => {
  const t = await start();
  llm.reply({ status: 401, body: '{"error":{"message":"bad test key"}}' });
  t.send("fail this turn\r");
  await waitFor(() => t.screen().includes("bad test key"), "provider error detail");
  expect(t.process.exitCode).toBeNull();
  expect(await t.quit()).toBe(0);
}, 15000);

test("TUI starts on the first listed model, then on the last one picked", async () => {
  sb.writeConfig({ provider: { fake: { options: { baseURL: llm.baseURL }, models: { base: { name: "Base" }, other: { name: "Other" } } } } });
  const t = await start("fake/base");
  t.send("\x0c");
  await waitFor(() => t.screen().includes("Model"), "model picker");
  t.send("other\r");
  await waitFor(async () => (await state()).options.model === "fake/other", "model selection");
  expect(await t.quit()).toBe(0);
  ui = new Tui(sb);
  await ui.ready();
  await waitFor(() => ui!.screen().includes("fake/other"), "remembered model after relaunch");
}, 15000);

test("TUI model picker changes the next run without losing the editor draft", async () => {
  sb.writeConfig({ model: "fake/base", provider: { fake: { options: { baseURL: llm.baseURL }, models: { base: { name: "Base" }, other: { name: "Other" } } } } });
  const t = await start();
  t.send("saved draft\x0c");
  await waitFor(() => t.screen().includes("Model"), "model picker");
  t.send("other\r");
  await waitFor(async () => (await state()).options.model === "fake/other", "model selection");
  llm.reply({ text: "picked" });
  t.send("\r");
  await waitFor(() => llm.requests.some((r) => r.messages.some((m: any) => m.content === "saved draft")), "preserved draft submission");
  expect(llm.requests.at(-1).model).toBe("other");
  expect(await t.quit()).toBe(0);
}, 15000);

test("TUI reasoning and tool previews toggle without requiring another event", async () => {
  writeFileSync(join(sb.project, "long.txt"), Array.from({ length: 24 }, (_, n) => `source line ${n}`).join("\n") + "\nTOOL_TAIL_MARKER\n");
  const t = await start();
  llm.reply({ calls: [{ id: "read-long", name: "read", args: { path: "long.txt" } }] }, { text: "Read completed", reasoning: "REASONING_MARKER " + "and then more reasoning ".repeat(12) });
  t.send("read the long file\r");
  await waitFor(async () => {
    const s = await state();
    return !s.running && s.messages.some((m: any) => m.content.some((p: any) => p.text === "Read completed"));
  }, "completed tool turn");
  await waitFor(() => t.screen().includes("Read completed"), "rendered reply");
  // Collapsed, reasoning shows only its most recent words.
  expect(t.screen()).toContain("▶ Thinking: …");
  expect(t.screen()).not.toContain("REASONING_MARKER");
  expect(t.screen()).not.toContain("TOOL_TAIL_MARKER");
  // The footer follows once the turn goes idle.
  await waitFor(() => /Worked for \d+s · \d+:\d\d [AP]M/.test(t.screen()), "turn footer");
  t.send("\x14");
  await waitFor(() => t.screen().includes("REASONING_MARKER"), "expanded reasoning");
  t.send("\x0f\x1b[F");
  await waitFor(() => t.screen().includes("TOOL_TAIL_MARKER"), "expanded tool output");
  t.send("\x14\x0f");
  await waitFor(() => !t.screen().includes("REASONING_MARKER") && !t.screen().includes("TOOL_TAIL_MARKER"), "collapsed previews");
  expect(await t.quit()).toBe(0);
}, 15000);

test("TUI completes and runs prompt templates; unknown slash names are sent as text", async () => {
  mkdirSync(join(sb.project, ".zeta/prompts"), { recursive: true });
  writeFileSync(join(sb.project, ".zeta/prompts/review.md"), "---\ndescription: Review a file\nargument-hint: <path>\n---\nReview $1 carefully.");
  const t = await start();
  t.send("/rev");
  await waitFor(() => t.screen().includes("/review <path>") && t.screen().includes("Review a file (project)"), "template completion");
  t.send("\r");
  await waitFor(() => t.screen().includes(" /review") && !t.screen().includes("Review a file (project)"), "completed template");
  llm.reply({ text: "template reviewed" });
  t.send("a.zig\r");
  await waitFor(() => llm.requests.some((r) => JSON.stringify(r.messages).includes("Review a.zig carefully.")), "expanded template");
  await waitFor(() => t.screen().includes("template reviewed"), "template reply");
  llm.reply({ text: "plain slash" });
  t.send("/nosuch thing\r");
  await waitFor(() => llm.requests.some((r) => JSON.stringify(r.messages).includes("/nosuch thing")), "unknown slash sent as text");
  expect(await t.quit()).toBe(0);
}, 15000);

test("TUI /mcp shows server status in the status line", async () => {
  sb.writeConfig({
    model: "fake/base",
    provider: { fake: { options: { baseURL: llm.baseURL } } },
    mcp: { servers: { fake: { type: "local", command: [process.execPath, join(import.meta.dir, "fake-mcp.ts")] } } },
  });
  const t = await start();
  t.send("/mcp\r");
  await waitFor(() => /MCP: fake (pending|connected)/.test(t.screen()), "mcp status");
  t.send("/mcp fake\r");
  await waitFor(() => /MCP: fake (pending|connected)/.test(t.screen()) && !t.screen().includes("/mcp fake"), "reconnect sent");
  for (let i = 0; i < 20 && !t.screen().includes("MCP: fake connected (4 tools)"); i++) {
    t.send("/mcp\r");
    await Bun.sleep(100);
  }
  expect(t.screen()).toContain("MCP: fake connected (4 tools)");
  expect(await t.quit()).toBe(0);
}, 15000);

test("TUI /extensions shows extension status in the status line", async () => {
  const { cpSync } = await import("node:fs");
  mkdirSync(join(sb.project, ".zeta", "extensions"), { recursive: true });
  cpSync(join(import.meta.dir, "../../docs/examples/extensions/hello"), join(sb.project, ".zeta", "extensions", "hello"), { recursive: true });
  const t = await start();
  for (let i = 0; i < 30 && !t.screen().includes("Extensions: hello running"); i++) {
    t.send("/extensions\r");
    await Bun.sleep(100);
  }
  expect(t.screen()).toContain("Extensions: hello running");
  expect(await t.quit()).toBe(0);
}, 15000);

test("TUI /cd completes directories and moves the session to that project", async () => {
  mkdirSync(join(sb.project, ".git"), { recursive: true });
  const other = join(sb.root, "other");
  mkdirSync(join(other, ".git"), { recursive: true });
  const t = await start();
  llm.reply({ text: "first reply" });
  t.send("first\r");
  await waitFor(() => t.screen().includes("first reply"), "first reply");
  t.send("/cd ../oth");
  await waitFor(() => t.screen().includes("other/"), "directory completion");
  t.send("\t");
  await waitFor(() => t.screen().includes("/cd ../other/"), "completed directory");
  t.send("\r");
  await waitFor(() => t.screen().includes(`Moved to ${other}`), "moved status");
  await waitFor(() => t.screen().includes("→ The project directory is now"), "move notice");
  expect((await (await sb.api(`/sessions?location=${encodeURIComponent(other)}`)).json())).toHaveLength(1);
  llm.reply({ text: "second reply" });
  t.send("second\r");
  await waitFor(() => t.screen().includes("second reply"), "second reply");
  const request = JSON.stringify(llm.requests[1].messages);
  expect(request).toContain(`Project directory: ${other}`);
  expect(request).toContain("The project directory is now");
  t.send("/cd .\r");
  await waitFor(() => t.screen().includes(`Already in ${other}`), "same project");
  expect(await t.quit()).toBe(0);
}, 20000);

test("tui.jsonc can show thinking expanded from the start", async () => {
  writeFileSync(join(sb.env.XDG_CONFIG_HOME, "zeta", "tui.jsonc"), '{\n  // shown in full\n  "thinking": "expanded",\n}\n');
  const t = await start();
  llm.reply({ text: "Answer", reasoning: "EXPANDED_REASONING " + "and more ".repeat(20) });
  t.send("think\r");
  await waitFor(() => t.screen().includes("Answer"), "reply");
  expect(t.screen()).toContain("▼ Thinking:");
  expect(t.screen()).toContain("EXPANDED_REASONING");
  expect(await t.quit()).toBe(0);
}, 15000);
