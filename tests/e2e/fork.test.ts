import { afterEach, beforeEach, expect, test } from "bun:test";
import { FakeOpenAI } from "./fake-openai";
import { Sandbox, jsonEvents } from "./harness";

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

async function messages(id: string): Promise<Array<{ id: string; role: string; content: Array<{ text?: string }> }>> {
  return (await (await sb.api(`/sessions/${id}/messages`)).json()).messages;
}

test("fork copies a session up to a message, with tool results, and both go on separately", async () => {
  llm.reply({ calls: [{ id: "r", name: "missing_tool", args: {} }] }, { text: "first reply" });
  const first = await sb.zeta(["run", "--json", "start"]);
  expect(first.code).toBe(0);
  const source = jsonEvents(first.stdout)[0].session;
  const history = await messages(source);
  expect(history.map((m) => m.role)).toEqual(["user", "assistant", "tool_result", "assistant"]);

  // Forking at the tool call brings its result along.
  const forked = await (await sb.api(`/sessions/${source}/fork`, "POST", { fromMessageId: history[1].id })).json();
  expect(forked.forkedFrom).toBe(source);
  expect(forked.forkedAt).toBe(history[2].id);
  expect((await messages(forked.id)).map((m) => m.role)).toEqual(["user", "assistant", "tool_result"]);

  // With no message the whole history is copied; the copy continues alone.
  const whole = await (await sb.api(`/sessions/${source}/fork`, "POST", {})).json();
  llm.reply({ text: "fork reply" });
  expect((await sb.api(`/sessions/${whole.id}/prompt`, "POST", { text: "only in the fork" })).status).toBe(200);
  for (let i = 0; i < 100 && (await messages(whole.id)).length < 6; i++) await Bun.sleep(20);
  expect((await messages(whole.id)).length).toBe(6);
  expect((await messages(source)).length).toBe(4);

  expect((await sb.api(`/sessions/${source}/fork`, "POST", { fromMessageId: "msg_nope" })).status).toBe(404);
  expect((await sb.api(`/sessions/ses_nope/fork`, "POST", {})).status).toBe(404);
  const listed = await (await sb.api("/sessions")).json();
  expect(listed.find((s: { id: string }) => s.id === forked.id).forkedFrom).toBe(source);
});
