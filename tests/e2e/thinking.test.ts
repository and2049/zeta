import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { FakeOpenAI } from "./fake-openai";
import { Sandbox } from "./harness";

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
    await sb.start();
    const session = (await (await sb.api("/sessions", "POST", { location: sb.project })).json()).id;
    await sb.api(`/sessions/${session}`, "PATCH", { thinking: "medium" });
    await sb.api(`/sessions/${session}/prompt`, "POST", { text: "hi" });
    await waitFor(1);
    // medium is not among the model's levels: the next one up.
    expect(llm.requests[0].reasoning_effort).toBe("high");

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
    await sb.start();
    const session = (await (await sb.api("/sessions", "POST", { location: sb.project, thinking: "high" })).json()).id;
    await sb.api(`/sessions/${session}/prompt`, "POST", { text: "hi" });
    await waitFor(1);
    expect("reasoning_effort" in llm.requests[0]).toBe(false);
  });
});
