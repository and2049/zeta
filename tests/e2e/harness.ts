// Runs the real zeta binary in an isolated HOME / XDG layout.

import { mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { waitFor } from "./wait-for";

export const zetaBin = process.env.ZETA_BIN ?? resolve(import.meta.dir, "../../zig-out/bin/zeta");

export type LogMessage = {
  id?: string;
  role: string;
  content: Array<{ type: string; text?: string; id?: string; name?: string; arguments?: unknown }>;
  toolCallId?: string;
  toolName?: string;
  isError?: boolean;
  stopReason?: string;
};
export type AgentEvent = {
  type: string;
  data: { message?: LogMessage; toolCallId?: string; toolName?: string; result?: { content: Array<{ text: string }> }; isError?: boolean; args?: string };
  session: string;
  seq: number;
};
export function jsonEvents(stdout: string): AgentEvent[] {
  return stdout.trim().split("\n").filter(Boolean).map((line) => JSON.parse(line) as AgentEvent);
}

export class Sandbox {
  server?: ReturnType<typeof Bun.spawn>;
  root = mkdtempSync(join(tmpdir(), "zeta-e2e-"));
  home = join(this.root, "home");
  project = join(this.root, "project");
  env: Record<string, string> = {
    PATH: process.env.PATH ?? "/usr/bin:/bin",
    HOME: this.home,
    XDG_CONFIG_HOME: join(this.home, ".config"),
    XDG_DATA_HOME: join(this.home, ".local/share"),
    XDG_STATE_HOME: join(this.home, ".local/state"),
    XDG_CACHE_HOME: join(this.home, ".cache"),
    XDG_RUNTIME_DIR: join(this.root, "run"),
  };

  constructor() {
    mkdirSync(this.project, { recursive: true });
    mkdirSync(join(this.root, "run"), { recursive: true, mode: 0o700 });
  }

  get discoveryPath() {
    return join(this.env.XDG_RUNTIME_DIR, "zeta", "server.json");
  }

  discovery(): { url: string; pid: number; version: string; password: string } {
    return JSON.parse(readFileSync(this.discoveryPath, "utf8"));
  }

  writeConfig(config: unknown) {
    const dir = join(this.env.XDG_CONFIG_HOME, "zeta");
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "zeta.jsonc"), JSON.stringify(config, null, 2));
  }

  /** Persisted JSONL messages for the one session created by a test. */
  sessionMessages(): LogMessage[] {
    const dir = join(this.env.XDG_DATA_HOME, "zeta", "sessions");
    if (!existsSync(dir)) return [];
    const files = readdirSync(dir, { recursive: true }).filter((file) => String(file).endsWith(".jsonl"));
    if (files.length === 0) return [];
    if (files.length !== 1) throw new Error(`Expected one session log, got ${files.length}`);
    return readFileSync(join(dir, String(files[0])), "utf8").trim().split("\n")
      .map((line) => JSON.parse(line) as { type: string; message?: LogMessage })
      .filter((entry) => entry.type === "message")
      .map((entry) => entry.message!);
  }

  async zeta(args: string[], extraEnv: Record<string, string> = {}, cwd = this.project) {
    const proc = Bun.spawn([zetaBin, ...args], {
      cwd,
      env: { ...this.env, ...extraEnv },
      stdout: "pipe",
      stderr: "pipe",
    });
    const [stdout, stderr, code] = await Promise.all([
      new Response(proc.stdout).text(),
      new Response(proc.stderr).text(),
      proc.exited,
    ]);
    return { stdout, stderr, code };
  }

  async start(hostname?: string) {
    this.server = Bun.spawn([zetaBin, "serve", ...(hostname ? ["--hostname", hostname] : [])], {
      cwd: this.project, env: this.env, stdout: "ignore", stderr: "ignore",
    });
    await waitFor(() => existsSync(this.discoveryPath), "server discovery");
  }

  async stop() {
    if (existsSync(this.discoveryPath)) await this.api("/server/stop", "POST", {});
    if (this.server) {
      await this.server.exited;
      this.server = undefined;
    }
  }

  /** Authenticated request to the daemon discovered in this sandbox. */
  api(path: string, method = "GET", body?: unknown): Promise<Response> {
    const { url, password } = this.discovery();
    return fetch(`${url}${path}`, {
      method,
      headers: {
        authorization: `Basic ${btoa(`zeta:${password}`)}`,
        ...(body === undefined ? {} : { "content-type": "application/json" }),
      },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
      signal: AbortSignal.timeout(10_000),
    });
  }

  /** Stops the server and removes the sandbox. */
  async cleanup() {
    if (existsSync(this.discoveryPath)) {
      const { pid } = this.discovery();
      try {
        process.kill(pid, "SIGTERM");
      } catch {}
      for (let i = 0; i < 50 && existsSync(this.discoveryPath); i++) await Bun.sleep(10);
    }
    if (this.server) await this.server.exited;
    rmSync(this.root, { recursive: true, force: true });
  }
}
