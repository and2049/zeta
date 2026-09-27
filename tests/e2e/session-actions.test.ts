import { afterEach, beforeEach, expect, test } from "bun:test";
import { Sandbox } from "./harness";
import { FakeOpenAI } from "./fake-openai";
import { waitFor } from "./wait-for";

let sb: Sandbox;
let llm: FakeOpenAI;
beforeEach(() => {
  sb = new Sandbox(); llm = new FakeOpenAI();
  sb.writeConfig({ model: "fake/base", provider: { fake: { options: { baseURL: llm.baseURL } } } });
});
afterEach(async () => { await sb.cleanup(); llm.stop(); });
async function json(path: string, method = "GET", body?: unknown): Promise<any> {
  const response = await sb.api(path, method, body);
  expect(response.status).toBe(200);
  return response.json();
}
async function boot() {
  llm.reply({ text: "warm" });
  expect((await sb.zeta(["run", "warm"])).code).toBe(0);
  return (await json("/sessions", "POST", { location: sb.project })).id as string;
}

test("session model and title changes survive restart and affect the next run", async () => {
  const id = await boot();
  await json(`/sessions/${id}`, "PATCH", { model: "fake/alternate", title: "Renamed session" });
  const changed = await json(`/sessions/${id}`);
  expect(changed.info.title).toBe("Renamed session");
  expect(changed.options.model).toBe("fake/alternate");
  llm.reply({ text: "saved" });
  await json(`/sessions/${id}/prompt`, "POST", { text: "persist renamed" });
  await waitFor(async () => !(await json(`/sessions/${id}`)).running);
  expect((await sb.zeta(["server", "stop"])).code).toBe(0);
  llm.reply({ text: "restarted" });
  expect((await sb.zeta(["run", "restart"])).code).toBe(0);
  expect((await json(`/sessions/${id}`)).info.title).toBe("Renamed session");
  llm.reply({ text: "alternate response" });
  await json(`/sessions/${id}/prompt`, "POST", { text: "continue renamed" });
  await waitFor(async () => !(await json(`/sessions/${id}`)).running);
  expect(llm.requests.at(-1)?.model).toBe("alternate");
});

test("removing one pending input leaves the active turn and other input intact", async () => {
  const id = await boot();
  llm.reply({ text: "active", chunks: 6, delayMs: 100 });
  await json(`/sessions/${id}/prompt`, "POST", { text: "active prompt" });
  await waitFor(() => llm.requests.some((r) => r.messages.some((m: any) => m.content === "active prompt")));
  const removed = await json(`/sessions/${id}/prompt`, "POST", { text: "remove this", delivery: "queue" });
  const retained = await json(`/sessions/${id}/prompt`, "POST", { text: "retain this", delivery: "queue" });
  await json(`/sessions/${id}/inbox/${removed.inboxId}`, "DELETE");
  const snapshot = await json(`/sessions/${id}`);
  expect(snapshot.running).toBe(true);
  expect(snapshot.inbox.map((item: any) => item.id)).toContain(retained.inboxId);
  expect(snapshot.inbox.map((item: any) => item.id)).not.toContain(removed.inboxId);
  await json(`/sessions/${id}/abort`, "POST", {});
  expect(llm.requests.some((r) => JSON.stringify(r.messages).includes("remove this"))).toBe(false);
});

test("queued inputs each run as their own follow-up turn", async () => {
  const id = await boot();
  let release!: () => void;
  const paused = new Promise<void>((resolve) => { release = resolve; });
  llm.reply({ text: "active", chunks: 2, afterFirstChunk: paused }, { text: "first answer" }, { text: "second answer" });
  const before = llm.requests.length;
  try {
    await json(`/sessions/${id}/prompt`, "POST", { text: "active prompt" });
    await waitFor(() => llm.requests.length > before);
    await json(`/sessions/${id}/prompt`, "POST", { text: "first follow-up", delivery: "queue" });
    await json(`/sessions/${id}/prompt`, "POST", { text: "second follow-up", delivery: "queue" });
  } finally { release(); }
  await waitFor(async () => !(await json(`/sessions/${id}`)).running);
  const lastUser = (r: any) => r.messages.filter((m: any) => m.role === "user").at(-1)?.content;
  expect(llm.requests.slice(before).map(lastUser)).toEqual(["active prompt", "first follow-up", "second follow-up"]);
});

test("aborting a tool-call stream leaves every call paired for the next run", async () => {
  const id = await boot();
  let release!: () => void;
  const paused = new Promise<void>((resolve) => { release = resolve; });
  llm.reply({ calls: [{ id: "orphan", name: "missing_tool", args: {} }], afterFirstChunk: paused });
  try {
    await json(`/sessions/${id}/prompt`, "POST", { text: "start a tool" });
    await waitFor(async () => (await json(`/sessions/${id}`)).inflight?.content?.some((c: any) => c.type === "toolCall"), "streamed tool call");
    await json(`/sessions/${id}/abort`, "POST", {});
  } finally { release(); }
  const messages = (await json(`/sessions/${id}`)).messages;
  const assistant = messages.findLast((m: any) => m.role === "assistant");
  expect(assistant.stopReason).toBe("aborted");
  const result = messages.find((m: any) => m.toolCallId === "orphan");
  expect(result.isError).toBe(true);
  llm.reply({ text: "resumed" });
  await json(`/sessions/${id}/prompt`, "POST", { text: "carry on" });
  await waitFor(async () => !(await json(`/sessions/${id}`)).running);
  const replayed = llm.requests.at(-1).messages;
  const call = replayed.findIndex((m: any) => m.tool_calls?.some((c: any) => c.id === "orphan"));
  expect(call).toBeGreaterThan(-1);
  expect(replayed[call + 1]).toMatchObject({ role: "tool", tool_call_id: "orphan" });
});

test("images are capability checked and persist as provider-compatible content", async () => {
  const id = await boot();
  const image = { mimeType: "image/png", data: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2nAAAAABJRU5ErkJggg==" };
  expect((await sb.api(`/sessions/${id}/prompt`, "POST", { text: "look", images: [image] })).status).toBe(400);
  sb.writeConfig({ model: "fake/vision", provider: { fake: { options: { baseURL: llm.baseURL }, models: { vision: { name: "Vision", attachment: true, modalities: { input: ["text", "image"] } } } } } });
  llm.reply({ text: "one pixel" });
  await json(`/sessions/${id}/prompt`, "POST", { text: "look", images: [image] });
  await waitFor(async () => !(await json(`/sessions/${id}`)).running);
  const content = llm.requests.at(-1)?.messages.at(-1)?.content;
  expect(content).toEqual([{ type: "text", text: "look" }, { type: "image_url", image_url: { url: `data:image/png;base64,${image.data}` } }]);
  const saved = await json(`/sessions/${id}`);
  expect(saved.messages.find((m: any) => m.role === "user").content[1]).toEqual({ type: "image", ...image });
  expect((await sb.api(`/sessions/${id}/prompt`, "POST", { text: "bad image", images: [{ ...image, data: "broken!==" }] })).status).toBe(400);

  // Back on a text-only model, the earlier image becomes a visible placeholder.
  sb.writeConfig({ model: "fake/base", provider: { fake: { options: { baseURL: llm.baseURL } } } });
  llm.reply({ text: "text only" });
  await json(`/sessions/${id}/prompt`, "POST", { text: "and now?" });
  await waitFor(async () => !(await json(`/sessions/${id}`)).running);
  const replayed = JSON.stringify(llm.requests.at(-1)?.messages);
  expect(replayed).toContain("this model does not support image input");
  expect(replayed).not.toContain(image.data);
  const last = (await json(`/sessions/${id}`)).messages.at(-1);
  expect(last.stopReason).toBe("stop");
});

test("generated titles use small_model and preserve manual titles", async () => {
  sb.writeConfig({ model: "fake/base", small_model: "fake/title-model", provider: { fake: { options: { baseURL: llm.baseURL } } } });
  const id = await boot();
  llm.reply({ text: "first reply" });
  await json(`/sessions/${id}/prompt`, "POST", { text: "Explain the editor" });
  await waitFor(async () => !(await json(`/sessions/${id}`)).running);
  await json(`/sessions/${id}/title`, "POST", {});
  await waitFor(async () => (await json(`/sessions/${id}`)).info.title === "Test conversation", "generated title");
  expect(llm.titleRequests.at(-1)?.model).toBe("title-model");
  await json(`/sessions/${id}`, "PATCH", { title: "My chosen title" });
  await json(`/sessions/${id}/title`, "POST", {});
  expect((await json(`/sessions/${id}`)).info.title).toBe("My chosen title");
});

test("interactive model selection agrees with config inspection despite an initial environment override", async () => {
  await boot();
  const { id } = await json("/sessions", "POST", { location: sb.project, environment: { model: "fake/from-env" } });
  await json(`/sessions/${id}`, "PATCH", { model: "fake/selected" });
  expect((await json(`/config?session=${id}`)).config.model).toBe("fake/selected");
  llm.reply({ text: "selected response" });
  await json(`/sessions/${id}/prompt`, "POST", { text: "which model" });
  await waitFor(async () => !(await json(`/sessions/${id}`)).running);
  expect(llm.requests.at(-1)?.model).toBe("selected");
});

test("a next-run vision model does not admit images into an active text-only run", async () => {
  sb.writeConfig({ model: "fake/base", provider: { fake: { options: { baseURL: llm.baseURL }, models: { vision: { attachment: true } } } } });
  const id = await boot();
  let release!: () => void;
  const paused = new Promise<void>((resolve) => { release = resolve; });
  llm.reply({ text: "slow text reply", chunks: 2, afterFirstChunk: paused });
  try {
    await json(`/sessions/${id}/prompt`, "POST", { text: "still on text model" });
    await waitFor(() => llm.requests.some((r) => r.messages.some((m: any) => m.content === "still on text model")));
    await json(`/sessions/${id}`, "PATCH", { model: "fake/vision" });
    const response = await sb.api(`/sessions/${id}/prompt`, "POST", { text: "image follow-up", images: [{ mimeType: "image/png", data: "YWJj" }] });
    expect(response.status).toBe(400);
    const snapshot = await json(`/sessions/${id}`);
    expect(snapshot.inbox).toHaveLength(0);
    expect(snapshot.messages.some((m: any) => JSON.stringify(m).includes("image follow-up"))).toBe(false);
  } finally { release(); }
});
