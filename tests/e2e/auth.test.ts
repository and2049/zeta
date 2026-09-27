import { afterEach, beforeEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { FakeOpenAI } from "./fake-openai";
import { Sandbox } from "./harness";

let sb: Sandbox;
let llm: FakeOpenAI;

beforeEach(async () => {
  sb = new Sandbox();
  llm = new FakeOpenAI();
  sb.writeConfig({ model: "fake/base", provider: { fake: { options: { baseURL: llm.baseURL } } } });
  await sb.start();
});
afterEach(async () => {
  await sb.cleanup();
  llm.stop();
});

test("auth catalog has named API and OpenAI OAuth methods, custom only with location", async () => {
  const base = await sb.api("/auth/providers");
  expect(base.status).toBe(200);
  const { providers } = await base.json();
  expect(providers.map((p: any) => [p.id, p.name])).toEqual([
    ["openai", "OpenAI"], ["anthropic", "Anthropic"], ["deepseek", "DeepSeek"],
    ["zai", "Z.AI"], ["zhipuai", "Zhipu AI"], ["openrouter", "OpenRouter"],
  ]);
  expect(providers[0].methods.map((m: any) => [m.id, m.type])).toEqual([
    ["api", "api"], ["browser", "oauth"], ["device", "oauth"],
  ]);
  expect(providers[0].methods.map((m: any) => m.label)).toEqual([
    "API key", "ChatGPT (browser)", "ChatGPT (device code)",
  ]);
  for (const provider of providers.slice(1)) expect(provider.methods.map((m: any) => m.id)).toEqual(["api"]);
  expect(providers.some((p: any) => p.id === "fake")).toBe(false);
  const withLocation = await sb.api(`/auth/providers?location=${encodeURIComponent(sb.project)}`);
  expect(withLocation.status).toBe(200);
  expect((await withLocation.json()).providers).toContainEqual({
    id: "fake", name: "fake", methods: [{ id: "api", label: "API key", type: "api" }],
  });
  expect((await sb.api("/auth/providers?location=relative")).status).toBe(400);
});

test("API-key PUT defaults type to api and never echoes key", async () => {
  const secret = "e2e-auth-secret";
  const response = await sb.api("/credentials/zai", "PUT", { key: secret });
  expect(response.status).toBe(200);
  expect(await response.json()).toEqual({ id: "zai", type: "api" });
  expect((await (await sb.api("/credentials")).text())).not.toContain(secret);
  const data = JSON.parse(readFileSync(join(sb.env.XDG_DATA_HOME, "zeta", "credentials.json"), "utf8"));
  expect(data.zai).toEqual({ type: "api", key: secret });
  expect((await sb.api("/credentials/zai", "PUT", { type: "oauth", key: secret })).status).toBe(400);
});

test("model discovery lists connected providers and configured keyless endpoints only", async () => {
  const providers: Record<string, any> = {
    openai: { models: { "fixture-openai": { name: "Fixture OpenAI" } } },
    deepseek: { models: { "fixture-deepseek": { name: "Fixture DeepSeek" } } },
    local: { options: { baseURL: llm.baseURL }, models: { "local-model": { name: "Local model" } } },
  };
  sb.writeConfig({ provider: providers });
  const path = `/models?location=${encodeURIComponent(sb.project)}`;
  async function listed() {
    const response = await sb.api(path);
    expect(response.status).toBe(200);
    const value = await response.json();
    expect(JSON.stringify(value)).not.toContain("model-picker-secret");
    return value.providers.map((p: any) => p.id).sort();
  }
  expect(await listed()).toEqual(["local"]);
  expect((await sb.api("/credentials/openai", "PUT", { key: "model-picker-secret" })).status).toBe(200);
  expect(await listed()).toEqual(["local", "openai"]);
  providers.deepseek.options = { apiKey: "model-picker-secret" };
  sb.writeConfig({ provider: providers });
  expect(await listed()).toEqual(["deepseek", "local", "openai"]);
  // Explicit empty config masks stored keys just as it does for execution.
  providers.openai.options = { apiKey: "" };
  sb.writeConfig({ provider: providers });
  expect(await listed()).toEqual(["deepseek", "local"]);
});

test("a new browser flow replaces a pending one; status/cancel retain no secrets", async () => {
  expect((await sb.api("/auth/openai/start", "POST", { method: "api" })).status).toBe(400);
  expect((await sb.api("/auth/deepseek/start", "POST", { method: "browser" })).status).toBe(400);
  expect((await sb.api("/auth/nobody/start", "POST", { method: "browser" })).status).toBe(404);
  // A configured custom provider resolves to the fallback, which has no sign-in.
  sb.writeConfig({ provider: { local: { options: { baseURL: "http://127.0.0.1:9/v1" } } } });
  const custom = await sb.api("/auth/local/start", "POST", { method: "browser", location: sb.project });
  expect(custom.status).toBe(400);
  expect((await custom.json()).error).toBe("provider has no sign-in");
  expect((await sb.api("/auth/openai/status")).status).toBe(400);
  const response = await sb.api("/auth/openai/start", "POST", { method: "browser" });
  expect(response.status).toBe(200);
  const receipt = await response.json();
  expect(receipt.id).toMatch(/^[0-9a-f]{32}$/);
  expect(receipt.url).toContain("auth.openai.com");
  expect(typeof receipt.instructions).toBe("string");
  // An abandoned pending flow never blocks the next sign-in.
  const abandoned = encodeURIComponent(receipt.id);
  const second = await sb.api("/auth/openai/start", "POST", { method: "browser" });
  expect(second.status).toBe(200);
  const secondReceipt = await second.json();
  expect(secondReceipt.id).not.toBe(receipt.id);
  expect((await sb.api(`/auth/openai/status?id=${abandoned}`)).status).toBe(404);
  const id = encodeURIComponent(secondReceipt.id);
  expect(await (await sb.api(`/auth/openai/status?id=${id}`)).json()).toEqual({ status: "pending", error: null });
  expect((await sb.api("/auth/openai/status?id=unknown")).status).toBe(404);
  expect((await sb.api("/auth/openai/flow?id=unknown", "DELETE")).status).toBe(404);
  expect((await sb.api(`/auth/openai/flow?id=${id}`, "DELETE")).status).toBe(200);
  expect(await (await sb.api(`/auth/openai/status?id=${id}`)).json()).toEqual({ status: "error", error: "authentication canceled" });
  const replacement = await sb.api("/auth/openai/start", "POST", { method: "browser" });
  expect(replacement.status).toBe(200);
  expect((await replacement.json()).id).not.toBe(secondReceipt.id);
  expect((await sb.api(`/auth/openai/status?id=${id}`)).status).toBe(404);
  // Shutdown cancels and joins the pending browser listener, without waiting
  // for its ten-minute expiry.
  await sb.stop();
});
