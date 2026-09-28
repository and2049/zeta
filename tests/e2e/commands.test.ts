import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { FakeOpenAI } from "./fake-openai";
import { Sandbox } from "./harness";

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

function template(dir: string, name: string, text: string) {
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, `${name}.md`), text);
}

describe("prompt-template commands", () => {
  test("templates are listed, expanded server-side and logged as the expanded text", async () => {
    const user = join(sb.home, ".config/zeta/prompts");
    template(user, "review", "user version");
    template(user, "model", "reserved name");
    template(user, "plain", "Summarize the diff.\nThen stop.");
    template(join(sb.project, ".zeta/prompts"), "review", "---\ndescription: Review files\nargument-hint: <path> [focus]\n---\nReview $1 for ${2:-bugs}. All: $@");

    llm.reply({ text: "warm" });
    expect((await sb.zeta(["run", "warm"])).code).toBe(0);

    const listing = await json(`/commands?location=${encodeURIComponent(sb.project)}`);
    expect(listing.commands).toEqual([
      { name: "plain", description: "Summarize the diff.", argumentHint: null, source: "user" },
      { name: "review", description: "Review files", argumentHint: "<path> [focus]", source: "project" },
    ]);
    const registry = await json(`/registry?location=${encodeURIComponent(sb.project)}`);
    expect(registry.commands.map((c: { name: string }) => c.name)).toEqual(["plain", "review"]);
    expect(registry.diagnostics.some((d: string) => d.includes("model.md") && d.includes("built-in"))).toBe(true);

    // Edits apply without a reload.
    template(user, "fresh", "new");
    expect((await json(`/commands?location=${encodeURIComponent(sb.project)}`)).commands.length).toBe(3);

    const id = (await json("/sessions", "POST", { location: sb.project })).id;
    llm.reply({ text: "reviewed" });
    const receipt = await json(`/sessions/${id}/command`, "POST", { name: "review", arguments: "src/a.zig 'two words'" });
    expect(receipt.inboxId).toMatch(/^msg_/);
    const expanded = "Review src/a.zig for two words. All: src/a.zig two words";
    for (let i = 0; i < 150 && llm.requests.length < 2; i++) await Bun.sleep(20);
    expect(JSON.stringify(llm.requests.at(-1).messages.at(-1))).toContain(expanded);
    for (let i = 0; i < 150; i++) {
      if ((await json(`/sessions/${id}`)).running === false) break;
      await Bun.sleep(20);
    }
    const snapshot = await json(`/sessions/${id}`);
    const first = snapshot.messages.find((m: { role: string }) => m.role === "user");
    expect(first.content).toEqual([{ type: "text", text: expanded }]);

    expect((await sb.api(`/sessions/${id}/command`, "POST", { name: "missing" })).status).toBe(404);
    expect((await sb.api(`/sessions/${id}/command`, "POST", { name: "model" })).status).toBe(404);
    expect((await sb.api("/sessions/ses_none/command", "POST", { name: "review" })).status).toBe(404);
    expect((await sb.api(`/sessions/${id}/command`)).status).toBe(405);
  });
});
