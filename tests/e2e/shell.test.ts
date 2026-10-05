import { afterEach, beforeEach, expect, test } from "bun:test";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { Sandbox } from "./harness";
import { FakeOpenAI } from "./fake-openai";
import { waitFor } from "./tui-harness";

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
  llm.requests.length = 0;
  return (await json("/sessions", "POST", { location: sb.project })).id as string;
}
const shells = (state: any) => state.messages.filter((m: any) => m.origin === "shell");

test("a shell command is recorded without a turn and the next prompt carries it", async () => {
  const id = await boot();
  writeFileSync(join(sb.project, "marker.txt"), "x");
  const started = await json(`/sessions/${id}/shell`, "POST", { command: "ls; echo oops >&2; exit 3" });
  await waitFor(async () => shells(await json(`/sessions/${id}`)).length === 1, "recorded command");
  const state = await json(`/sessions/${id}`);
  const message = shells(state)[0];
  expect(message.id).toBe(started.id);
  expect(message.role).toBe("user");
  expect(message.isError).toBe(true);
  expect(message.content[0].text).toBe("ls; echo oops >&2; exit 3");
  expect(message.content[1].text).toBe("marker.txt\noops\nCommand exited with code 3");
  expect(state.running).toBe(false);
  expect(state.shell ?? null).toBeNull();
  await Bun.sleep(200);
  expect(llm.requests).toHaveLength(0);

  llm.reply({ text: "seen" });
  await json(`/sessions/${id}/prompt`, "POST", { text: "what did I run?" });
  await waitFor(async () => llm.requests.length === 1 && !(await json(`/sessions/${id}`)).running, "turn");
  const sent = llm.requests[0].messages.filter((m: any) => m.role === "user").map((m: any) => typeof m.content === "string" ? m.content : JSON.stringify(m.content));
  expect(sent).toHaveLength(2);
  expect(sent[0]).toContain("The user ran a shell command themselves");
  expect(sent[0]).toContain("Command:\nls; echo oops >&2; exit 3\n\nOutput:\nmarker.txt\noops");
  expect(sent[1]).toBe("what did I run?");

  expect((await sb.api(`/sessions/${id}/shell`, "POST", { command: "  " })).status).toBe(400);
  expect((await sb.api(`/sessions/ses_missing/shell`, "POST", { command: "ls" })).status).toBe(404);
  expect((await sb.api(`/sessions/${id}/shell`, "DELETE")).status).toBe(404);
}, 20000);

test("a command run during a turn joins that turn at its next step", async () => {
  const id = await boot();
  let release!: () => void;
  const held = new Promise<void>((resolve) => { release = resolve; });
  // The first reply waits, then calls a tool; the command's output must be
  // in the request that follows the tool result.
  llm.reply({ calls: [{ id: "c1", name: "bash", args: { command: "true" } }], afterFirstChunk: held }, { text: "done" });
  await json(`/sessions/${id}/prompt`, "POST", { text: "work" });
  await waitFor(() => llm.requests.length === 1, "first request");
  await json(`/sessions/${id}/shell`, "POST", { command: "echo MIDTURN" });
  await waitFor(async () => (await json(`/sessions/${id}`)).inbox.some((item: any) => item.kind === "shell"), "result waiting");
  release();
  await waitFor(async () => llm.requests.length === 2 && !(await json(`/sessions/${id}`)).running, "turn end");
  expect(JSON.stringify(llm.requests[1].messages)).toContain("Command:\\necho MIDTURN\\n\\nOutput:\\nMIDTURN");
  const state = await json(`/sessions/${id}`);
  expect(state.inbox).toHaveLength(0);
  expect(state.messages.map((m: any) => m.origin ?? m.role)).toEqual(["user", "assistant", "tool_result", "shell", "assistant"]);
  await Bun.sleep(200);
  expect(llm.requests).toHaveLength(2);
}, 20000);

test("one command runs at a time and stopping keeps its output", async () => {
  const id = await boot();
  await json(`/sessions/${id}/shell`, "POST", { command: "echo first; sleep 30; echo never" });
  await waitFor(async () => (await json(`/sessions/${id}`)).shell?.command.startsWith("echo first"), "running command in the snapshot");
  expect((await sb.api(`/sessions/${id}/shell`, "POST", { command: "ls" })).status).toBe(409);
  await Bun.sleep(200);
  await json(`/sessions/${id}/shell`, "DELETE");
  await waitFor(async () => shells(await json(`/sessions/${id}`)).length === 1, "stopped command recorded");
  const state = await json(`/sessions/${id}`);
  expect(shells(state)[0].content[1].text).toBe("first\nStopped by the user");
  expect(shells(state)[0].isError).toBe(true);
  expect(state.shell ?? null).toBeNull();
  await json(`/sessions/${id}/shell`, "POST", { command: "echo again" });
  await waitFor(async () => shells(await json(`/sessions/${id}`)).length === 2, "next command");
}, 20000);
