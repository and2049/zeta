import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { FakeOpenAI } from "./fake-openai";
import { Sandbox } from "./harness";
import { waitFor } from "./wait-for";

let sb: Sandbox;
let llm: FakeOpenAI;
const provider = (url: string) => ({ fake: { options: { baseURL: url } } });

beforeEach(() => {
  sb = new Sandbox();
  llm = new FakeOpenAI();
  sb.writeConfig({ model: "fake/base", provider: provider(llm.baseURL) });
});
afterEach(async () => {
  await sb.cleanup();
  llm.stop();
});

describe("session configuration", () => {
  test("project profile overrides global profile, both layered over defaults", async () => {
    const global = join(sb.env.XDG_CONFIG_HOME, "zeta", "profiles");
    const project = join(sb.project, ".zeta", "profiles");
    mkdirSync(global, { recursive: true });
    mkdirSync(project, { recursive: true });
    writeFileSync(join(global, "review.jsonc"), JSON.stringify({ model: "fake/global-profile" }));
    writeFileSync(join(project, "review.jsonc"), JSON.stringify({ model: "fake/project-profile" }));
    llm.reply({ text: "project" });
    await sb.start();
    const session = (await (await sb.api("/sessions", "POST", { location: sb.project, profile: "review" })).json()).id;
    await sb.api(`/sessions/${session}/prompt`, "POST", { text: "hi" });
    await waitFor(async () => !(await (await sb.api(`/sessions/${session}`)).json()).running);
    expect(llm.requests[0].model).toBe("project-profile");
    expect(llm.requests[0].messages[0].role).toBe("system");
    expect((await (await sb.api(`/sessions/${session}/messages`)).json()).messages.at(-1).content[0].text).toBe("project");
  });

  test("session model and environment selectors override config on a reused server", async () => {
    await sb.start();
    llm.reply({ text: "first" }, { text: "second" }, { text: "third" });
    const pid = sb.discovery().pid;
    for (const [text, selectors] of [
      ["initial", {}],
      ["selected", { model: "fake/selected" }],
      ["environment", { model: "fake/selected", environment: { model: "fake/caller-env" } }],
    ] as const) {
      const session = (await (await sb.api("/sessions", "POST", { location: sb.project, ...selectors })).json()).id;
      await sb.api(`/sessions/${session}/prompt`, "POST", { text });
      await waitFor(async () => !(await (await sb.api(`/sessions/${session}`)).json()).running);
    }
    expect(sb.discovery().pid).toBe(pid);
    expect(llm.requests.map((request) => request.model)).toEqual(["base", "selected", "caller-env"]);
  });

});
