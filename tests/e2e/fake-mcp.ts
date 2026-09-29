// A small MCP server for tests, over stdio (default) or Streamable HTTP
// (`--http`, prints the URL on its first stdout line).
// Tools: echo {text} (read-only), add {a, b}, fail {}; `grow` adds a tool
// named `extra` and sends notifications/tools/list_changed. Prompts: review
// {file, focus?}, and `roots` (over stdio: the roots zeta answered with).
// With --instructions the server hands out instructions.

type Message = { jsonrpc: "2.0"; id?: number | string; method?: string; params?: any; result?: unknown };

const tools: any[] = [
  { name: "echo", description: "Echo text back", annotations: { readOnlyHint: true }, inputSchema: { type: "object", properties: { text: { type: "string", format: "plain" } }, required: ["text"] } },
  { name: "add", description: "Add two numbers", inputSchema: { type: "object", properties: { a: { type: "number" }, b: { type: "number" } }, required: ["a", "b"] } },
  { name: "fail", description: "Always fails", inputSchema: { type: "object" } },
  { name: "grow", description: "Adds a tool", inputSchema: { type: "object" } },
];

let roots: unknown = null;
// With --ask, the tool `ask` puts a question to the user (elicitation) and
// returns the answer.
if (process.argv.includes("--ask")) {
  tools.push({ name: "ask", description: "Ask the user", inputSchema: { type: "object" } });
  tools.push({ name: "ask_url", description: "Ask the user to visit a URL", inputSchema: { type: "object" } });
  tools.push({ name: "ask_then_cancel", description: "Ask, then take the question back", inputSchema: { type: "object" } });
}
// Whether a reply ever came for a question this server cancelled.
let cancelledReplied = false;
let asking: number | string | undefined;
const prompts = [
  { name: "review", description: "Review a file", arguments: [{ name: "file", required: true }, { name: "focus" }] },
  { name: "roots", description: "The client's roots" },
];

function handle(message: Message, notify: (m: Message) => void): Message | null {
  if (message.id === "roots-1" && message.method === undefined) {
    roots = message.result;
    return null;
  }
  if (message.id === "eli-2" && message.method === undefined) {
    cancelledReplied = true;
    return null;
  }
  if (message.id === "eli-1" && message.method === undefined) {
    const call = asking;
    asking = undefined;
    const answer = message.result ?? { error: (message as any).error };
    return { jsonrpc: "2.0", id: call, result: { content: [{ type: "text", text: JSON.stringify(answer) }] } };
  }
  if (message.method === "notifications/initialized") notify({ jsonrpc: "2.0", id: "roots-1", method: "roots/list" });
  if (message.id === undefined) return null;
  const reply = (result: unknown): Message => ({ jsonrpc: "2.0", id: message.id, result });
  switch (message.method) {
    case "initialize":
      return reply({
        protocolVersion: message.params?.protocolVersion ?? "2025-11-25",
        capabilities: process.argv.includes("--prompts-only") ? { prompts: {} } : { tools: { listChanged: true }, prompts: {} },
        serverInfo: { name: "fake", version: "1" },
        ...(process.argv.includes("--instructions") ? { instructions: "Prefer echo for greetings." } : {}),
      });
    case "tools/list":
      if (process.argv.includes("--prompts-only")) return { jsonrpc: "2.0", id: message.id, error: { code: -32601, message: "Method not found" } } as Message;
      return reply({ tools });
    case "prompts/list":
      if (process.argv.includes("--prompts-broken")) return { jsonrpc: "2.0", id: message.id, error: { code: -32603, message: "prompts are down" } } as Message;
      return reply({ prompts });
    case "prompts/get": {
      const { name, arguments: args } = message.params;
      if (name === "review" && !args.file) return { jsonrpc: "2.0", id: message.id, error: { code: -32602, message: "file is required" } } as Message;
      const text = name === "roots" ? JSON.stringify(roots) : `Review ${args.file} focusing on ${args.focus || "anything"}.`;
      return reply({ messages: [{ role: "user", content: { type: "text", text } }] });
    }
    case "tools/call": {
      const { name, arguments: args } = message.params;
      if (name === "echo") return reply({ content: [{ type: "text", text: args.text }] });
      if (name === "add") return reply({ content: [], structuredContent: { sum: args.a + args.b } });
      if (name === "fail") return reply({ content: [{ type: "text", text: "it broke" }], isError: true });
      if (name === "grow") {
        if (!tools.some((t) => t.name === "extra")) tools.push({ name: "extra", description: "Added later", inputSchema: { type: "object" } });
        notify({ jsonrpc: "2.0", method: "notifications/tools/list_changed" });
        return reply({ content: [{ type: "text", text: "grown" }] });
      }
      if (name === "extra") return reply({ content: [{ type: "text", text: "extra ran" }] });
      if (name === "ask_url") {
        asking = message.id;
        notify({ jsonrpc: "2.0", id: "eli-1", method: "elicitation/create", params: { mode: "url", message: "Visit", url: "https://example.test", elicitationId: "e" } });
        return null;
      }
      if (name === "ask_then_cancel") {
        const call = message.id;
        notify({ jsonrpc: "2.0", id: "eli-2", method: "elicitation/create", params: { message: "Never mind?", requestedSchema: { type: "object", properties: {} } } });
        setTimeout(() => {
          notify({ jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: "eli-2", reason: "changed my mind" } });
          setTimeout(() => notify({ jsonrpc: "2.0", id: call, result: { content: [{ type: "text", text: `replied: ${cancelledReplied}` }] } }), 200);
        }, 300);
        return null;
      }
      if (name === "ask") {
        asking = message.id;
        notify({ jsonrpc: "2.0", id: "eli-1", method: "elicitation/create", params: { message: "Which branch?", requestedSchema: { type: "object", properties: { branch: { type: "string" } }, required: ["branch"] } } });
        return null;
      }
      return { jsonrpc: "2.0", id: message.id, error: { code: -32602, message: `unknown tool ${name}` } } as Message;
    }
    default:
      return { jsonrpc: "2.0", id: message.id, error: { code: -32601, message: "Method not found" } } as Message;
  }
}

if (process.argv.includes("--http")) {
  const session = crypto.randomUUID();
  let expired = false;
  // With --expire-after N, the session is forgotten after N tool calls.
  const expireAt = process.argv.includes("--expire-after") ? Number(process.argv[process.argv.indexOf("--expire-after") + 1]) : Infinity;
  let calls = 0;
  // With --oauth, /mcp needs a bearer token from the built-in authorization
  // server at /as (dynamic registration, PKCE, refresh). The first token
  // issued stops working after one tool call, so it has to be refreshed.
  const oauth = process.argv.includes("--oauth");
  let challenge = "";
  let issued = 0;
  const valid = new Set<string>();
  // With --revoke-after N, every token and the refresh token stop working
  // after N tool calls.
  const revokeAt = process.argv.includes("--revoke-after") ? Number(process.argv[process.argv.indexOf("--revoke-after") + 1]) : Infinity;
  let revoked = false;
  const server = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    async fetch(req) {
      const url = new URL(req.url);
      const base = `http://127.0.0.1:${server.port}`;
      if (oauth && url.pathname !== "/mcp") {
        if (url.pathname === "/.well-known/oauth-protected-resource/mcp") return Response.json({ resource: `${base}/mcp`, authorization_servers: [`${base}/as`] });
        if (url.pathname === "/.well-known/oauth-authorization-server/as")
          return Response.json({
            issuer: `${base}/as`,
            authorization_endpoint: `${base}/as/authorize`,
            token_endpoint: `${base}/as/token`,
            registration_endpoint: `${base}/as/register`,
            ...(process.argv.includes("--no-pkce") ? {} : { code_challenge_methods_supported: ["S256"] }),
          });
        if (url.pathname === "/as/register") return Response.json({ client_id: "fake-client" }, { status: 201 });
        if (url.pathname === "/as/authorize") {
          challenge = url.searchParams.get("code_challenge") ?? "";
          if (url.searchParams.get("resource") !== `${base}/mcp`) return new Response("wrong resource", { status: 400 });
          const back = new URL(url.searchParams.get("redirect_uri")!);
          back.searchParams.set("code", "the-code");
          back.searchParams.set("state", url.searchParams.get("state")!);
          return Response.redirect(back.toString(), 302);
        }
        if (url.pathname === "/as/token") {
          const form = new URLSearchParams(await req.text());
          if (form.get("resource") !== `${base}/mcp`) return new Response("wrong resource", { status: 400 });
          if (form.get("grant_type") === "authorization_code") {
            const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(form.get("code_verifier") ?? "")));
            const expected = Buffer.from(digest).toString("base64url");
            if (form.get("code") !== "the-code" || expected !== challenge) return new Response("bad grant", { status: 400 });
          } else if (form.get("refresh_token") !== "the-refresh" || revoked) return new Response("bad refresh", { status: 400 });
          const token = `token-${++issued}`;
          valid.add(token);
          return Response.json({ access_token: token, refresh_token: "the-refresh", expires_in: 3600, token_type: "Bearer" });
        }
        return new Response("not found", { status: 404 });
      }
      if (oauth) {
        const token = (req.headers.get("authorization") ?? "").replace(/^Bearer /, "");
        if (!valid.has(token))
          return new Response("unauthorized", { status: 401, headers: { "www-authenticate": `Bearer resource_metadata="${base}/.well-known/oauth-protected-resource/mcp"` } });
      }
      if (req.method === "DELETE") return new Response(null, { status: 204 });
      const message = (await req.json()) as Message;
      if (message.method !== "initialize" && (expired || req.headers.get("mcp-session-id") !== session)) return new Response("unknown session", { status: 404 });
      if (message.method === "tools/call" && ++calls >= expireAt) expired = true;
      if (oauth && message.method === "tools/call") {
        valid.delete("token-1");
        if (calls >= revokeAt) {
          revoked = true;
          valid.clear();
        }
      }
      const queued: Message[] = [];
      const reply = handle(message, (m) => queued.push(m));
      if (!reply) return new Response(null, { status: 202 });
      // Tool calls answer as an event stream; everything else as JSON.
      if (message.method === "tools/call") {
        const body = [...queued, reply].map((m) => `event: message\ndata: ${JSON.stringify(m)}\n\n`).join("");
        if (process.argv.includes("--hold-open")) {
          // Send the answer, then keep the stream open.
          const stream = new ReadableStream({ start(controller) { controller.enqueue(new TextEncoder().encode(body)); } });
          return new Response(stream, { headers: { "content-type": "text/event-stream", "mcp-session-id": session } });
        }
        return new Response(body, { headers: { "content-type": "text/event-stream", "mcp-session-id": session } });
      }
      return Response.json(reply, { headers: { "mcp-session-id": session } });
    },
  });
  console.log(`http://127.0.0.1:${server.port}/mcp`);
} else {
  const write = (m: Message) => process.stdout.write(`${JSON.stringify(m)}\n`);
  console.error("fake mcp ready");
  let buffer = "";
  for await (const chunk of Bun.stdin.stream()) {
    buffer += new TextDecoder().decode(chunk);
    let end: number;
    while ((end = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, end).trim();
      buffer = buffer.slice(end + 1);
      if (!line) continue;
      const reply = handle(JSON.parse(line), write);
      if (reply) write(reply);
    }
  }
}
