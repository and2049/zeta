import { afterEach, beforeEach, expect, test } from "bun:test";
import { Sandbox } from "./harness";

// A scripted Anthropic Messages server: each request pops the next list of
// SSE events. Title requests get a fixed title.
class FakeAnthropic {
  requests: any[] = [];
  headers: Headers[] = [];
  script: object[][] = [];
  server = Bun.serve({ port: 0, hostname: "127.0.0.1", fetch: (req) => this.handle(req) });

  get baseURL() {
    return `http://127.0.0.1:${this.server.port}/v1`;
  }

  private async handle(req: Request): Promise<Response> {
    if (req.method !== "POST" || new URL(req.url).pathname !== "/v1/messages") return new Response("not found", { status: 404 });
    const body: any = await req.json();
    const title = body.system?.[0]?.text?.startsWith("Generate a short session title");
    if (!title) {
      this.requests.push(body);
      this.headers.push(req.headers);
    }
    const events = title ? reply([text(0, "Title")], "end_turn") : this.script.shift() ?? reply([text(0, "(script exhausted)")], "end_turn");
    const sse = events.map((e: any) => `event: ${e.type}\ndata: ${JSON.stringify(e)}\n\n`).join("");
    return new Response(sse, { headers: { "content-type": "text/event-stream" } });
  }
}

function text(index: number, value: string): object[] {
  return [
    { type: "content_block_start", index, content_block: { type: "text", text: "" } },
    { type: "content_block_delta", index, delta: { type: "text_delta", text: value } },
    { type: "content_block_stop", index },
  ];
}

function toolUse(index: number, id: string, name: string, input: object): object[] {
  const json = JSON.stringify(input);
  return [
    { type: "content_block_start", index, content_block: { type: "tool_use", id, name, input: {} } },
    { type: "content_block_delta", index, delta: { type: "input_json_delta", partial_json: json.slice(0, 5) } },
    { type: "content_block_delta", index, delta: { type: "input_json_delta", partial_json: json.slice(5) } },
    { type: "content_block_stop", index },
  ];
}

function reply(blocks: object[][], stop: string): object[] {
  return [
    { type: "message_start", message: { usage: { input_tokens: 12, cache_read_input_tokens: 30, cache_creation_input_tokens: 4, output_tokens: 1 } } },
    ...blocks.flat(),
    { type: "message_delta", delta: { stop_reason: stop }, usage: { output_tokens: 7 } },
    { type: "message_stop" },
  ];
}

let sb: Sandbox;
let llm: FakeAnthropic;

beforeEach(() => {
  sb = new Sandbox();
  llm = new FakeAnthropic();
  sb.writeConfig({ model: "anthropic/claude-test", provider: { anthropic: { options: { baseURL: llm.baseURL, apiKey: "sk-ant-e2e" } } } });
});

afterEach(async () => {
  await sb.cleanup();
  llm.server.stop(true);
});

async function prompt(text: string): Promise<string> {
  await sb.start();
  const session = (await (await sb.api("/sessions", "POST", { location: sb.project })).json()).id;
  await sb.api(`/sessions/${session}/prompt`, "POST", { text });
  for (let i = 0; i < 200; i++) {
    const state = await (await sb.api(`/sessions/${session}`)).json();
    if (!state.running && state.messages.length >= 2) return session;
    await Bun.sleep(20);
  }
  throw new Error("timed out waiting for reply");
}

test("a run with a tool call goes through the Messages API", async () => {
  llm.script.push(
    reply([text(0, "Checking."), toolUse(1, "toolu_1", "missing_tool", {})], "tool_use"),
    reply([text(0, "It is missing.")], "end_turn"),
  );
  const session = await prompt("look at missing.txt");
  expect(JSON.stringify((await (await sb.api(`/sessions/${session}/messages`)).json()).messages)).toContain("It is missing.");

  expect(llm.requests.length).toBe(2);
  expect(llm.headers[0].get("x-api-key")).toBe("sk-ant-e2e");
  expect(llm.headers[0].get("anthropic-version")).toBe("2023-06-01");
  expect(llm.headers[0].get("authorization")).toBeNull();
  const first = llm.requests[0];
  expect(first.model).toBe("claude-test");
  expect(first.stream).toBe(true);
  expect(first.max_tokens).toBe(8192);
  expect(first.system[0].cache_control).toEqual({ type: "ephemeral" });
  expect(first.tools ?? []).toEqual([]);

  // The second request replays the call and carries its result in a user turn.
  const [user, assistant, results] = llm.requests[1].messages;
  expect(user.role).toBe("user");
  expect(assistant.role).toBe("assistant");
  expect(assistant.content.map((b: any) => b.type)).toEqual(["text", "tool_use"]);
  expect(assistant.content[1]).toEqual({ type: "tool_use", id: "toolu_1", name: "missing_tool", input: {} });
  expect(results.role).toBe("user");
  expect(results.content[0].type).toBe("tool_result");
  expect(results.content[0].tool_use_id).toBe("toolu_1");
  expect(results.content[0].is_error).toBe(true);
  expect(results.content.at(-1).cache_control).toEqual({ type: "ephemeral" });

  const log = (await (await sb.api(`/sessions/${session}/messages`)).json()).messages;
  const last = log.at(-1);
  expect(last.stopReason).toBe("stop");
  expect(last.usage).toEqual({ input: 12, output: 7, cacheRead: 30, cacheWrite: 4 });
});

test("an HTTP error from the API is reported with its message", async () => {
  llm.server.stop(true);
  const failing = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    fetch: () => Response.json({ type: "error", error: { type: "invalid_request_error", message: "max_tokens: too large" } }, { status: 400 }),
  });
  sb.writeConfig({ model: "anthropic/claude-test", provider: { anthropic: { options: { baseURL: `http://127.0.0.1:${failing.port}/v1`, apiKey: "sk-ant-e2e" } } } });
  const session = await prompt("hi");
  failing.stop(true);
  expect(JSON.stringify((await (await sb.api(`/sessions/${session}/messages`)).json()).messages)).toContain("HTTP 400: max_tokens: too large");
});
