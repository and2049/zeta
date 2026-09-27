import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { FakeOpenAI } from "./fake-openai";
import { Sandbox, zetaBin, type AgentEvent } from "./harness";

let sb: Sandbox;
let llm: FakeOpenAI;

beforeEach(() => {
  sb = new Sandbox();
  llm = new FakeOpenAI();
  sb.writeConfig({ model: "fake/base", provider: { fake: { options: { baseURL: llm.baseURL } } } });
});
afterEach(async () => {
  await sb.cleanup();
  llm.stop();
});

async function json(path: string, method = "GET", body?: unknown): Promise<any> {
  const response = await sb.api(path, method, body);
  expect(response.status).toBe(200);
  return response.json();
}
async function create(options: object = {}): Promise<string> {
  return (await json("/sessions", "POST", { location: sb.project, ...options })).id;
}
async function prompt(id: string, text: string) {
  const receipt = await json(`/sessions/${id}/prompt`, "POST", { text });
  expect(receipt.inboxId).toMatch(/^msg_/);
  return receipt.inboxId as string;
}
async function snapshot(id: string): Promise<any> { return json(`/sessions/${id}`); }
async function eventually<T>(read: () => Promise<T>, ready: (value: T) => boolean): Promise<T> {
  for (let i = 0; i < 150; i++) {
    const value = await read();
    if (ready(value)) return value;
    await Bun.sleep(20);
  }
  throw new Error("timed out waiting for daemon state");
}
async function boot() {
  await sb.start();
  llm.reply({ text: "warm" });
  const id = await create();
  await prompt(id, "warm");
  await eventually(() => snapshot(id), (s) => !s.running && s.messages.length >= 2);
}

/** A subscription established before the snapshot; queued frames are retained across HTTP reads. */
class Feed {
  private reader: ReadableStreamDefaultReader<Uint8Array>;
  private decoder = new TextDecoder();
  private bytes = "";
  private events: AgentEvent[] = [];

  private constructor(reader: ReadableStreamDefaultReader<Uint8Array>) { this.reader = reader; }

  static async subscribe(): Promise<Feed> {
    const response = await sb.api("/event");
    expect(response.status).toBe(200);
    const feed = new Feed(response.body!.getReader());
    expect((await feed.next()).type).toBe("server.connected");
    return feed;
  }

  async next(): Promise<AgentEvent> {
    while (!this.events.length) {
      const { done, value } = await this.reader.read();
      if (done) throw new Error("SSE feed closed unexpectedly");
      this.bytes += this.decoder.decode(value, { stream: true });
      let end: number;
      while ((end = this.bytes.indexOf("\n\n")) !== -1) {
        const frame = this.bytes.slice(0, end);
        this.bytes = this.bytes.slice(end + 2);
        const data = frame.split("\n").filter((line) => line.startsWith("data: ")).map((line) => line.slice(6)).join("\n");
        if (data) this.events.push(JSON.parse(data));
      }
    }
    return this.events.shift()!;
  }

  async until(type: string, session: string): Promise<AgentEvent> {
    for (;;) {
      const event = await this.next();
      if (event.type === type && event.session === session) return event;
    }
  }

  async close() { await this.reader.cancel(); }
}

describe("durable sessions and history", () => {
  test("SSE reconnect snapshot contains the streamed prefix and later deltas reconstruct one reply", async () => {
    await boot();
    const feed = await Feed.subscribe(); // subscribe before fetching state, as a reconnecting client does
    const id = await create();
    const full = "prefix-and-suffix-reconnected";
    let resume!: () => void;
    const pause = new Promise<void>((resolve) => { resume = resolve; });
    llm.reply({ text: full, chunks: 3, afterFirstChunk: pause });
    try {
      await prompt(id, "stream a reply");
      const first = await feed.until("message.part.delta", id);
      const delta = (first.data as any).delta as string;
      expect(delta.length).toBeGreaterThan(0);
      const state = await snapshot(id);
      expect(state.running).toBe(true);
      expect(state.revision).toBeGreaterThanOrEqual(first.seq);
      expect(state.messages.some((m: any) => m.id === (first.data as any).messageId)).toBe(false);
      expect(state.inflight?.id).toBe((first.data as any).messageId);
      expect(state.inflight?.content?.[0]?.text).toBe(delta);
      // Discard pre-snapshot frames, then apply only later events. The first
      // chunk must already be in the state; otherwise reconnect loses text.
      resume();
      let reconstructed = state.inflight.content[0].text as string;
      let completed: any;
      for (;;) {
        const event = await feed.next();
        if (event.session !== id || event.seq <= state.revision) continue;
        if (event.type === "message.part.delta" && (event.data as any).messageId === state.inflight.id) {
          reconstructed += (event.data as any).delta;
        }
        if (event.type === "message.end" && event.data.message?.id === state.inflight.id) {
          completed = event.data.message;
          break;
        }
      }
      expect(reconstructed).toBe(full);
      expect(completed.content[0].text).toBe(full);
    } finally {
      resume();
      await feed.close();
    }
  });

  test("restart restores history, selectors, and list without continuing the old turn", async () => {
    mkdirSync(join(sb.project, ".zeta", "profiles"), { recursive: true });
    writeFileSync(join(sb.project, ".zeta", "profiles", "review.jsonc"), JSON.stringify({ model: "fake/profile" }));
    await boot();
    const id = await create({ profile: "review", model: "fake/selected" });
    llm.reply({ text: "before restart" });
    await prompt(id, "first");
    await eventually(() => snapshot(id), (s) => !s.running && s.messages.some((m: any) => m.content?.[0]?.text === "before restart"));
    expect((await json("/sessions")).some((s: any) => s.id === id)).toBe(true);
    const other = await create();
    expect((await json(`/sessions?location=${encodeURIComponent(sb.project)}`)).map((s: any) => s.id)).toContain(id);
    expect((await json(`/sessions?location=${encodeURIComponent(sb.root)}`)).map((s: any) => s.id)).not.toContain(id);
    expect(other).not.toBe(id);

    await sb.stop();
    expect(existsSync(sb.discoveryPath)).toBe(false);
    // Starting the daemon again must not send an old prompt to the provider.
    const server = Bun.spawn([zetaBin, "serve"], { cwd: sb.project, env: sb.env, stdout: "pipe", stderr: "pipe" });
    try {
      await eventually(async () => existsSync(sb.discoveryPath), Boolean);
      expect(llm.requests).toHaveLength(2); // warmup and original turn only
      const restored = await snapshot(id);
      expect(restored.running).toBe(false);
      expect(restored.options).toMatchObject({ profile: "review", model: "fake/selected" });
      expect(restored.messages.map((m: any) => m.role)).toEqual(["user", "assistant"]);
      llm.reply({ text: "after restart" });
      await prompt(id, "second");
      await eventually(() => snapshot(id), (s) => !s.running && s.messages.at(-1)?.content?.[0]?.text === "after restart");
      expect(llm.requests.at(-1).model).toBe("selected");
      expect(llm.requests.at(-1).messages.filter((m: any) => m.role === "user").map((m: any) => m.content)).toEqual(["first", "second"]);
    } finally {
      if (existsSync(sb.discoveryPath)) await sb.api("/server/stop", "POST", {});
      await server.exited;
    }
  });

  test("restart skips a corrupt complete log without deleting it or hiding healthy sessions", async () => {
    await boot();
    const healthy = await create();
    const corrupt = await create();
    llm.reply({ text: "healthy" }, { text: "corrupt" });
    await prompt(healthy, "keep");
    await prompt(corrupt, "break");
    await eventually(() => snapshot(corrupt), (s) => !s.running && s.messages.length >= 2);
    const sessionsDir = join(sb.env.XDG_DATA_HOME, "zeta", "sessions");
    const locationDir = join(sessionsDir, readdirSync(sessionsDir)[0]);
    const path = join(locationDir, `${corrupt}.jsonl`);
    expect(readFileSync(path, "utf8")).toContain(`"id":"${corrupt}"`);
    await sb.stop();
    const broken = readFileSync(path, "utf8") + '{"type":"message","message":{}}\n';
    writeFileSync(path, broken);
    const server = Bun.spawn([zetaBin, "serve"], { cwd: sb.project, env: sb.env, stdout: "pipe", stderr: "pipe" });
    try {
      await eventually(async () => existsSync(sb.discoveryPath), Boolean);
      expect((await json("/sessions")).map((s: any) => s.id)).toContain(healthy);
      expect((await json("/sessions")).map((s: any) => s.id)).not.toContain(corrupt);
      expect((await sb.api(`/sessions/${corrupt}`)).status).toBe(404);
      expect(readFileSync(path, "utf8")).toBe(broken);
    } finally {
      if (existsSync(sb.discoveryPath)) await sb.api("/server/stop", "POST", {});
      await server.exited;
    }
  });

  test("messages page backwards exclusively, caps limit, and rejects invalid cursors", async () => {
    await boot();
    const id = await create();
    for (let i = 0; i < 3; i++) {
      llm.reply({ text: `reply-${i}` });
      await prompt(id, `prompt-${i}`);
      await eventually(() => snapshot(id), (s) => !s.running && s.messages.at(-1)?.content?.[0]?.text === `reply-${i}`);
    }
    const latest = await json(`/sessions/${id}/messages?limit=2`);
    expect(latest.messages.map((m: any) => m.content[0].text)).toEqual(["prompt-2", "reply-2"]);
    expect(latest.nextBefore).toBe(latest.messages[0].id);
    const prior = await json(`/sessions/${id}/messages?limit=2&before=${latest.nextBefore}`);
    expect(prior.messages.map((m: any) => m.content[0].text)).toEqual(["prompt-1", "reply-1"]);
    expect(prior.messages.some((m: any) => m.id === latest.messages[0].id)).toBe(false);
    expect((await json(`/sessions/${id}/messages`)).messages).toHaveLength(6);
    expect((await sb.api(`/sessions/${id}/messages?limit=201`)).status).toBe(400);
    expect((await sb.api(`/sessions/${id}/messages?before=msg_nonexistent`)).status).toBe(400);
  });

  test("abort clears a queued prompt without affecting another session; delete removes history", async () => {
    await boot();
    const a = await create();
    const b = await create();
    llm.reply({ text: "late", delayMs: 1000 });
    await prompt(a, "blocked");
    await eventually(() => Promise.resolve(llm.requests.length), (n) => n >= 2);
    await prompt(a, "must not run");
    expect((await snapshot(a)).inbox.map((item: any) => item.text)).toContain("must not run");
    await json(`/sessions/${a}/abort`, "POST", {});
    const stopped = await snapshot(a);
    expect(stopped.running).toBe(false);
    expect(stopped.inbox).toEqual([]);
    llm.reply({ text: "other session" });
    await prompt(b, "independent");
    await eventually(() => snapshot(b), (s) => !s.running && s.messages.some((m: any) => m.role === "assistant"));
    expect((await snapshot(b)).messages.at(-1).content[0].text).toBe("other session");
    expect(llm.requests.some((r) => r.messages.some((m: any) => m.content === "must not run"))).toBe(false);
    expect((await sb.api(`/sessions/${a}`, "DELETE")).status).toBe(200);
    expect((await sb.api(`/sessions/${a}`)).status).toBe(404);
    expect((await sb.api(`/sessions/${a}`, "DELETE")).status).toBe(404);
  });

});

describe("administration", () => {
  test("credential metadata and config never expose keys; explicit config wins over stored key", async () => {
    await boot();
    const key = "stored-phase3-secret";
    expect((await json("/credentials/fake", "PUT", { type: "api", key })).type).toBe("api");
    const listing = await json("/credentials");
    expect(listing).toEqual({ providers: [{ id: "fake", type: "api" }] });
    expect(JSON.stringify(listing)).not.toContain(key);
    llm.reply({ text: "stored" });
    const stored = await create();
    await prompt(stored, "stored key");
    await eventually(() => snapshot(stored), (s) => !s.running && s.messages.length >= 2);
    expect(llm.headers.at(-1)?.get("authorization")).toBe(`Bearer ${key}`);
    const config = await json(`/config?location=${encodeURIComponent(sb.project)}`);
    expect(config).toHaveProperty("config");
    expect(config).toHaveProperty("provenance");
    expect(JSON.stringify(config)).not.toContain(key);
    await json("/config", "PATCH", { target: "user", patch: { provider: { fake: { options: { apiKey: "explicit-phase3-secret" } } } } });
    llm.reply({ text: "explicit" });
    const explicit = await create();
    await prompt(explicit, "explicit key");
    await eventually(() => snapshot(explicit), (s) => !s.running && s.messages.length >= 2);
    expect(llm.headers.at(-1)?.get("authorization")).toBe("Bearer explicit-phase3-secret");
    const redacted = await json(`/config?location=${encodeURIComponent(sb.project)}`);
    expect(redacted.config.provider.fake.options.apiKey).toBe("[REDACTED]");
    expect(JSON.stringify(redacted)).not.toContain("explicit-phase3-secret");
  });

  test("PATCH persists recursive project edits, deletes only that layer, and active turns retain their config", async () => {
    await boot();
    const id = await create();
    const location = sb.project;
    await json("/config", "PATCH", { target: "project", location, patch: { model: "fake/project", provider: { fake: { options: { baseURL: llm.baseURL } } } } });
    expect((await json(`/config?location=${encodeURIComponent(location)}`)).config.model).toBe("fake/project");
    llm.reply({ text: "old config turn", delayMs: 300 });
    await prompt(id, "first");
    await eventually(() => Promise.resolve(llm.requests.length), (count) => count === 2);
    await json("/config", "PATCH", { target: "project", location, patch: { model: "fake/changed" } });
    await eventually(() => snapshot(id), (s) => !s.running && s.messages.at(-1)?.role === "assistant");
    expect(llm.requests.at(-1).model).toBe("project");
    // The session keeps the model it ran with; a new one takes the new config.
    llm.reply({ text: "same model turn" });
    await prompt(id, "second");
    await eventually(() => snapshot(id), (s) => !s.running && s.messages.at(-1)?.content?.[0]?.text === "same model turn");
    expect(llm.requests.at(-1).model).toBe("project");
    const next = await create();
    llm.reply({ text: "new config turn" });
    await prompt(next, "third");
    await eventually(() => snapshot(next), (s) => !s.running && s.messages.at(-1)?.content?.[0]?.text === "new config turn");
    expect(llm.requests.at(-1).model).toBe("changed");
    await json("/config", "PATCH", { target: "project", location, patch: { model: null } });
    expect((await json(`/config?location=${encodeURIComponent(location)}`)).config.model).toBe("fake/base");
    expect(JSON.parse(readFileSync(join(location, ".zeta", "zeta.jsonc"), "utf8")).provider.fake.options.baseURL).toBe(llm.baseURL);
    expect((await sb.api("/models")).status).toBe(400);
    expect((await sb.api("/registry")).status).toBe(400);
    const registry = await json(`/registry?session=${id}`);
    expect(registry.tools).toEqual([]);
    expect(registry.plugins).toContainEqual({ id: "openai", layer: "builtin", source: "builtin" });
    expect(registry.providers.map((p: any) => p.id)).toEqual(["openai", "anthropic", "deepseek", "zai", "zhipuai", "openrouter", "*"]);
    expect(registry.prompt_sections.slice(0, 2)).toEqual(["base", "environment"]);
    expect(registry.hooks).toEqual([]);
    expect((await json(`/models?location=${encodeURIComponent(location)}`)).providers).toBeDefined();
    await json("/config", "PATCH", { target: "project", location, patch: { plugin: { ghost: { on: true } } } });
    const shown = await json(`/config?location=${encodeURIComponent(location)}`);
    expect(shown.config.plugin.ghost).toEqual({ on: true });
    expect(shown.diagnostics).toContainEqual('config for unknown plugin "ghost" is ignored');
    expect((await sb.api("/config", "PATCH", { target: "project", location, patch: { theme: "dark" } })).status).toBe(400);
  });

  test("HTTP reload reports no failures when nothing is loaded from disk", async () => {
    await boot();
    expect(await json("/registry/reload", "POST", { location: sb.project })).toEqual({ failures: [] });
    expect(await json("/registry/reload", "POST", {})).toEqual({ failures: [] });
    expect((await sb.api("/registry/reload")).status).toBe(405);
  });

});
