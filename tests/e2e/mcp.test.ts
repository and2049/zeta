import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { FakeOpenAI } from "./fake-openai";
import { Sandbox, jsonEvents } from "./harness";

let sb: Sandbox;
let llm: FakeOpenAI;
let http: ReturnType<typeof Bun.spawn> | null = null;
const fake = join(import.meta.dir, "fake-mcp.ts");

function config(servers: Record<string, unknown>) {
  sb.writeConfig({
    model: "fake/test-model",
    provider: { fake: { options: { baseURL: llm.baseURL } } },
    mcp: { timeout: 10000, servers },
  });
}

const local = { type: "local", command: [process.execPath, fake] };

async function mcpStatus() {
  return (await (await sb.api(`/mcp?location=${encodeURIComponent(sb.project)}`)).json()).servers as Array<{ name: string; status: string; tools: number; error?: string }>;
}

beforeEach(() => {
  sb = new Sandbox();
  llm = new FakeOpenAI();
});

afterEach(async () => {
  http?.kill();
  http = null;
  await sb.cleanup();
  llm.stop();
});

describe("mcp", () => {
  test("a local server's tools are offered to the model and run", async () => {
    config({ fake: local });
    llm.reply(
      { calls: [{ id: "e", name: "mcp__fake__echo", args: { text: "hello" } }, { id: "a", name: "mcp__fake__add", args: { a: 2, b: 3 } }, { id: "f", name: "mcp__fake__fail", args: {} }] },
      { text: "done" },
    );
    const result = await sb.zeta(["run", "use the tools"]);
    expect(result.code).toBe(0);
    const offered = llm.requests[0].tools.map((t: { function: { name: string } }) => t.function.name);
    expect(offered).toContain("mcp__fake__echo");
    expect(offered).toContain("mcp__fake__add");
    const results = llm.requests[1].messages.filter((m: { role: string }) => m.role === "tool");
    expect(results.find((m: { tool_call_id: string }) => m.tool_call_id === "e").content).toBe("hello");
    expect(results.find((m: { tool_call_id: string }) => m.tool_call_id === "a").content).toBe('{"sum":5}');
    expect(results.find((m: { tool_call_id: string }) => m.tool_call_id === "f").content).toBe("it broke");
    const status = await mcpStatus();
    expect(status).toEqual([{ name: "fake", status: "connected", tools: 4, error: null, signIn: null }]);
    const registry = await (await sb.api(`/registry?location=${encodeURIComponent(sb.project)}`)).json();
    expect(registry.tools.some((t: { name: string; plugin: string }) => t.name === "mcp__fake__echo" && t.plugin === "mcp:fake")).toBe(true);
    expect(registry.mcp[0].status).toBe("connected");
  });

  test("tools/list_changed brings new tools to the next run", async () => {
    config({ fake: local });
    llm.reply({ calls: [{ id: "g", name: "mcp__fake__grow", args: {} }] }, { text: "grown" });
    expect((await sb.zeta(["run", "grow"])).code).toBe(0);
    for (let i = 0; i < 50 && (await mcpStatus())[0].tools !== 5; i++) await Bun.sleep(20);
    llm.reply({ calls: [{ id: "x", name: "mcp__fake__extra", args: {} }] }, { text: "ok" });
    expect((await sb.zeta(["run", "again"])).code).toBe(0);
    expect(llm.requests[3].messages.at(-1).content).toBe("extra ran");
  });

  test("a remote server over Streamable HTTP", async () => {
    http = Bun.spawn([process.execPath, fake, "--http"], { stdout: "pipe" });
    const reader = http.stdout.getReader();
    const url = new TextDecoder().decode((await reader.read()).value).trim();
    config({ remote: { type: "remote", url, headers: { "x-test": "1" } } });
    llm.reply({ calls: [{ id: "e", name: "mcp__remote__echo", args: { text: "over http" } }] }, { text: "done" });
    const result = await sb.zeta(["run", "remote"]);
    expect(result.code).toBe(0);
    expect(llm.requests[1].messages.at(-1).content).toBe("over http");
  });

  test("an expired HTTP session fails the server until it reconnects", async () => {
    http = Bun.spawn([process.execPath, fake, "--http", "--expire-after", "1"], { stdout: "pipe" });
    const url = new TextDecoder().decode((await http.stdout.getReader().read()).value).trim();
    config({ remote: { type: "remote", url } });
    llm.reply(
      { calls: [{ id: "e1", name: "mcp__remote__echo", args: { text: "one" } }] },
      { calls: [{ id: "e2", name: "mcp__remote__echo", args: { text: "two" } }] },
      { text: "done" },
    );
    expect((await sb.zeta(["run", "remote"])).code).toBe(0);
    expect(llm.requests[1].messages.at(-1).content).toBe("one");
    expect(llm.requests[2].messages.at(-1).content).toContain("McpSessionExpired");
    for (let i = 0; i < 50 && (await mcpStatus())[0].status !== "failed"; i++) await Bun.sleep(20);
    const status = (await mcpStatus())[0];
    expect(status.status).toBe("failed");
    expect(status.error).toContain("session expired");
    const registry = await (await sb.api(`/registry?location=${encodeURIComponent(sb.project)}`)).json();
    expect(registry.tools.some((t: { name: string }) => t.name.startsWith("mcp__remote__"))).toBe(false);
  });

  test("a remote server that keeps its event stream open after answering", async () => {
    http = Bun.spawn([process.execPath, fake, "--http", "--hold-open"], { stdout: "pipe" });
    const url = new TextDecoder().decode((await http.stdout.getReader().read()).value).trim();
    config({ remote: { type: "remote", url } });
    llm.reply({ calls: [{ id: "e", name: "mcp__remote__echo", args: { text: "held" } }] }, { text: "done" });
    expect((await sb.zeta(["run", "remote"])).code).toBe(0);
    expect(llm.requests[1].messages.at(-1).content).toBe("held");
  });

  test("reload replaces servers without losing their tools", async () => {
    config({ fake: local });
    llm.reply({ text: "one" });
    expect((await sb.zeta(["run", "hi"])).code).toBe(0);
    const reload = await (await sb.api("/registry/reload", "POST", { location: sb.project })).json();
    expect(reload.failures).toEqual([]);
    llm.reply({ calls: [{ id: "e", name: "mcp__fake__echo", args: { text: "after reload" } }] }, { text: "done" });
    expect((await sb.zeta(["run", "again"])).code).toBe(0);
    expect(llm.requests[2].messages.at(-1).content).toBe("after reload");
    expect((await mcpStatus())[0]).toEqual({ name: "fake", status: "connected", tools: 4, error: null, signIn: null });
  });

  test("one configured server runs in two projects", async () => {
    config({ fake: local });
    const other = join(sb.root, "other");
    mkdirSync(other, { recursive: true });
    llm.reply({ text: "hi" });
    expect((await sb.zeta(["run", "hi"])).code).toBe(0);
    const here = await mcpStatus();
    const there = (await (await sb.api(`/mcp?location=${encodeURIComponent(other)}`)).json()).servers;
    for (let i = 0; i < 100 && (await (await sb.api(`/mcp?location=${encodeURIComponent(other)}`)).json()).servers[0].status !== "connected"; i++) await Bun.sleep(20);
    const later = (await (await sb.api(`/mcp?location=${encodeURIComponent(other)}`)).json()).servers[0];
    expect(here[0].status).toBe("connected");
    expect(there.length).toBe(1);
    expect(later).toEqual({ name: "fake", status: "connected", tools: 4, error: null, signIn: null });
  });

  test("failed, disabled and unknown servers", async () => {
    config({
      broken: { type: "local", command: ["/bin/sh", "-c", "echo 'cannot start' >&2; exit 3"] },
      off: { ...local, disabled: true },
      bad: { type: "local", command: [] },
    });
    llm.reply({ text: "fine" });
    expect((await sb.zeta(["run", "hi"])).code).toBe(0);
    const offered = (llm.requests[0].tools ?? []).map((t: { function: { name: string } }) => t.function.name);
    expect(offered.some((name: string) => name.startsWith("mcp__"))).toBe(false);
    const status = await mcpStatus();
    const broken = status.find((s) => s.name === "broken")!;
    expect(broken.status).toBe("failed");
    expect(broken.error).toContain("cannot start");
    expect(status.find((s) => s.name === "off")!.status).toBe("disabled");
    expect(status.some((s) => s.name === "bad")).toBe(false);
    const registry = await (await sb.api(`/registry?location=${encodeURIComponent(sb.project)}`)).json();
    expect(registry.diagnostics.some((d: string) => d.includes("mcp server 'bad'"))).toBe(true);
    expect((await sb.api("/mcp/nope/connect", "POST", { location: sb.project })).status).toBe(404);
    expect((await sb.api("/mcp/broken/connect", "POST", { location: sb.project })).status).toBe(200);
  });

  test("a server that needs a sign-in: sign in, refresh a refused token, sign out", async () => {
    http = Bun.spawn([process.execPath, fake, "--http", "--oauth"], { stdout: "pipe" });
    const url = new TextDecoder().decode((await http.stdout.getReader().read()).value).trim();
    config({ remote: { type: "remote", url } });
    const settled = async (want: string) => {
      for (let i = 0; i < 200 && (await mcpStatus())[0]?.status !== want; i++) await Bun.sleep(20);
      return (await mcpStatus())[0];
    };
    // Listing starts the shared server and the project's MCP servers.
    await sb.zeta(["mcp"]);
    expect((await settled("needs_auth")).status).toBe("needs_auth");
    expect((await sb.zeta(["mcp"])).stdout).toContain("remote needs_auth: sign-in required");

    const started = await sb.api("/mcp/remote/auth", "POST", { location: sb.project });
    expect(started.status).toBe(200);
    const { url: authorize } = await started.json();
    expect((await mcpStatus())[0].signIn.state).toBe("running");
    // The browser: the authorization server redirects to zeta's listener.
    const redirected = await fetch(authorize, { redirect: "manual" });
    expect(redirected.status).toBe(302);
    expect((await fetch(redirected.headers.get("location")!)).status).toBe(200);
    expect((await settled("connected")).tools).toBe(4);
    const stored = JSON.parse(await Bun.file(join(sb.env.XDG_DATA_HOME, "zeta", "credentials.json")).text());
    expect(stored["mcp:remote"].type).toBe("mcp");
    expect(stored["mcp:remote"].url).toBe(url);

    // The first token stops working after a call; the next call refreshes it.
    llm.reply(
      { calls: [{ id: "e1", name: "mcp__remote__echo", args: { text: "one" } }] },
      { calls: [{ id: "e2", name: "mcp__remote__echo", args: { text: "two" } }] },
      { text: "done" },
    );
    expect((await sb.zeta(["run", "remote"])).code).toBe(0);
    expect(llm.requests[2].messages.at(-1).content).toBe("two");

    const out = await sb.zeta(["mcp", "logout", "remote"]);
    expect(out.code).toBe(0);
    expect((await settled("needs_auth")).status).toBe("needs_auth");
    expect(JSON.parse(await Bun.file(join(sb.env.XDG_DATA_HOME, "zeta", "credentials.json")).text())["mcp:remote"]).toBeUndefined();
    expect((await sb.api("/mcp/missing/auth", "POST", { location: sb.project })).status).toBe(404);
  });

  test("a revoked sign-in makes the server need a new one; no PKCE, no sign-in", async () => {
    http = Bun.spawn([process.execPath, fake, "--http", "--oauth", "--revoke-after", "1"], { stdout: "pipe" });
    const url = new TextDecoder().decode((await http.stdout.getReader().read()).value).trim();
    config({ remote: { type: "remote", url } });
    await sb.zeta(["mcp"]);
    const { url: authorize } = await (await sb.api("/mcp/remote/auth", "POST", { location: sb.project })).json();
    const redirected = await fetch(authorize, { redirect: "manual" });
    await fetch(redirected.headers.get("location")!);
    for (let i = 0; i < 200 && (await mcpStatus())[0].status !== "connected"; i++) await Bun.sleep(20);
    llm.reply(
      { calls: [{ id: "e1", name: "mcp__remote__echo", args: { text: "one" } }] },
      { calls: [{ id: "e2", name: "mcp__remote__echo", args: { text: "two" } }] },
      { text: "done" },
    );
    await sb.zeta(["run", "remote"]);
    const status = (await mcpStatus())[0];
    expect(status.status).toBe("needs_auth");
    expect(status.tools).toBe(0);

    http.kill();
    http = Bun.spawn([process.execPath, fake, "--http", "--oauth", "--no-pkce"], { stdout: "pipe" });
    const plain = new TextDecoder().decode((await http.stdout.getReader().read()).value).trim();
    config({ remote: { type: "remote", url: plain } });
    await sb.zeta(["reload"]);
    const refused = await sb.api("/mcp/remote/auth", "POST", { location: sb.project });
    expect(refused.status).toBe(502);
    expect(await refused.json()).toEqual({ error: "McpPkceUnsupported" });
  });

  test("prompts become commands; instructions, annotations, roots and disabled tools", async () => {
    config({ fake: { ...local, command: [process.execPath, fake, "--instructions"], disabled_tools: ["fa*"] } });
    llm.reply({ text: "ok" });
    expect((await sb.zeta(["run", "hello"])).code).toBe(0);
    const system = String(llm.requests[0].messages[0].content);
    expect(system).toContain("Instructions from the MCP server fake (tools mcp__fake__*):\nPrefer echo for greetings.");
    const offered = llm.requests[0].tools.map((t: { function: { name: string } }) => t.function.name);
    expect(offered).toContain("mcp__fake__echo");
    expect(offered).not.toContain("mcp__fake__fail");
    const registry = await (await sb.api(`/registry?location=${encodeURIComponent(sb.project)}`)).json();
    expect(registry.tools.find((t: { name: string }) => t.name === "mcp__fake__echo").sideEffect).toBe("read");
    expect(registry.tools.find((t: { name: string }) => t.name === "mcp__fake__add").sideEffect).toBe("system");

    const listing = await (await sb.api(`/commands?location=${encodeURIComponent(sb.project)}`)).json();
    const review = listing.commands.find((c: { name: string }) => c.name === "fake:review");
    expect(review.argumentHint).toBe("<file> [focus]");
    const session = (await (await sb.api("/sessions", "POST", { location: sb.project })).json()).id;
    llm.reply({ text: "reviewed" }, { text: "rooted" });
    expect((await sb.api(`/sessions/${session}/command`, "POST", { name: "fake:review", arguments: "src/a.zig security and speed" })).status).toBe(200);
    for (let i = 0; i < 200 && llm.requests.length < 2; i++) await Bun.sleep(20);
    expect(llm.requests[1].messages.at(-1).content).toBe("Review src/a.zig focusing on security and speed.");
    expect((await sb.api(`/sessions/${session}/command`, "POST", { name: "fake:roots", arguments: "" })).status).toBe(200);
    for (let i = 0; i < 200 && llm.requests.length < 3; i++) await Bun.sleep(20);
    const roots = JSON.parse(llm.requests[2].messages.at(-1).content);
    expect(roots.roots[0].uri).toBe(`file://${sb.project}`);
    // The server's own words reach the user; the last argument keeps its text.
    const missing = await sb.api(`/sessions/${session}/command`, "POST", { name: "fake:review", arguments: "" });
    expect(missing.status).toBe(502);
    expect(await missing.text()).toContain("MCP error -32602: file is required");
    llm.reply({ text: "kept" });
    expect((await sb.api(`/sessions/${session}/command`, "POST", { name: "fake:review", arguments: "a.zig what's  wrong" })).status).toBe(200);
    for (let i = 0; i < 200 && llm.requests.length < 4; i++) await Bun.sleep(20);
    expect(llm.requests[3].messages.at(-1).content).toBe("Review a.zig focusing on what's  wrong.");
  });

  test("prompts that cannot be listed leave the tools; the instructions name the real tool prefix", async () => {
    config({ "my.docs": { ...local, command: [process.execPath, fake, "--prompts-broken", "--instructions"] } });
    llm.reply({ text: "ok" });
    expect((await sb.zeta(["run", "hello"])).code).toBe(0);
    expect((await mcpStatus())[0].status).toBe("connected");
    const offered = llm.requests[0].tools.map((t: { function: { name: string } }) => t.function.name);
    expect(offered).toContain("mcp__my_docs__echo");
    expect(String(llm.requests[0].messages[0].content)).toContain("Instructions from the MCP server my.docs (tools mcp__my_docs__*)");
  });

  test("a server with prompts only, under a name with a space", async () => {
    config({ "my docs": { ...local, command: [process.execPath, fake, "--prompts-only", "--instructions"] } });
    llm.reply({ text: "ok" });
    expect((await sb.zeta(["run", "hello"])).code).toBe(0);
    expect(await mcpStatus()).toEqual([{ name: "my docs", status: "connected", tools: 0, error: null, signIn: null }]);
    // No tools of it are offered, so neither are its instructions.
    expect(String(llm.requests[0].messages[0].content)).not.toContain("Prefer echo");
    const listing = await (await sb.api(`/commands?location=${encodeURIComponent(sb.project)}`)).json();
    expect(listing.commands.map((c: { name: string }) => c.name)).toContain("my_docs:review");
  });

  test("a deferred server's tools are found with mcp_search and run with mcp_call", async () => {
    config({ fake: { ...local, deferred: true } });
    llm.reply(
      { calls: [{ id: "s", name: "mcp_search", args: { query: "echo text" } }] },
      { calls: [{ id: "c", name: "mcp_call", args: { name: "mcp__fake__echo", arguments: { text: "deferred" } } }] },
      { text: "done" },
    );
    expect((await sb.zeta(["run", "find it"])).code).toBe(0);
    const offered = llm.requests[0].tools.map((t: { function: { name: string } }) => t.function.name);
    expect(offered).toContain("mcp_search");
    expect(offered).toContain("mcp_call");
    expect(offered.some((n: string) => n.startsWith("mcp__fake__"))).toBe(false);
    const found = JSON.parse(llm.requests[1].messages.at(-1).content);
    expect(found.tools[0].name).toBe("mcp__fake__echo");
    expect(found.tools[0].inputSchema.required).toEqual(["text"]);
    expect(llm.requests[2].messages.at(-1).content).toBe("deferred");

    // Hooks see the real tool.
    mkdirSync(join(sb.project, ".zeta"), { recursive: true });
    writeFileSync(join(sb.project, ".zeta", "hooks.json"), JSON.stringify({ hooks: { PreToolUse: [{ matcher: "mcp__fake__echo", hooks: [{ type: "command", command: "echo 'no echo' >&2; exit 2" }] }] } }));
    expect((await sb.zeta(["reload"])).code).toBe(0);
    llm.reply({ calls: [{ id: "d", name: "mcp_call", args: { name: "mcp__fake__echo", arguments: { text: "no" } } }] }, { text: "done" });
    const blocked = await sb.zeta(["run", "--json", "again"]);
    const end = jsonEvents(blocked.stdout).find((e) => e.type === "tool.execution.end");
    expect(end?.data.result?.content[0].text).toBe("no echo");
  });

  test("turning deferred off and on again over reloads swaps the search tools", async () => {
    const names = async () =>
      (await (await sb.api(`/registry?location=${encodeURIComponent(sb.project)}`)).json()).tools.map((t: { name: string }) => t.name);
    config({ fake: { ...local, deferred: true } });
    llm.reply({ text: "ok" });
    expect((await sb.zeta(["run", "hello"])).code).toBe(0);
    expect(await names()).toContain("mcp_call");
    for (const deferred of [false, true]) {
      config({ fake: { ...local, deferred } });
      expect((await sb.zeta(["reload"])).code).toBe(0);
      llm.reply({ text: "ok" });
      expect((await sb.zeta(["run", "again"])).code).toBe(0);
      const offered = llm.requests.at(-1).tools.map((t: { function: { name: string } }) => t.function.name);
      expect(offered.includes("mcp_call")).toBe(deferred);
      expect(offered.includes("mcp__fake__echo")).toBe(!deferred);
      expect((await names()).includes("mcp_search")).toBe(deferred);
    }
  });

  test("a server's question is declined by zeta run and answered through the API", async () => {
    config({ fake: { ...local, command: [process.execPath, fake, "--ask"] } });
    llm.reply({ calls: [{ id: "q", name: "mcp__fake__ask", args: {} }] }, { text: "done" });
    const run = await sb.zeta(["run", "ask me"]);
    expect(run.stderr).toContain("mcp:fake asked: Which branch? (declined: no terminal to answer on)");
    expect(JSON.parse(llm.requests[1].messages.at(-1).content)).toEqual({ action: "decline" });

    // A client that stays subscribed answers it.
    const { url, password } = sb.discovery();
    const events = await fetch(`${url}/event`, { headers: { authorization: `Basic ${btoa(`zeta:${password}`)}` } });
    const session = (await (await sb.api("/sessions", "POST", { location: sb.project })).json()).id;
    llm.reply({ calls: [{ id: "q2", name: "mcp__fake__ask", args: {} }] }, { text: "done" });
    await sb.api(`/sessions/${session}/prompt`, "POST", { text: "ask again" });
    let open: Array<{ id: string; kind: string; source: string; message: string; schema: { required: string[] } }> = [];
    for (let i = 0; i < 200 && open.length === 0; i++) {
      open = (await (await sb.api(`/questions?location=${encodeURIComponent(sb.project)}`)).json()).questions;
      await Bun.sleep(20);
    }
    expect(open[0].source).toBe("mcp:fake");
    expect(open[0].kind).toBe("form");
    expect((open[0] as unknown as { session: string }).session).toBe(session);
    expect(open[0].schema.required).toEqual(["branch"]);

    // A run in the same project leaves another session's question alone.
    llm.reply({ text: "unrelated" });
    const other = await sb.zeta(["run", "something else"]);
    expect(other.code).toBe(0);
    expect(other.stderr).not.toContain("declined");
    expect((await (await sb.api(`/questions?location=${encodeURIComponent(sb.project)}`)).json()).questions.length).toBe(1);
    expect((await sb.api(`/questions/${open[0].id}/reply`, "POST", { action: "accept" })).status).toBe(400);
    const misfit = await sb.api(`/questions/${open[0].id}/reply`, "POST", { action: "accept", content: { branch: 42 } });
    expect(misfit.status).toBe(400);
    expect(await misfit.text()).toContain("branch");
    expect((await sb.api(`/questions/${open[0].id}/reply`, "POST", { action: "accept", content: { branch: "main" } })).status).toBe(200);
    for (let i = 0; i < 200 && llm.requests.length < 5; i++) await Bun.sleep(20);
    expect(JSON.parse(llm.requests[4].messages.at(-1).content)).toEqual({ action: "accept", content: { branch: "main" } });

    // A URL elicitation was never declared: invalid params.
    llm.reply({ calls: [{ id: "u", name: "mcp__fake__ask_url", args: {} }] }, { text: "done" });
    await sb.api(`/sessions/${session}/prompt`, "POST", { text: "visit" });
    for (let i = 0; i < 200 && llm.requests.length < 7; i++) await Bun.sleep(20);
    expect(JSON.parse(llm.requests[6].messages.at(-1).content).error.code).toBe(-32602);
    await events.body?.cancel();
  });

  test("a question the server cancels, or whose call times out, is withdrawn", async () => {
    config({ fake: { ...local, command: [process.execPath, fake, "--ask"], timeout: 400 } });
    expect((await sb.zeta(["mcp"])).code).toBe(0);
    const { url, password } = sb.discovery();
    const events = await fetch(`${url}/event`, { headers: { authorization: `Basic ${btoa(`zeta:${password}`)}` } });
    const session = (await (await sb.api("/sessions", "POST", { location: sb.project })).json()).id;
    const open = async () => (await (await sb.api(`/questions?location=${encodeURIComponent(sb.project)}`)).json()).questions;
    const waitFor = async (want: number) => {
      for (let i = 0; i < 200 && (await open()).length !== want; i++) await Bun.sleep(10);
      return open();
    };

    // The call's deadline bounds the question, and the call's end takes it back.
    llm.reply({ calls: [{ id: "t", name: "mcp__fake__ask", args: {} }] }, { text: "done" });
    const asked = Date.now();
    await sb.api(`/sessions/${session}/prompt`, "POST", { text: "ask" });
    const [question] = await waitFor(1);
    expect(question.expiresAt - asked).toBeLessThanOrEqual(1000);
    expect(await waitFor(0)).toEqual([]);
    for (let i = 0; i < 200 && llm.requests.length < 2; i++) await Bun.sleep(20);
    expect(String(llm.requests[1].messages.at(-1).content)).toContain("Timeout");

    // Cancelled by the server: withdrawn, and no reply goes back.
    config({ fake: { ...local, command: [process.execPath, fake, "--ask"] } });
    expect((await sb.zeta(["reload"])).code).toBe(0);
    llm.reply({ calls: [{ id: "c", name: "mcp__fake__ask_then_cancel", args: {} }] }, { text: "done" });
    await sb.api(`/sessions/${session}/prompt`, "POST", { text: "ask and cancel" });
    expect((await waitFor(1)).length).toBe(1);
    expect(await waitFor(0)).toEqual([]);
    for (let i = 0; i < 200 && llm.requests.length < 4; i++) await Bun.sleep(20);
    expect(llm.requests[3].messages.at(-1).content).toBe("replied: false");
    await events.body?.cancel();
  });
});
