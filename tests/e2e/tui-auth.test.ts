import { afterEach, beforeEach, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { Sandbox } from "./harness";
import { FakeOpenAI } from "./fake-openai";
import { Tui, waitFor } from "./tui-harness";

let sb: Sandbox;
let llm: FakeOpenAI;
let ui: Tui | undefined;
beforeEach(() => {
  sb = new Sandbox();
  llm = new FakeOpenAI();
  sb.writeConfig({ model: "fake/base", provider: { fake: { options: { baseURL: llm.baseURL } } } });
});
afterEach(async () => { await ui?.close(); ui = undefined; await sb.cleanup(); llm.stop(); });

async function start() {
  ui = new Tui(sb);
  await ui.ready();
  await waitFor(() => existsSync(sb.discoveryPath), "server started");
  await waitFor(() => ui!.screen().includes("fake/base"), "model loaded");
  return ui;
}

async function pickFake(t: Tui) {
  await waitFor(() => t.screen().includes("Provider"), "provider picker");
  t.send("fake\r");
  await waitFor(() => t.screen().includes("Method") && t.screen().includes("API key"), "API method picker");
  t.send("\r");
  await waitFor(() => t.screen().includes("Paste the key (hidden)"), "masked key editor");
}

test("real PTY /connect saves API key without echo, transcript, or errors", async () => {
  const t = await start();
  t.send("/connect\r");
  await pickFake(t);
  const key = "e2e-secret-DO-NOT-ECHO-123";
  t.send(`\x1b[200~${key}\x1b[201~`);
  await waitFor(() => t.screen().includes("•"), "masked input");
  expect(t.output).not.toContain(key);
  t.send("\r");
  await waitFor(async () => (await (await sb.api("/credentials")).json()).providers.some((p: any) => p.id === "fake"), "credential stored");
  await waitFor(() => t.screen().includes("Model"), "refreshed model picker");
  expect(readFileSync(join(sb.env.XDG_DATA_HOME, "zeta", "credentials.json"), "utf8")).toContain(key);
  expect(JSON.stringify(sb.sessionMessages())).not.toContain(key);
  expect(t.output).not.toContain(key);
  t.send("\x1b");
  await waitFor(() => !t.screen().includes("Model"), "model picker dismissed");
  expect(await t.quit()).toBe(0);
}, 20000);

test("real PTY /connect cancellation, Ctrl+C secret clearing, and editor recovery", async () => {
  const t = await start();
  t.send("/connect\r");
  await pickFake(t);
  const key = "canceled-secret-DO-NOT-ECHO";
  t.send(key);
  await waitFor(() => t.screen().includes("•"), "masked input");
  t.send("\x03"); // Ctrl+C clears the key, not the draft or the process.
  await waitFor(() => !t.screen().includes("•"), "cleared masked key");
  expect(t.process.exitCode).toBeNull();
  t.send("another-secret\x1b");
  await waitFor(() => !t.screen().includes("Paste the key (hidden)"), "key editor dismissed");
  t.send("draft survives");
  await waitFor(() => t.screen().includes("draft survives"), "conversation editor usable after Escape");
  expect((await (await sb.api("/credentials")).json()).providers).not.toContainEqual({ id: "fake", type: "api" });
  expect(t.output).not.toContain(key);
  expect(t.output).not.toContain("another-secret");
  expect(JSON.stringify(sb.sessionMessages())).not.toContain(key);
  expect(await t.quit()).toBe(0);
}, 20000);

test.skipIf(process.platform !== "linux")("known OAuth flow is canceled on Ctrl+Q; browser opener receives URL as one argument", async () => {
  const bin = join(sb.root, "bin");
  mkdirSync(bin);
  const marker = join(sb.root, "opened-url");
  const opener = join(bin, "xdg-open");
  writeFileSync(opener, `#!/bin/sh\nprintf '%s' "$1" > '${marker}'\n`);
  chmodSync(opener, 0o755);
  sb.env.PATH = `${bin}:${sb.env.PATH}`;
  const t = await start();
  t.send("/connect\r");
  await waitFor(() => t.screen().includes("Provider"), "provider picker");
  t.send("OpenAI\r");
  await waitFor(() => t.screen().includes("Method"), "method picker");
  t.send("browser\r");
  await waitFor(() => t.screen().includes("Login") && t.screen().includes("URL"), "OAuth receipt");
  await waitFor(() => existsSync(marker), "stub browser opened");
  expect(readFileSync(marker, "utf8")).toContain("/oauth/authorize?");
  expect(await t.quit()).toBe(0);
  const next = await sb.api("/auth/openai/start", "POST", { method: "browser" });
  expect(next.status).toBe(200);
  const flow = await next.json();
  expect((await sb.api(`/auth/openai/flow?id=${encodeURIComponent(flow.id)}`, "DELETE")).status).toBe(200);
}, 20000);
