import { afterEach, beforeEach, expect, test } from "bun:test";
import { cpSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { FakeOpenAI } from "./fake-openai";
import { Sandbox, jsonEvents } from "./harness";

let sb: Sandbox;
let llm: FakeOpenAI;

beforeEach(() => {
  sb = new Sandbox();
  llm = new FakeOpenAI();
  // The example permissions extension asks about files outside the project,
  // and nobody is there to answer: only reads it lets through succeed.
  mkdirSync(join(sb.project, ".zeta", "extensions"), { recursive: true });
  cpSync(join(import.meta.dir, "../../docs/examples/extensions/permissions"), join(sb.project, ".zeta", "extensions", "permissions"), { recursive: true });
  sb.writeConfig({
    model: "fake/test-model",
    provider: { fake: { options: { baseURL: llm.baseURL } } },
    plugin: { permissions: { outside: "ask" } },
    mcp: { servers: { fake: { type: "local", command: [process.execPath, join(import.meta.dir, "fake-mcp.ts")] } } },
  });
});

afterEach(async () => {
  await sb.cleanup();
  llm.stop();
});

test("an oversized result is saved in full and the model gets its start, end and path", async () => {
  const lines = Array.from({ length: 3000 }, (_, i) => `line ${i}`).join("\n");
  llm.reply({ calls: [{ id: "big", name: "mcp__fake__echo", args: { text: lines } }] }, { text: "saw it" });
  const run = await sb.zeta(["run", "--json", "show"]);
  expect(run.code).toBe(0);
  const result: string = llm.requests[1].messages.at(-1).content;
  expect(result.startsWith("line 0\n")).toBe(true);
  expect(result.endsWith("line 2999")).toBe(true);
  const path = /The full output is in (\S+);/.exec(result)![1];
  expect(readFileSync(path, "utf8")).toBe(lines);

  // Reading the saved output back is not a trip outside the project.
  llm.reply({ calls: [{ id: "back", name: "read", args: { path, offset: 1500, limit: 2 } }] }, { text: "done" });
  const session = jsonEvents(run.stdout)[0].session;
  expect((await sb.api(`/sessions/${session}/prompt`, "POST", { text: "read the rest" })).status).toBe(200);
  for (let i = 0; i < 100 && llm.requests.length < 4; i++) await Bun.sleep(20);
  expect(llm.requests[3].messages.at(-1).content).toContain("line 1499");

  // A fork gets its own copy, which outlives the source.
  const fork = await (await sb.api(`/sessions/${session}/fork`, "POST", {})).json();
  const copied: string = (await (await sb.api(`/sessions/${fork.id}/messages`)).json()).messages
    .map((m: any) => m.content.map((c: any) => c.text ?? "").join(""))
    .find((text: string) => text.includes("The full output is in"));
  const forkPath = /The full output is in (\S+);/.exec(copied)![1];
  expect(forkPath).toContain(`${fork.id}.artifacts`);

  expect((await sb.api(`/sessions/${session}`, "DELETE")).status).toBe(200);
  expect(existsSync(path)).toBe(false);
  expect(readFileSync(forkPath, "utf8")).toBe(lines);
  expect((await sb.api(`/sessions/${fork.id}`, "DELETE")).status).toBe(200);
  expect(existsSync(forkPath)).toBe(false);
});
