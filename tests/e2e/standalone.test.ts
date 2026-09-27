import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { FakeOpenAI } from "./fake-openai";
import { Sandbox, zetaBin } from "./harness";

let sb: Sandbox;
let llm: FakeOpenAI;

beforeEach(() => {
  sb = new Sandbox();
  llm = new FakeOpenAI();
  sb.writeConfig({ model: "fake/test-model", provider: { fake: { options: { baseURL: llm.baseURL } } } });
});

afterEach(async () => {
  await sb.cleanup();
  llm.stop();
});

describe("standalone and hostname", () => {
  test("zeta run --standalone uses a private server that ends with it", async () => {
    llm.reply({ text: "private reply" });
    const r = await sb.zeta(["run", "--standalone", "hello"]);
    expect(r.code).toBe(0);
    expect(r.stdout).toBe("private reply\n");
    // The shared server was never started, and the private one is gone.
    expect(existsSync(sb.discoveryPath)).toBe(false);
    const runtime = join(sb.env.XDG_RUNTIME_DIR, "zeta");
    expect(existsSync(runtime) ? readdirSync(runtime).filter((f) => f.startsWith("standalone-")) : []).toEqual([]);
    // Its session is saved like any other.
    expect(sb.sessionMessages().some((m) => JSON.stringify(m).includes("private reply"))).toBe(true);
  });

  test("zeta serve --hostname listens on another address", async () => {
    const proc = Bun.spawn([zetaBin, "serve", "--hostname", "0.0.0.0"], { cwd: sb.project, env: sb.env, stdout: "ignore", stderr: "pipe" });
    for (let i = 0; i < 200 && !existsSync(sb.discoveryPath); i++) await Bun.sleep(20);
    const { url, password } = sb.discovery();
    expect(url.startsWith("http://127.0.0.1:")).toBe(true);
    const port = new URL(url).port;
    // Reached through a non-loopback interface name too.
    const health = await fetch(`http://0.0.0.0:${port}/health`, { headers: { authorization: `Basic ${btoa(`zeta:${password}`)}` } });
    expect(health.status).toBe(200);
    expect((await fetch(`http://0.0.0.0:${port}/health`)).status).toBe(401);
    await sb.zeta(["server", "stop"]);
    await proc.exited;
    expect(await new Response(proc.stderr).text()).toContain("other machines can connect");
  });

  test("a standalone server keeps its sessions from the shared one and cleans up when its client dies", async () => {
    const client = Bun.spawn(["sleep", "30"]);
    const dir = join(sb.env.XDG_RUNTIME_DIR, "zeta", `standalone-${client.pid}`);
    const privateServer = Bun.spawn([zetaBin, "serve", "--runtime-dir", dir, "--parent", String(client.pid)], { cwd: sb.project, env: sb.env, stdout: "ignore", stderr: "ignore" });
    const discovery = join(dir, "server.json");
    for (let i = 0; i < 200 && !existsSync(discovery); i++) await Bun.sleep(20);
    const { url, password } = JSON.parse(await Bun.file(discovery).text());
    const auth = { authorization: `Basic ${btoa(`zeta:${password}`)}`, "content-type": "application/json" };
    const created = await (await fetch(`${url}/sessions`, { method: "POST", headers: auth, body: JSON.stringify({ location: sb.project }) })).json();

    // The shared server starts meanwhile and leaves that session alone.
    llm.reply({ text: "shared" });
    expect((await sb.zeta(["run", "hi"])).code).toBe(0);
    const listed = await (await sb.api("/sessions")).json();
    expect(listed.some((s: { id: string }) => s.id === created.id)).toBe(false);

    client.kill();
    await privateServer.exited;
    expect(existsSync(dir)).toBe(false);
  });

  test("a server watching its client removes only its own standalone directory", async () => {
    const gone = Bun.spawn(["true"]);
    await gone.exited;
    const other = join(sb.project, "not-a-runtime");
    mkdirSync(other);
    writeFileSync(join(other, "keep.txt"), "mine");
    const r = await sb.zeta(["serve", "--runtime-dir", other, "--parent", String(gone.pid)]);
    expect(r.code).toBe(0);
    expect(existsSync(join(other, "keep.txt"))).toBe(true);
    const own = join(sb.env.XDG_RUNTIME_DIR, "zeta", `standalone-${gone.pid}`);
    mkdirSync(own, { recursive: true });
    expect((await sb.zeta(["serve", "--runtime-dir", own, "--parent", String(gone.pid)])).code).toBe(0);
    expect(existsSync(own)).toBe(false);
  });

  test("an IPv6 --hostname and unknown serve flags are refused", async () => {
    const r = await sb.zeta(["serve", "--hostname", "::1"]);
    expect(r.code).toBe(2);
    expect(r.stderr).toContain("--hostname takes an IPv4 address");
    const bogus = await sb.zeta(["serve", "--bogus", "x"]);
    expect(bogus.code).toBe(2);
    expect(bogus.stderr).toContain("usage: zeta serve");
  });
});
