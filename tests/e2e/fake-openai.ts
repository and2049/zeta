// A scripted OpenAI-compatible chat completions server.
// Each request pops the next reply from the script; requests are recorded.

export type ToolCall = { id: string; name: string; args: string | Record<string, unknown>; chunks?: number };
export type Reply =
  | { text: string; reasoning?: string; chunks?: number; delayMs?: number; afterFirstChunk?: Promise<void>; gzip?: boolean }
  | { calls: ToolCall[]; text?: string; finish_reason?: "tool_calls" | "length"; afterFirstChunk?: Promise<void> }
  | { status: number; body: string };

export class FakeOpenAI {
  requests: any[] = [];
  titleRequests: any[] = [];
  headers: Headers[] = [];
  private script: Reply[] = [];
  private server: ReturnType<typeof Bun.serve>;

  constructor() {
    this.server = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch: (req) => this.handle(req),
    });
  }

  get baseURL() {
    return `http://127.0.0.1:${this.server.port}/v1`;
  }

  reply(...replies: Reply[]) {
    this.script.push(...replies);
  }

  stop() {
    this.server.stop(true);
  }

  private async handle(req: Request): Promise<Response> {
    const url = new URL(req.url);
    if (req.method !== "POST" || url.pathname !== "/v1/chat/completions") {
      return new Response("not found", { status: 404 });
    }
    const request: any = await req.json();
    const title = request.messages?.some((message: any) => message.role === "system" && typeof message.content === "string" && message.content.startsWith("Generate a short session title"));
    if (title) this.titleRequests.push(request);
    else { this.requests.push(request); this.headers.push(req.headers); }
    const next: Reply = title ? { text: "Test conversation" } : this.script.shift() ?? { text: "(script exhausted)" };
    if ("status" in next) return new Response(next.body, { status: next.status });
    if ("delayMs" in next && next.delayMs) await Bun.sleep(next.delayMs);

    const frames: object[] = [];
    if ("reasoning" in next && next.reasoning) frames.push({ choices: [{ index: 0, delta: { reasoning_content: next.reasoning } }] });
    if ("calls" in next) {
      if (next.text) frames.push({ choices: [{ index: 0, delta: { role: "assistant", content: next.text } }] });
      for (const [index, call] of next.calls.entries()) {
        frames.push({ choices: [{ index: 0, delta: { tool_calls: [{ index, id: call.id, type: "function", function: { name: call.name, arguments: "" } }] } }] });
        const args = typeof call.args === "string" ? call.args : JSON.stringify(call.args);
        for (const argumentsChunk of split(args, call.chunks ?? 3)) {
          frames.push({ choices: [{ index: 0, delta: { tool_calls: [{ index, function: { arguments: argumentsChunk } }] } }] });
        }
      }
      frames.push({ choices: [{ index: 0, delta: {}, finish_reason: next.finish_reason ?? "tool_calls" }] });
    } else {
      const pieces = split(next.text, next.chunks ?? 3);
      for (const [i, content] of pieces.entries()) {
        frames.push({ choices: [{ index: 0, delta: i === 0 ? { role: "assistant", content } : { content } }] });
      }
      frames.push({ choices: [{ index: 0, delta: {}, finish_reason: "stop" }] });
    }
    frames.push({ choices: [], usage: { prompt_tokens: 10, completion_tokens: frames.length } });
    const lines = frames.map((f) => `data: ${JSON.stringify(f)}\n\n`);
    lines.push("data: [DONE]\n\n");
    if ("gzip" in next && next.gzip) {
      // Sent even though the client asked for identity, like a misbehaving proxy.
      return new Response(Bun.gzipSync(lines.join("")), { headers: { "content-type": "text/event-stream", "content-encoding": "gzip" } });
    }
    if (!("afterFirstChunk" in next) || !next.afterFirstChunk) {
      return new Response(lines.join(""), { headers: { "content-type": "text/event-stream" } });
    }
    const pause = next.afterFirstChunk;
    const body = new ReadableStream({
      async start(controller) {
        const encoder = new TextEncoder();
        controller.enqueue(encoder.encode(lines[0]));
        await pause;
        for (const line of lines.slice(1)) controller.enqueue(encoder.encode(line));
        controller.close();
      },
    });
    return new Response(body, { headers: { "content-type": "text/event-stream" } });
  }
}

function split(text: string, n: number): string[] {
  const size = Math.max(1, Math.ceil(text.length / n));
  const out: string[] = [];
  for (let i = 0; i < text.length; i += size) out.push(text.slice(i, i + size));
  return out.length ? out : [""];
}
