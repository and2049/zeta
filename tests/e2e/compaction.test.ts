import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { FakeOpenAI } from "./fake-openai";
import { Sandbox, jsonEvents } from "./harness";

let sb: Sandbox;
let llm: FakeOpenAI;

beforeEach(() => {
  sb = new Sandbox();
  llm = new FakeOpenAI();
  sb.writeConfig({
    model: "fake/small",
    provider: { fake: { options: { baseURL: llm.baseURL }, models: { small: { name: "Small", limit: { context: 2000 } } } } },
    compaction: { reserveTokens: 100, keepRecentTokens: 500 },
  });
});

afterEach(async () => {
  await sb.cleanup();
  llm.stop();
});

const system = (request: { messages: Array<{ role: string; content: unknown }> }) => String(request.messages[0]?.content ?? "");

describe("compaction", () => {
  test("a history past the window is summarized before the request", async () => {
    llm.reply({ text: "first answer" });
    const first = await sb.zeta(["run", "--json", "x".repeat(4000)]);
    expect(first.code).toBe(0);
    const session = jsonEvents(first.stdout)[0].session;
    llm.reply({ text: "## Goal\nSUMMARY TEXT" }, { text: "second answer" });
    const sent = await sb.api(`/sessions/${session}/prompt`, "POST", { text: "y".repeat(8000) });
    expect(sent.status).toBe(200);
    for (let i = 0; i < 200 && llm.requests.length < 3; i++) await Bun.sleep(20);
    expect(system(llm.requests[1])).toContain("You summarize a coding session");
    expect(JSON.stringify(llm.requests[1].messages)).toContain("[User]: xxxx");
    const main = llm.requests[2].messages.filter((m: { role: string }) => m.role !== "system");
    expect(JSON.stringify(main[0].content)).toContain("SUMMARY TEXT");
    expect(JSON.stringify(main.at(-1).content)).toContain("yyyy");
    expect(JSON.stringify(llm.requests[2].messages)).not.toContain("first answer");
    const logged = sb.sessionMessages() as Array<{ origin?: string; firstKeptId?: string; tokensBefore?: number }>;
    const summary = logged.find((m) => m.origin === "compaction")!;
    expect(summary.firstKeptId).toBeDefined();
    expect(summary.tokensBefore!).toBeGreaterThan(2000);
  });

  test("POST /compact queues a manual compaction with instructions", async () => {
    llm.reply({ text: "one" });
    const first = await sb.zeta(["run", "--json", "tell me about the build"]);
    const session = jsonEvents(first.stdout)[0].session;
    llm.reply({ text: "## Goal\nMANUAL SUMMARY" });
    const queued = await sb.api(`/sessions/${session}/compact`, "POST", { instructions: "keep build commands" });
    expect(queued.status).toBe(200);
    expect((await queued.json()).inboxId).toMatch(/^msg_/);
    for (let i = 0; i < 200 && llm.requests.length < 2; i++) await Bun.sleep(20);
    expect(JSON.stringify(llm.requests[1].messages)).toContain("Focus on: keep build commands");
    for (let i = 0; i < 100 && !sb.sessionMessages().some((m) => (m as { origin?: string }).origin === "compaction"); i++) await Bun.sleep(20);
    expect(sb.sessionMessages().some((m) => (m as { origin?: string }).origin === "compaction")).toBe(true);
    expect((await sb.api("/sessions/ses_missing/compact", "POST", {})).status).toBe(404);
  });

  test("a request rejected as too long is compacted and sent again, with the session as cache key", async () => {
    sb.writeConfig({
      model: "fake/small",
      provider: { fake: { options: { baseURL: llm.baseURL, setCacheKey: true }, models: { small: { name: "Small" } } } },
    });
    llm.reply({ text: "first answer" });
    const first = await sb.zeta(["run", "--json", "tell me about the build"]);
    expect(first.code).toBe(0);
    const session = jsonEvents(first.stdout)[0].session;
    llm.reply(
      { status: 400, body: JSON.stringify({ error: { message: "This model's maximum context length is 2000 tokens.", code: "context_length_exceeded" } }) },
      { text: "## Goal\nOVERFLOW SUMMARY" },
      { text: "second answer" },
    );
    expect((await sb.api(`/sessions/${session}/prompt`, "POST", { text: "and the tests?" })).status).toBe(200);
    const answered = () => sb.sessionMessages().some((m) => JSON.stringify(m).includes("second answer"));
    for (let i = 0; i < 200 && !answered(); i++) await Bun.sleep(20);
    expect(answered()).toBe(true);
    expect(llm.requests.length).toBe(4);
    expect(system(llm.requests[2])).toContain("You summarize a coding session");
    expect(JSON.stringify(llm.requests[3].messages)).toContain("OVERFLOW SUMMARY");
    expect(llm.requests[3].prompt_cache_key).toBe(session);
    const logged = sb.sessionMessages() as Array<{ role: string; stopReason?: string; origin?: string }>;
    expect(logged.some((m) => m.role === "assistant" && m.stopReason === "error")).toBe(false);
    expect(logged.some((m) => m.origin === "compaction")).toBe(true);
  });
});
