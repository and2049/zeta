import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { Sandbox } from "./harness";

let sb: Sandbox;
let other: string;

beforeEach(async () => {
  sb = new Sandbox();
  other = join(sb.root, "other");
  mkdirSync(join(sb.project, ".git"));
  mkdirSync(join(other, ".git"), { recursive: true });
  await sb.start();
});
afterEach(async () => { await sb.cleanup(); });

const locationList = async (path: string) => (await (await sb.api(`/sessions?location=${encodeURIComponent(path)}`)).json()) as any[];

test("empty session move updates its location without persisting a note", async () => {
  const empty = await (await sb.api("/sessions", "POST", { location: sb.project })).json();
  expect(await (await sb.api(`/sessions/${empty.id}/move`, "POST", { directory: other })).json()).toEqual({ moved: true, location: other });
  expect((await (await sb.api(`/sessions/${empty.id}`)).json()).messages).toEqual([]);
  expect((await locationList(other)).some(s => s.id === empty.id)).toBe(false);
});

test("directory listing and move validate paths without a provider", async () => {
  const created = await (await sb.api("/sessions", "POST", { location: sb.project })).json();
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
