import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { closeSync, mkdirSync, openSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { connect } from "node:net";
import { dirname, join } from "node:path";
import { FakeOpenAI } from "./fake-openai";
import { Sandbox, zetaBin } from "./harness";

let sb: Sandbox;
let llm: FakeOpenAI;

beforeEach(() => {
  sb = new Sandbox();
  llm = new FakeOpenAI();
  sb.writeConfig({
    model: "fake/test-model",
    provider: { fake: { options: { baseURL: llm.baseURL, apiKey: "{env:FAKE_KEY}" } } },
  });
});

afterEach(async () => {
  await sb.cleanup();
  llm.stop();
});

describe("zeta run", () => {
  test("unused sessions are hidden until their first prompt", async () => {
    llm.reply({ text: "initial" }, { text: "ready" });
    expect((await sb.zeta(["run", "start"])).code).toBe(0);
    const created = await (await sb.api("/sessions", "POST", { location: sb.project })).json();
    expect((await sb.api(`/sessions/${created.id}`)).status).toBe(200);
    const listed = async () => (await (await sb.api("/sessions")).json()) as { id: string }[];
    expect((await listed()).some((s) => s.id === created.id)).toBe(false);
    expect((await (await sb.api(`/sessions?q=${created.id}`)).json()).length).toBe(0);
    expect((await sb.api(`/sessions/${created.id}/prompt`, "POST", { text: "hello" })).status).toBe(200);
    for (let i = 0; i < 50 && !(await listed()).some((s) => s.id === created.id); i++) await Bun.sleep(20);
    expect((await listed()).some((s) => s.id === created.id)).toBe(true);
  });

  test("--continue and --session conflict before reading stdin or starting a server", async () => {
    const proc = Bun.spawn([zetaBin, "run", "--continue", "--session", "ses_any", "hi"], {
      cwd: sb.project, env: sb.env, stdin: "pipe", stdout: "pipe", stderr: "pipe",
    });
    const code = await Promise.race([proc.exited, Bun.sleep(2000).then(() => { proc.kill(); return -1; })]);
    expect(code).toBe(2);
    expect(await new Response(proc.stderr).text()).toContain("--continue and --session cannot be used together");
    expect(() => sb.discovery()).toThrow();
  });

  test("auto-starts the server and streams the reply", async () => {
    llm.reply({ text: "Hello from the fake model" });
    const r = await sb.zeta(["run", "say", "hello"], { FAKE_KEY: "sk-test" });

    expect(r.stderr).toBe("");
    expect(r.code).toBe(0);
    expect(r.stdout).toBe("Hello from the fake model\n");

    const req = llm.requests[0];
    expect(req.model).toBe("test-model");
    expect(req.stream).toBe(true);
    expect(req.messages[0].role).toBe("system");
    expect(req.messages[1]).toEqual({ role: "user", content: "say hello" });
    expect(llm.headers[0].get("authorization")).toBe("Bearer sk-test");

    const d = sb.discovery();
    expect(d.url).toMatch(/^http:\/\/127\.0\.0\.1:\d+$/);
    expect(statSync(sb.discoveryPath).mode & 0o777).toBe(0o600);
    const [session] = await (await sb.api(`/sessions?location=${encodeURIComponent(sb.project)}`)).json();
    const { messages } = await (await sb.api(`/sessions/${session.id}/messages`)).json();
    const assistant = messages.find((m: { role: string }) => m.role === "assistant");
    expect(typeof assistant.completedAt).toBe("number");
    expect(assistant.completedAt).toBeGreaterThanOrEqual(assistant.timestamp);
  });

  test("a second run reuses the running server", async () => {
    llm.reply({ text: "one" }, { text: "two" });
    expect((await sb.zeta(["run", "first"])).stdout).toBe("one\n");
    const pid = sb.discovery().pid;
    expect((await sb.zeta(["run", "second"])).stdout).toBe("two\n");
    expect(sb.discovery().pid).toBe(pid);
  });

  test("--continue and --session prompt an earlier session", async () => {
    llm.reply({ text: "one" }, { text: "two" }, { text: "three" });
    expect((await sb.zeta(["run", "first"])).code).toBe(0);
    const [first] = await (await sb.api(`/sessions?location=${encodeURIComponent(sb.project)}`)).json();
    // From a subdirectory: the project's latest session.
    mkdirSync(join(sb.project, ".git"));
    mkdirSync(join(sb.project, "sub"));
    const second = await sb.zeta(["run", "-c", "second"], {}, join(sb.project, "sub"));
    expect(second.stdout).toBe("two\n");
    expect(llm.requests[1].messages.map((m: { content: string }) => m.content).slice(1)).toEqual(["first", "one", "second"]);
    const third = await sb.zeta(["run", "--session", first.id, "--thinking", "high", "third"]);
    expect(third.stdout).toBe("three\n");
    expect(llm.requests[2].messages.length).toBe(6);
    expect((await (await sb.api(`/sessions?location=${encodeURIComponent(sb.project)}`)).json()).length).toBe(1);
    const missing = await sb.zeta(["run", "--session", "ses_000000000000000000000000000", "hi"]);
    expect(missing.code).toBe(1);
    expect(missing.stderr).toContain("not found");
  });

  test("piped stdin and @file arguments join the prompt; images are attached", async () => {
    const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2nAAAAABJRU5ErkJggg==";
    writeFileSync(join(sb.project, "notes.txt"), "line one");
    writeFileSync(join(sb.project, "dot.png"), Buffer.from(png, "base64"));
    sb.writeConfig({ model: "fake/vision", provider: { fake: { options: { baseURL: llm.baseURL }, models: { vision: { name: "Vision", attachment: true, modalities: { input: ["text", "image"] } } } } } });
    llm.reply({ text: "ok" }, { text: "seen" });
    const proc = Bun.spawn([zetaBin, "run", "summarize", "@notes.txt"], { cwd: sb.project, env: sb.env, stdin: new Blob(["  from a pipe\n"]), stdout: "pipe", stderr: "pipe" });
    expect(await proc.exited).toBe(0);
    expect(llm.requests[0].messages[1].content).toBe(`from a pipe\n\n<file name="${join(sb.project, "notes.txt")}">\nline one\n</file>\n\nsummarize`);
    expect((await sb.zeta(["run", "@dot.png", "what", "is", "this"])).code).toBe(0);
    const content = llm.requests[1].messages[1].content;
    expect(content[0].text).toBe(`<file name="${join(sb.project, "dot.png")}"></file>\n\nwhat is this`);
    expect(content[1].image_url.url).toBe(`data:image/png;base64,${png}`);
    const missing = await sb.zeta(["run", "@nope.txt"]);
    expect(missing.code).toBe(1);
    expect(missing.stderr).toContain("nope.txt: not found");
  });

  test("read shows an image to a model that takes images, and a notice to one that does not", async () => {
    const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2nAAAAABJRU5ErkJggg==";
    writeFileSync(join(sb.project, "dot.png"), Buffer.from(png, "base64"));
    sb.writeConfig({ model: "fake/vision", provider: { fake: { options: { baseURL: llm.baseURL }, models: { vision: { name: "Vision", attachment: true, modalities: { input: ["text", "image"] } }, plain: { name: "Plain" } } } } });
    llm.reply({ calls: [{ id: "r", name: "read", args: { path: "dot.png" } }] }, { text: "a dot" });
    expect((await sb.zeta(["run", "look at dot.png"])).code).toBe(0);
    const [, , , tool, attached] = llm.requests[1].messages;
    expect(tool.content).toContain("Read image");
    expect(attached.content[1].image_url.url).toBe(`data:image/png;base64,${png}`);
    llm.reply({ text: "cannot see" });
    expect((await sb.zeta(["run", "-c", "--model", "fake/plain", "again"])).code).toBe(0);
    const later = llm.requests[2].messages;
    expect(JSON.stringify(later)).not.toContain(png);
    expect(JSON.stringify(later)).toContain("Cannot read image");
  });

  test("zeta usage totals tokens and cost per project, session and model", async () => {
    sb.writeConfig({ model: "fake/priced", provider: { fake: { options: { baseURL: llm.baseURL }, models: { priced: { name: "Priced", cost: { input: 1000, output: 2000 } } } } } });
    llm.reply({ text: "one" }, { text: "two" });
    expect((await sb.zeta(["run", "first"])).code).toBe(0);
    expect((await sb.zeta(["run", "-c", "second"])).code).toBe(0);
    const [session] = await (await sb.api(`/sessions?location=${encodeURIComponent(sb.project)}`)).json();
    const report = await (await sb.api(`/sessions/${session.id}/usage`)).json();
    expect(report.total.input).toBe(20);
    expect(report.total.messages).toBe(2);
    expect(report.total.cost).toBeCloseTo((20 * 1000 + report.total.output * 2000) / 1e6, 9);
    expect(report.models[0].model).toBe("priced");
    const printed = await sb.zeta(["usage"]);
    expect(printed.code).toBe(0);
    expect(printed.stdout).toContain("1 session, 2 model replies");
    expect(printed.stdout).toContain("fake/priced: input 20");
    expect((await sb.zeta(["usage", "--session", "ses_missing"])).stdout).toContain("session not found");
  });

  test("--continue takes the newest session; zeta sessions finds and exports them", async () => {
    llm.reply({ text: "old reply" }, { text: "new reply" }, { text: "continued" });
    expect((await sb.zeta(["run", "about the parser"])).code).toBe(0);
    await Bun.sleep(5);
    expect((await sb.zeta(["run", "about the lexer"])).code).toBe(0);
    expect((await sb.zeta(["run", "-c", "go on"])).code).toBe(0);
    expect(llm.requests[2].messages[1].content).toBe("about the lexer");
    const listed = (await sb.zeta(["sessions"])).stdout.trim().split("\n");
    expect(listed.length).toBe(2);
    const found = (await sb.zeta(["sessions", "PARSER"])).stdout.trim().split("\n");
    expect(found.length).toBe(1);
    const id = found[0].split(" ")[0];
    expect((await (await sb.api(`/sessions?q=lexer`)).json()).length).toBe(1);
    const exported = (await sb.zeta(["sessions", "export", id])).stdout.trim().split("\n").map((l) => JSON.parse(l));
    expect(exported[0]).toMatchObject({ type: "session", id, location: sb.project });
    expect(exported.slice(1).map((l: { message: { role: string } }) => l.message.role)).toEqual(["user", "assistant"]);
    expect(exported[2].message.content[0].text).toBe("old reply");
    expect((await sb.zeta(["sessions", "export", "ses_nope"])).code).toBe(1);
  });

  test("zeta undo puts back the latest reply's file changes, not the user's", async () => {
    writeFileSync(join(sb.project, "a.txt"), "one");
    llm.reply(
      { calls: [{ id: "w1", name: "write", args: { path: "a.txt", content: "two" } }, { id: "w2", name: "write", args: { path: "new.txt", content: "x" } }] },
      { text: "done" },
    );
    expect((await sb.zeta(["run", "change things"])).code).toBe(0);
    expect(readFileSync(join(sb.project, "a.txt"), "utf8")).toBe("two");
    const undone = await sb.zeta(["undo"]);
    expect(undone.stdout).toBe("Undid 2 of 2 file changes.\n");
    expect(readFileSync(join(sb.project, "a.txt"), "utf8")).toBe("one");
    expect(() => statSync(join(sb.project, "new.txt"))).toThrow();
    const again = await sb.zeta(["undo"]);
    expect(again.code).toBe(1);
    expect(again.stdout).toBe("Nothing to undo.\n");

    // A file the user changed after the reply is left alone.
    llm.reply({ calls: [{ id: "e1", name: "edit", args: { path: "a.txt", edits: [{ oldText: "one", newText: "three" }] } }] }, { text: "edited" });
    expect((await sb.zeta(["run", "-c", "edit it"])).code).toBe(0);
    expect(JSON.stringify(llm.requests[2].messages)).toContain("The user undid the file changes");
    writeFileSync(join(sb.project, "a.txt"), "mine");
    const conflict = await sb.zeta(["undo"]);
    expect(conflict.stdout).toContain("changed since, left as is");
    expect(readFileSync(join(sb.project, "a.txt"), "utf8")).toBe("mine");
  });

  test("--json prints the session's events in loop order", async () => {
    llm.reply({ text: "abc", chunks: 3 });
    const r = await sb.zeta(["run", "--json", "hi"]);
    expect(r.code).toBe(0);
    const events = r.stdout.trim().split("\n").map((l) => JSON.parse(l));
    const kinds = events.map((e) => e.type).filter((t) => t !== "server.heartbeat");
    expect(kinds).toEqual([
      "session.created",
      "session.inbox.updated",
      // The session keeps the model it first ran with.
      "session.updated",
      "agent.start",
      "turn.start",
      "session.inbox.updated",
      "message.start",
      "message.end",
      "message.start",
      "message.part.delta",
      "message.part.delta",
      "message.part.delta",
      "message.end",
      "turn.end",
      "agent.end",
    ]);
    const final = events.findLast((e) => e.type === "message.end");
    expect(final.data.message.content).toEqual([{ type: "text", text: "abc" }]);
    expect(final.data.message.usage.input).toBe(10);
    expect(new Set(events.map((e) => e.session)).size).toBe(1);
  });

  test("a gzip-compressed provider stream is decoded", async () => {
    llm.reply({ text: "compressed reply", gzip: true });
    const r = await sb.zeta(["run", "hi"]);
    expect(r.stderr).toBe("");
    expect(r.code).toBe(0);
    expect(r.stdout).toBe("compressed reply\n");
    expect(llm.headers[0].get("accept-encoding")).toBe("identity");
  });

  test("prompts and replies larger than a stream read buffer", async () => {
    const reply = "r".repeat(100_000);
    llm.reply({ text: reply, chunks: 1 });
    const prompt = "p".repeat(40_000);
    const r = await sb.zeta(["run", prompt]);
    expect(r.stderr).toBe("");
    expect(r.code).toBe(0);
    expect(r.stdout).toBe(`${reply}\n`);
    expect(llm.requests[0].messages[1].content).toBe(prompt);
  });

  test("a provider error fails the run with its message", async () => {
    llm.reply({ status: 401, body: '{"error":{"message":"bad key"}}' });
    const r = await sb.zeta(["run", "hi"]);
    expect(r.code).toBe(1);
    expect(r.stderr).toContain("HTTP 401");
    expect(r.stderr).toContain("bad key");
  });

  test("a dropped event stream reconnects to a restarted server and reports the interrupted run", async () => {
    let release!: () => void;
    const paused = new Promise<void>((resolve) => { release = resolve; });
    llm.reply({ text: "Hello world", chunks: 2, afterFirstChunk: paused });
    const running = sb.zeta(["run", "hi"]);
    let restarted: ReturnType<typeof Bun.spawn> | undefined;
    try {
      while (llm.requests.length === 0) await Bun.sleep(10);
      await Bun.sleep(100);
      expect((await sb.zeta(["server", "stop"])).code).toBe(0);
      restarted = Bun.spawn([zetaBin, "serve"], { cwd: sb.project, env: sb.env, stdout: "ignore", stderr: "ignore" });
      const r = await running;
      expect(r.code).toBe(1);
      expect(r.stdout).toBe("Hello \n");
      expect(r.stderr).toMatch(/^error: /);
      expect(r.stderr).not.toContain("lost the connection");
    } finally {
      release();
      restarted?.kill();
    }
  });

  test("an error body is reduced to its message, with the key redacted, before it is logged", async () => {
    llm.reply({ status: 401, body: '{"error":{"message":"Incorrect API key provided: sk-echoed-secret-key","type":"invalid_request_error","internal":"stack trace"}}' });
    const r = await sb.zeta(["run", "hi"], { FAKE_KEY: "sk-echoed-secret-key" });
    expect(r.code).toBe(1);
    expect(r.stderr).toContain("Incorrect API key provided: [redacted]");
    const logged = JSON.stringify(sb.sessionMessages());
    expect(logged).not.toContain("sk-echoed-secret-key");
    expect(logged).not.toContain("stack trace");
    expect(llm.requests).toHaveLength(1);
  });

  test("a retryable provider failure is retried before any output", async () => {
    llm.reply({ status: 503, body: '{"error":{"message":"overloaded"}}' }, { text: "recovered" });
    const r = await sb.zeta(["run", "--json", "hi"]);
    expect(r.code).toBe(0);
    const events = r.stdout.trim().split("\n").map((l) => JSON.parse(l));
    const retry = events.find((e) => e.type === "message.retry");
    expect(retry.data).toMatchObject({ attempt: 1, maxAttempts: 3, delayMs: 1000, errorMessage: "HTTP 503: overloaded" });
    expect(events.findLast((e) => e.type === "message.end").data.message.content).toEqual([{ type: "text", text: "recovered" }]);
    expect(llm.requests).toHaveLength(2);
  });

  test("a missing model is reported", async () => {
    sb.writeConfig({});
    const r = await sb.zeta(["run", "hi"]);
    expect(r.code).toBe(1);
    expect(r.stderr).toContain("NoModelConfigured");
    expect(llm.requests.length).toBe(0);
  });
});

describe("server", () => {
  test("typed JSON bodies reject unknown properties", async () => {
    llm.reply({ text: "x" });
    await sb.zeta(["run", "start it"]);
    const extra = await sb.api("/sessions", "POST", { location: sb.project, unexpected: true });
    expect(extra.status).toBe(400);
    expect(await extra.json()).toEqual({ error: "UnknownField" });
    const nested = await sb.api("/sessions", "POST", { location: sb.project, environment: { profile: null, extra: true } });
    expect(nested.status).toBe(400);
    expect(await nested.json()).toEqual({ error: "UnknownField" });
  });

  test("requires basic auth", async () => {
    llm.reply({ text: "x" });
    await sb.zeta(["run", "start it"]);
    const { url, password } = sb.discovery();

    expect((await fetch(`${url}/health`)).status).toBe(401);
    const wrong = await fetch(`${url}/health`, { headers: { authorization: "Basic " + btoa("zeta:nope") } });
    expect(wrong.status).toBe(401);
    const ok = await fetch(`${url}/health`, { headers: { authorization: "Basic " + btoa(`zeta:${password}`) } });
    expect(ok.status).toBe(200);
    expect((await ok.json()).pid).toBe(sb.discovery().pid);
  });

  test("body requests without framing or over the limit close the connection, not the server", async () => {
    llm.reply({ text: "x" });
    await sb.zeta(["run", "start it"]);
    const { url, password } = sb.discovery();
    const port = Number(new URL(url).port);
    const auth = `authorization: Basic ${btoa(`zeta:${password}`)}\r\n`;
    // Raw requests: fetch always frames a POST body. node:net buffers the
    // whole write, so the oversized body is actually delivered.
    const raw = (request: string) => new Promise<string>((resolve, reject) => {
      let out = "";
      const socket = connect({ host: "127.0.0.1", port }, () => socket.write(request));
      socket.on("data", (chunk) => { out += chunk.toString(); });
      socket.on("close", () => resolve(out));
      socket.on("error", (err: NodeJS.ErrnoException) => err.code === "ECONNRESET" || err.code === "EPIPE" ? resolve(out) : reject(err));
    });
    const unframed = await raw(`POST /sessions HTTP/1.1\r\nhost: x\r\n${auth}\r\n`);
    expect(unframed).toMatch(/^HTTP\/1\.1 \d{3}/);
    expect(unframed.toLowerCase()).toContain("connection: close");
    const size = 8 * 1024 * 1024 + 1;
    const tooLarge = await raw(`POST /sessions HTTP/1.1\r\nhost: x\r\n${auth}content-type: application/json\r\ncontent-length: ${size}\r\n\r\n${"x".repeat(size)}`);
    expect(tooLarge).toMatch(/^HTTP\/1\.1 413/);
    expect(tooLarge.toLowerCase()).toContain("connection: close");
    expect((await sb.api("/health")).status).toBe(200);
  });

  test("connections are capped and silent ones are closed by the header deadline", async () => {
    llm.reply({ text: "x" });
    await sb.zeta(["run", "start it"]);
    const port = Number(new URL(sb.discovery().url).port);
    // Silent sockets never send a request; each holds a slot until its deadline.
    const open = (): Promise<{ closed: Promise<string> }> => new Promise((resolve, reject) => {
      let out = "";
      const socket = connect({ host: "127.0.0.1", port }, () => resolve({ closed }));
      const closed = new Promise<string>((done) => socket.on("close", () => done(out)));
      socket.on("data", (chunk) => { out += chunk.toString(); });
      socket.on("error", (err: NodeJS.ErrnoException) => err.code === "ECONNRESET" || err.code === "EPIPE" ? undefined : reject(err));
    });
    const silent = [];
    let refused = "";
    for (let i = 0; i < 70 && !refused; i++) {
      const socket = await open();
      const early = await Promise.race([socket.closed, Bun.sleep(20).then(() => null)]);
      if (early !== null) refused = early;
      else silent.push(socket);
    }
    expect(refused).toMatch(/^HTTP\/1\.1 503/);
    expect(silent.length).toBeLessThanOrEqual(64);
    const started = Date.now();
    await Promise.all(silent.map((s) => s.closed));
    expect(Date.now() - started).toBeLessThan(12_000);
    expect((await sb.api("/health")).status).toBe(200);
  }, 20_000);

  test("a second serve refuses to replace a live server", async () => {
    llm.reply({ text: "x" });
    await sb.zeta(["run", "start it"]);
    const original = readFileSync(sb.discoveryPath, "utf8");
    const { pid } = sb.discovery();
    const r = await sb.zeta(["serve"]);
    expect(r.code).toBe(1);
    expect(r.stderr).toContain("already running");
    expect(readFileSync(sb.discoveryPath, "utf8")).toBe(original);
    const { url, password } = sb.discovery();
    const health = await fetch(`${url}/health`, { headers: { authorization: `Basic ${btoa(`zeta:${password}`)}` } });
    expect(health.status).toBe(200);
    expect((await health.json()).pid).toBe(pid);
  });

  test("a started server resets its log, and a losing start only appends to it", async () => {
    const logPath = join(sb.env.XDG_STATE_HOME, "zeta", "server.log");
    mkdirSync(dirname(logPath), { recursive: true });
    writeFileSync(logPath, "stale line from an earlier server\n");
    llm.reply({ text: "x" });
    await sb.zeta(["run", "start it"]);
    const started = readFileSync(logPath, "utf8");
    expect(started).not.toContain("stale line");
    expect(started).toContain("listening");

    const fd = openSync(logPath, "a");
    const loser = Bun.spawn([zetaBin, "serve"], { cwd: sb.project, env: sb.env, stdout: fd, stderr: fd });
    expect(await loser.exited).toBe(1);
    closeSync(fd);
    const after = readFileSync(logPath, "utf8");
    expect(after.startsWith(started)).toBe(true);
    expect(after).toContain("already running");
  });
});
