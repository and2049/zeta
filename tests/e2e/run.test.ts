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

describe("server", () => {
  test("unused sessions are hidden until their first prompt", async () => {
    await sb.start();
    llm.reply({ text: "ready" });
    const created = await (await sb.api("/sessions", "POST", { location: sb.project })).json();
    expect((await sb.api(`/sessions/${created.id}`)).status).toBe(200);
    const listed = async () => (await (await sb.api("/sessions")).json()) as { id: string }[];
    expect((await listed()).some((s) => s.id === created.id)).toBe(false);
    expect((await (await sb.api(`/sessions?q=${created.id}`)).json()).length).toBe(0);
    expect((await sb.api(`/sessions/${created.id}/prompt`, "POST", { text: "hello" })).status).toBe(200);
    for (let i = 0; i < 50 && !(await listed()).some((s) => s.id === created.id); i++) await Bun.sleep(20);
    expect((await listed()).some((s) => s.id === created.id)).toBe(true);
  });


  test("typed JSON bodies reject unknown properties", async () => {
    await sb.start();
    const extra = await sb.api("/sessions", "POST", { location: sb.project, unexpected: true });
    expect(extra.status).toBe(400);
    expect(await extra.json()).toEqual({ error: "UnknownField" });
    const nested = await sb.api("/sessions", "POST", { location: sb.project, environment: { profile: null, extra: true } });
    expect(nested.status).toBe(400);
    expect(await nested.json()).toEqual({ error: "UnknownField" });
  });

  test("requires basic auth", async () => {
    await sb.start();
    const { url, password } = sb.discovery();

    expect((await fetch(`${url}/health`)).status).toBe(401);
    const wrong = await fetch(`${url}/health`, { headers: { authorization: "Basic " + btoa("zeta:nope") } });
    expect(wrong.status).toBe(401);
    const ok = await fetch(`${url}/health`, { headers: { authorization: "Basic " + btoa(`zeta:${password}`) } });
    expect(ok.status).toBe(200);
    expect((await ok.json()).pid).toBe(sb.discovery().pid);
  });

  test("body requests without framing or over the limit close the connection, not the server", async () => {
    await sb.start();
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
    await sb.start();
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
    await sb.start();
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

  test("serve --hostname listens on another address", async () => {
    await sb.start("0.0.0.0");
    const { url, password } = sb.discovery();
    expect(url.startsWith("http://127.0.0.1:")).toBe(true);
    const port = new URL(url).port;
    const health = await fetch(`http://0.0.0.0:${port}/health`, { headers: { authorization: `Basic ${btoa(`zeta:${password}`)}` } });
    expect(health.status).toBe(200);
    expect((await fetch(`http://0.0.0.0:${port}/health`)).status).toBe(401);
  });

  test("a started server resets its log, and a losing start only appends to it", async () => {
    const logPath = join(sb.env.XDG_STATE_HOME, "zeta", "server.log");
    mkdirSync(dirname(logPath), { recursive: true });
    writeFileSync(logPath, "stale line from an earlier server\n");
    const fd = openSync(logPath, "a");
    const server = Bun.spawn([zetaBin, "serve"], { cwd: sb.project, env: sb.env, stdout: fd, stderr: fd });
    await import("./wait-for").then(({ waitFor }) => waitFor(() => readFileSync(logPath, "utf8").includes("listening"), "server log"));
    const started = readFileSync(logPath, "utf8");
    expect(started).not.toContain("stale line");
    expect(started).toContain("listening");

    const loser = Bun.spawn([zetaBin, "serve"], { cwd: sb.project, env: sb.env, stdout: fd, stderr: fd });
    expect(await loser.exited).toBe(1);
    const after = readFileSync(logPath, "utf8");
    expect(after.startsWith(started)).toBe(true);
    expect(after).toContain("already running");
    await sb.api("/server/stop", "POST", {});
    await server.exited;
    closeSync(fd);
  });
});
