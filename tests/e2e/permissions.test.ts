import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { FakeOpenAI } from "./fake-openai";
import { Sandbox, type AgentEvent } from "./harness";

// zeta asks nothing itself: these tests drive the example permissions
// extension, which asks through the generic question API.
type QuestionEvent = AgentEvent & { data: AgentEvent["data"] & { id: string; kind: string; message: string; source: string; options: Array<{ value: string; label: string }> } };

const example = join(import.meta.dir, "../../docs/examples/extensions/permissions");

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
      signal: AbortSignal.timeout(20_000),
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

async function newSession(): Promise<string> {
  const response = await sb.api("/sessions", "POST", { location: sb.project });
  expect(response.status).toBe(200);
  return ((await response.json()) as { id: string }).id;
}

async function prompt(session: string) {
  expect((await sb.api(`/sessions/${session}/prompt`, "POST", { text: "write a file" })).status).toBe(200);
}

function reply(id: string, action: string, content?: unknown) {
  return sb.api(`/questions/${id}/reply`, "POST", content === undefined ? { action } : { action, content });
}

async function bootstrap(settings: object = { rules: [{ tool: "write", pattern: "*", effect: "ask" }] }) {
  mkdirSync(join(sb.project, ".zeta", "extensions"), { recursive: true });
  cpSync(example, join(sb.project, ".zeta", "extensions", "permissions"), { recursive: true });
  sb.writeConfig({
    model: "fake/test-model",
    provider: { fake: { options: { baseURL: llm.baseURL } } },
    plugin: { permissions: settings },
  });
  llm.reply({ text: "ready" });
  expect((await sb.zeta(["run", "start server"])).code).toBe(0);
  feed = await Feed.open(sb);
}

function toolResults() {
  return llm.requests.at(-1).messages.filter((message: { role: string }) => message.role === "tool");
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

describe("questions from the example permissions extension", () => {
  test("a rule that asks puts a choice to the user; 'once' runs the call and asks again next time", async () => {
    await bootstrap();
    const session = await newSession();
    llm.reply(
      { calls: [{ id: "once-1", name: "write", args: { path: "once.txt", content: "first" } }] },
      { calls: [{ id: "once-2", name: "write", args: { path: "once.txt", content: "second" } }] },
      { text: "done" },
    );
    await prompt(session);
    const first = await feed!.until("question.asked", session) as QuestionEvent;
    expect(first.data.kind).toBe("select");
    expect(first.data.source).toBe("permissions");
    expect(first.data.message).toContain(join(sb.project, "once.txt"));
    expect(first.data.options.map((o) => o.value)).toEqual(["once", "session", "deny"]);
    const listed = (await (await sb.api(`/questions?location=${encodeURIComponent(sb.project)}`)).json()).questions;
    expect(listed.map((q: { id: string }) => q.id)).toEqual([first.data.id]);
    // An answer that is not one of the options is refused and the question stays open.
    expect((await reply(first.data.id, "accept", "sometimes")).status).toBe(400);
    expect((await reply(first.data.id, "accept", "once")).status).toBe(200);
    expect((await reply(first.data.id, "accept", "once")).status).toBe(404);
    const second = await feed!.until("question.asked", session) as QuestionEvent;
    expect(second.data.id).not.toBe(first.data.id);
    expect((await reply(second.data.id, "accept", "once")).status).toBe(200);
    await feed!.until("agent.end", session);
    expect(readFileSync(join(sb.project, "once.txt"), "utf8")).toBe("second");
    expect(toolResults()).toHaveLength(2);
  });

  test("'for this session' stops asking about the same call", async () => {
    await bootstrap();
    const session = await newSession();
    llm.reply(
      { calls: [{ id: "session-1", name: "write", args: { path: "session.txt", content: "one" } }] },
      { calls: [{ id: "session-2", name: "write", args: { path: "session.txt", content: "two" } }] },
      { text: "done" },
    );
    await prompt(session);
    const asked = await feed!.until("question.asked", session) as QuestionEvent;
    expect((await reply(asked.data.id, "accept", "session")).status).toBe(200);
    const observed: string[] = [];
    while (true) {
      const event = await feed!.next();
      if (event.session !== session) continue;
      observed.push(event.type);
      if (event.type === "agent.end") break;
    }
    expect(observed).not.toContain("question.asked");
    expect(observed.filter((type) => type === "tool.execution.end")).toHaveLength(2);
  });

  test("denying ends the turn with the reason as the call's result", async () => {
    await bootstrap();
    const session = await newSession();
    llm.reply({ calls: [{ id: "denied", name: "write", args: { path: "denied.txt", content: "no" } }] });
    await prompt(session);
    const asked = await feed!.until("question.asked", session) as QuestionEvent;
    expect((await reply(asked.data.id, "accept", "deny")).status).toBe(200);
    const ended = await feed!.until("tool.execution.end", session);
    expect(ended.data.isError).toBe(true);
    expect(ended.data.result.content[0].text).toBe("The user denied this write call.");
    await feed!.until("agent.end", session);
    expect(existsSync(join(sb.project, "denied.txt"))).toBe(false);
    expect(llm.requests).toHaveLength(2); // bootstrap plus the one denied turn
  });

  test("reading outside the project asks; a rule can deny without asking", async () => {
    const outside = join(sb.root, "outside.txt");
    writeFileSync(outside, "secret");
    await bootstrap({ rules: [{ tool: "write", pattern: "*/.env", effect: "deny" }] });
    const session = await newSession();
    llm.reply(
      { calls: [{ id: "far", name: "read", args: { path: outside } }] },
      { calls: [{ id: "env", name: "write", args: { path: ".env", content: "X=1" } }] },
      { text: "done" },
    );
    await prompt(session);
    const asked = await feed!.until("question.asked", session) as QuestionEvent;
    expect(asked.data.message).toBe(`Allow read outside the project: ${outside}`);
    expect((await reply(asked.data.id, "accept", "once")).status).toBe(200);
    const read = await feed!.until("tool.execution.end", session);
    expect(read.data.result.content[0].text).toContain("secret");
    const write = await feed!.until("tool.execution.end", session);
    expect(write.data.result.content[0].text).toBe("A permission rule denies this write call.");
    await feed!.until("agent.end", session);
    expect(existsSync(join(sb.project, ".env"))).toBe(false);
  });

  test("aborting the turn withdraws its open question", async () => {
    await bootstrap();
    const session = await newSession();
    llm.reply({ calls: [{ id: "pending", name: "write", args: { path: "unapproved.txt", content: "no" } }] });
    await prompt(session);
    const asked = await feed!.until("question.asked", session) as QuestionEvent;
    expect((await sb.api(`/sessions/${session}/abort`, "POST", {})).status).toBe(200);
    const resolved = await feed!.until("question.resolved", session);
    expect(resolved.data).toEqual({ id: asked.data.id, action: "cancel" });
    expect((await reply(asked.data.id, "accept", "once")).status).toBe(404);
    expect(existsSync(join(sb.project, "unapproved.txt"))).toBe(false);
  });

  test("with no SSE listener a question declines at once, and the call is denied", async () => {
    await bootstrap();
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

  test("disconnecting the last SSE listener declines an open question", async () => {
    await bootstrap();
    const session = await newSession();
    llm.reply({ calls: [{ id: "disconnect", name: "write", args: { path: "disconnected.txt", content: "no" } }] });
    await prompt(session);
    const asked = await feed!.until("question.asked", session) as QuestionEvent;
    await feed!.close();
    feed = undefined;
    // No SSE listener remains to report the outcome: poll the session log.
    const dir = join(sb.env.XDG_DATA_HOME, "zeta", "sessions");
    let denied = false;
    for (let attempt = 0; attempt < 100 && !denied; attempt++) {
      const file = readdirSync(dir, { recursive: true }).find((name) => String(name).endsWith(`${session}.jsonl`));
      if (file) {
        const log = readFileSync(join(dir, String(file)), "utf8");
        denied = log.split("\n").some((line) => line.includes('"role":"tool_result"') && line.includes('"isError":true'));
      }
      if (!denied) await Bun.sleep(20);
    }
    expect(denied).toBe(true);
    expect((await reply(asked.data.id, "accept", "once")).status).toBe(404);
    expect(existsSync(join(sb.project, "disconnected.txt"))).toBe(false);
  });
});
