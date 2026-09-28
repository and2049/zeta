import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { FakeOpenAI } from "./fake-openai";
import { Sandbox, type AgentEvent } from "./harness";

type PermissionEvent = AgentEvent & { data: AgentEvent["data"] & { id: string; action: string; pattern: string; timeoutMs: number } };

class Feed {
  private reader: ReadableStreamDefaultReader<Uint8Array>;
  private decoder = new TextDecoder();
  private buffer = "";
  private queued: AgentEvent[] = [];

  private constructor(reader: ReadableStreamDefaultReader<Uint8Array>) { this.reader = reader; }

  static async open(sb: Sandbox): Promise<Feed> {
    const { url, password } = sb.discovery();
    const response = await fetch(`${url}/event`, {
      headers: { authorization: `Basic ${btoa(`zeta:${password}`)}` },
      signal: AbortSignal.timeout(10_000),
    });
    expect(response.status).toBe(200);
    const feed = new Feed(response.body!.getReader());
    expect((await feed.next()).type).toBe("server.connected");
    return feed;
  }

  async next(): Promise<AgentEvent> {
    while (!this.queued.length) {
      const { value, done } = await this.reader.read();
      if (done) throw new Error("SSE stream closed before expected event");
      this.buffer += this.decoder.decode(value, { stream: true });
      let boundary: number;
      while ((boundary = this.buffer.indexOf("\n\n")) !== -1) {
        const frame = this.buffer.slice(0, boundary);
        this.buffer = this.buffer.slice(boundary + 2);
        const data = frame.split("\n").filter((line) => line.startsWith("data: ")).map((line) => line.slice(6)).join("\n");
        if (data) this.queued.push(JSON.parse(data) as AgentEvent);
      }
    }
    return this.queued.shift()!;
  }

  async until(type: string, session: string): Promise<AgentEvent> {
    while (true) {
      const event = await this.next();
      if (event.type === type && event.session === session) return event;
    }
  }

  async close() { await this.reader.cancel(); }
}

let sb: Sandbox;
let llm: FakeOpenAI;
let feed: Feed | undefined;

async function post(path: string, body: object): Promise<Response> {
  const { url, password } = sb.discovery();
  return fetch(`${url}${path}`, {
    method: "POST",
    headers: { authorization: `Basic ${btoa(`zeta:${password}`)}`, "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

async function newSession(): Promise<string> {
  const response = await post("/sessions", { location: sb.project });
  expect(response.status).toBe(200);
  return ((await response.json()) as { id: string }).id;
}

async function prompt(session: string) {
  const response = await post(`/sessions/${session}/prompt`, { text: "write a file" });
  expect(response.status).toBe(200);
}

async function answer(id: string, reply: "allow_once" | "allow_session" | "deny") {
  return post(`/permissions/${id}/reply`, { reply });
}

async function bootstrap(timeout_ms = 500) {
  sb.writeConfig({
    model: "fake/test-model",
    provider: { fake: { options: { baseURL: llm.baseURL } } },
    tool_timeout_ms: timeout_ms,
    permission: [{ action: "write", pattern: "*", effect: "ask" }],
  });
  llm.reply({ text: "ready" });
  expect((await sb.zeta(["run", "start server"])).code).toBe(0);
  feed = await Feed.open(sb);
}

beforeEach(() => {
  sb = new Sandbox();
  llm = new FakeOpenAI();
});
afterEach(async () => {
  await feed?.close();
  feed = undefined;
  await sb.cleanup();
  llm.stop();
});

describe("permission replies over the API and SSE", () => {
  test("allow_once approves one call and asks again for the next call", async () => {
    await bootstrap(5_000);
    const session = await newSession();
    llm.reply(
      { calls: [{ id: "once-1", name: "write", args: { path: "once.txt", content: "first" } }] },
      { calls: [{ id: "once-2", name: "write", args: { path: "once.txt", content: "second" } }] },
      { text: "done" },
    );
    await prompt(session);
    const first = await feed!.until("permission.asked", session) as PermissionEvent;
    expect(first.data.action).toBe("write");
    expect(first.data.pattern).toContain("once.txt");
    expect((await answer(first.data.id, "allow_once")).status).toBe(200);
    expect((await answer(first.data.id, "allow_once")).status).toBe(404);
    const second = await feed!.until("permission.asked", session) as PermissionEvent;
    expect(second.data.id).not.toBe(first.data.id);
    expect((await answer(second.data.id, "allow_once")).status).toBe(200);
    await feed!.until("agent.end", session);
    expect(existsSync(join(sb.project, "once.txt"))).toBe(true);
    expect(llm.requests.at(-1).messages.filter((message: { role: string }) => message.role === "tool")).toHaveLength(2);
  });

  test("allow_session remembers a matching action/path for the same session", async () => {
    await bootstrap(5_000);
    const session = await newSession();
    llm.reply(
      { calls: [{ id: "session-1", name: "write", args: { path: "session.txt", content: "one" } }] },
      { calls: [{ id: "session-2", name: "write", args: { path: "session.txt", content: "two" } }] },
      { text: "done" },
    );
    await prompt(session);
    const asked = await feed!.until("permission.asked", session) as PermissionEvent;
    expect((await answer(asked.data.id, "allow_session")).status).toBe(200);
    const observed: string[] = [];
    while (true) {
      const event = await feed!.next();
      if (event.session !== session) continue;
      observed.push(event.type);
      if (event.type === "agent.end") break;
    }
    expect(observed).not.toContain("permission.asked");
    expect(observed.filter((type) => type === "tool.execution.end")).toHaveLength(2);
    expect(llm.requests.at(-1).messages.filter((message: { role: string }) => message.role === "tool")).toHaveLength(2);
  });

  test("unanswered ask expires, denies execution and rejects a late reply", async () => {
    await bootstrap(80);
    const session = await newSession();
    llm.reply({ calls: [{ id: "expires", name: "write", args: { path: "expired.txt", content: "no" } }] });
    await prompt(session);
    const asked = await feed!.until("permission.asked", session) as PermissionEvent;
    expect(asked.data.timeoutMs).toBe(80);
    const ended = await feed!.until("tool.execution.end", session);
    expect(ended.data.isError).toBe(true);
    await feed!.until("agent.end", session);
    expect((await answer(asked.data.id, "allow_once")).status).toBe(404);
    expect(existsSync(join(sb.project, "expired.txt"))).toBe(false);
    expect(llm.requests).toHaveLength(2); // bootstrap plus the one denied turn
  });

  test("an ask with no SSE listener denies at once instead of waiting for its deadline", async () => {
    await bootstrap(10_000);
    await feed!.close();
    feed = undefined;
    const session = await newSession();
    llm.reply({ calls: [{ id: "unattended", name: "write", args: { path: "unattended.txt", content: "no" } }] });
    const started = Date.now();
    await prompt(session);
    let denied = false;
    while (!denied && Date.now() - started < 5_000) {
      const page = await (await sb.api(`/sessions/${session}/messages`)).json() as { messages: Array<{ role: string; isError?: boolean }> };
      denied = page.messages.some((message) => message.role === "tool_result" && message.isError === true);
      if (!denied) await Bun.sleep(20);
    }
    expect(denied).toBe(true);
    expect(existsSync(join(sb.project, "unattended.txt"))).toBe(false);
  }, 15_000);

  test("disconnecting the last SSE listener denies a pending ask before its deadline", async () => {
    await bootstrap(5_000);
    const session = await newSession();
    llm.reply({ calls: [{ id: "disconnect", name: "write", args: { path: "disconnected.txt", content: "no" } }] });
    await prompt(session);
    const asked = await feed!.until("permission.asked", session) as PermissionEvent;
    await feed!.close();
    feed = undefined;
    // The only observer has disconnected, so no SSE event can report the
    // decision. Poll the persisted session log, well before the 5s deadline.
    const dir = join(sb.env.XDG_DATA_HOME, "zeta", "sessions");
    let denied = false;
    for (let attempt = 0; attempt < 30 && !denied; attempt++) {
      const file = readdirSync(dir, { recursive: true }).find((name) => String(name).endsWith(`${session}.jsonl`));
      if (file) {
        const log = readFileSync(join(dir, String(file)), "utf8");
        denied = log.split("\n").some((line) => line.includes('"role":"tool_result"') && line.includes('"isError":true'));
      }
      if (!denied) await Bun.sleep(20);
    }
    expect(denied).toBe(true);
    expect((await answer(asked.data.id, "allow_once")).status).toBe(404);
    expect(existsSync(join(sb.project, "disconnected.txt"))).toBe(false);
  });
});
