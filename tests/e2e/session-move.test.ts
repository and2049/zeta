import { afterEach, beforeEach, expect, test } from "bun:test";
import { existsSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { FakeOpenAI } from "./fake-openai";
import { Sandbox, zetaBin } from "./harness";
import { waitFor } from "./wait-for";

let sb: Sandbox;
let llm: FakeOpenAI;
let server: ReturnType<typeof Bun.spawn>;
let other: string;

beforeEach(async () => {
  sb = new Sandbox();
  llm = new FakeOpenAI();
  other = join(sb.root, "other");
  mkdirSync(join(sb.project, ".git"));
  mkdirSync(join(other, ".git"), { recursive: true });
  sb.writeConfig({ model: "fake/test-model", provider: { fake: { options: { baseURL: llm.baseURL } } } });
  server = Bun.spawn([zetaBin, "serve"], { cwd: sb.project, env: sb.env, stdout: "ignore", stderr: "ignore" });
  await waitFor(() => existsSync(sb.discoveryPath), "move server discovery");
});
afterEach(async () => { await sb.cleanup(); await server.exited; llm.stop(); });

const locationList = async (path: string) => (await (await sb.api(`/sessions?location=${encodeURIComponent(path)}`)).json()) as any[];

test("persisted move changes listings and next request context; empty move has no note", async () => {
  const first = await (await sb.api("/sessions", "POST", { location: sb.project })).json();
  llm.reply({ text: "first answer" }, { text: "second answer" });
  expect((await sb.api(`/sessions/${first.id}/prompt`, "POST", { text: "first question" })).status).toBe(200);
  await waitFor(() => llm.requests.length === 1, "first request");
  await waitFor(async () => !(await (await sb.api(`/sessions/${first.id}`)).json()).running, "first reply");
  expect(await (await sb.api(`/sessions/${first.id}/move`, "POST", { directory: other })).json()).toEqual({ moved: true, location: other });
  expect((await locationList(other)).some(s => s.id === first.id)).toBe(true);
  expect((await locationList(sb.project)).some(s => s.id === first.id)).toBe(false);
  expect((await (await sb.api(`/sessions/${first.id}`)).json()).info.location).toBe(other);
  expect((await (await sb.api(`/sessions/${first.id}/move`, "POST", { directory: join(other, ".git") })).json()).moved).toBe(false);
  expect((await sb.api(`/sessions/${first.id}/prompt`, "POST", { text: "second question" })).status).toBe(200);
  await waitFor(() => llm.requests.length === 2, "second request");
  const messages = llm.requests[1].messages;
  expect(messages[0].content).toContain(`Project directory: ${other}`);
  expect(messages.some((m: any) => m.role === "user" && m.content === `The project directory is now ${other}.`)).toBe(true);

  const empty = await (await sb.api("/sessions", "POST", { location: sb.project })).json();
  expect(await (await sb.api(`/sessions/${empty.id}/move`, "POST", { directory: other })).json()).toEqual({ moved: true, location: other });
  expect((await (await sb.api(`/sessions/${empty.id}`)).json()).messages).toEqual([]);
  expect((await locationList(other)).some(s => s.id === empty.id)).toBe(false);
});

test("running move conflicts; directory listing is sorted, bounded to directories, and validates paths", async () => {
  let release!: () => void;
  const pause = new Promise<void>(resolve => { release = resolve; });
  llm.reply({ text: "waiting", afterFirstChunk: pause });
  const created = await (await sb.api("/sessions", "POST", { location: sb.project })).json();
  try {
    expect((await sb.api(`/sessions/${created.id}/prompt`, "POST", { text: "wait" })).status).toBe(200);
    await waitFor(() => llm.requests.length === 1, "paused request");
    expect((await sb.api(`/sessions/${created.id}/move`, "POST", { directory: other })).status).toBe(409);
  } finally { release(); }

  mkdirSync(join(sb.root, ".hidden"));
  const entries = (await (await sb.api(`/directories?path=${encodeURIComponent(sb.root)}`)).json()).entries.map((e: any) => e.name);
  expect(entries).toEqual([...entries].sort());
  expect(entries).toContain(".hidden");
  expect(entries).toContain("other");
  expect((await sb.api("/directories?path=relative")).status).toBe(400);
  expect((await sb.api(`/directories?path=${encodeURIComponent(join(sb.root, "missing"))}`)).status).toBe(404);
  expect((await sb.api(`/directories?path=${encodeURIComponent(sb.discoveryPath)}`)).status).toBe(400);
  expect((await sb.api(`/sessions/${created.id}/move`, "POST", { directory: "relative" })).status).toBe(400);
  expect((await sb.api(`/sessions/${created.id}/move`, "POST", { directory: join(sb.root, "missing") })).status).toBe(404);
  expect((await sb.api(`/sessions/${created.id}/move`, "POST", { directory: sb.discoveryPath })).status).toBe(400);
  expect((await sb.api(`/sessions/${created.id}/move`, "POST", { directory: other, extra: true })).status).toBe(400);
});
