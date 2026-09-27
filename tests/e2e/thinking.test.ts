import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { FakeOpenAI } from "./fake-openai";
import { Sandbox, jsonEvents } from "./harness";

let sb: Sandbox;
let llm: FakeOpenAI;

beforeEach(() => {
  sb = new Sandbox();
  llm = new FakeOpenAI();
});

afterEach(async () => {
  await sb.cleanup();
  llm.stop();
});

const models = {
  thinker: { name: "Thinker", reasoning: true, thinkingLevels: ["low", "high"] },
  plain: { name: "Plain" },
};

async function waitFor(count: number) {
  for (let i = 0; i < 200 && llm.requests.length < count; i++) await Bun.sleep(20);
  expect(llm.requests.length).toBe(count);
}

describe("thinking level", () => {
  test("the session's level wins over the config's, fitted to the model", async () => {
    sb.writeConfig({ model: "fake/thinker", thinking: "low", provider: { fake: { options: { baseURL: llm.baseURL }, models } } });
    llm.reply({ text: "one" });
    const first = await sb.zeta(["run", "--json", "--thinking", "medium", "hi"]);
    expect(first.code).toBe(0);
    // medium is not among the model's levels: the next one up.
    expect(llm.requests[0].reasoning_effort).toBe("high");
    const session = jsonEvents(first.stdout)[0].session;

    const patched = await sb.api(`/sessions/${session}`, "PATCH", { thinking: "auto" });
    expect(patched.status).toBe(200);
    llm.reply({ text: "two" });
    await sb.api(`/sessions/${session}/prompt`, "POST", { text: "again" });
    await waitFor(2);
    expect(llm.requests[1].reasoning_effort).toBe("low");
    const snapshot = await (await sb.api(`/sessions/${session}`)).json();
    expect(snapshot.options.thinking).toBeNull();

    expect((await sb.api(`/sessions/${session}`, "PATCH", { thinking: "max" })).status).toBe(400);
  });

  test("a model that does not reason gets no setting", async () => {
    sb.writeConfig({ model: "fake/plain", thinking: "high", provider: { fake: { options: { baseURL: llm.baseURL }, models } } });
    llm.reply({ text: "ok" });
    const r = await sb.zeta(["run", "--thinking", "high", "hi"]);
    expect(r.code).toBe(0);
    expect("reasoning_effort" in llm.requests[0]).toBe(false);
  });
});
