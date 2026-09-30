// Real PTY, using Bun's built-in terminal support (no tmux dependency).
import { Sandbox, zetaBin } from "./harness";

export async function waitFor(check: () => boolean | Promise<boolean>, label = "condition") {
  for (let i = 0; i < 250; i++) {
    if (await check()) return;
    await Bun.sleep(20);
  }
  throw new Error(`Timed out waiting for ${label}`);
}

export class Tui {
  output = "";
  terminal: Bun.Terminal;
  process: ReturnType<typeof Bun.spawn>;
  original: number[];

  constructor(sb: Sandbox) {
    const decoder = new TextDecoder();
    this.terminal = new Bun.Terminal({
      cols: 90, rows: 28,
      data: (_terminal, bytes) => { this.output += decoder.decode(bytes, { stream: true }); },
    });
    this.original = this.flags();
    this.process = Bun.spawn([zetaBin], {
      cwd: sb.project, env: { ...sb.env, TERM: "xterm-256color" }, terminal: this.terminal,
    });
  }

  flags() { return [this.terminal.inputFlags, this.terminal.outputFlags, this.terminal.localFlags, this.terminal.controlFlags]; }
  /** Decode the cursor-addressed subset emitted by Screen, for visible-text assertions. */
  screen(): string {
    const lines: string[][] = [];
    let row = 0, col = 0;
    const text = this.output;
    for (let i = 0; i < text.length;) {
      if (text.startsWith("\x1b]", i)) {
        const osc = /^\x1b\][^\x07\x1b]*(\x07|\x1b\\)/.exec(text.slice(i));
        i += osc ? osc[0].length : 2;
        continue;
      }
      if (text[i] === "\x1b") {
        const match = /^\x1b\[([0-9;?]*)([ -/]*)([@-~])/.exec(text.slice(i));
        if (!match) { i++; continue; }
        const nums = match[1].split(";").map(Number);
        switch (match[3]) {
          case "H": case "f": row = (nums[0] || 1) - 1; col = (nums[1] || 1) - 1; break;
          case "J": if (nums[0] === 2) lines.length = 0; break;
          case "K": if (lines[row]) lines[row].length = col; break;
        }
        i += match[0].length;
        continue;
      }
      const point = text.codePointAt(i)!;
      const char = String.fromCodePoint(point);
      i += char.length;
      if (char === "\r") { col = 0; continue; }
      if (char === "\n") { row++; continue; }
      if (point < 32) continue;
      lines[row] ??= [];
      lines[row][col++] = char;
      if (point >= 0x1100 && (point <= 0x115f || point >= 0x2e80 && point <= 0xa4cf || point >= 0x1f300)) col++;
    }
    return Array.from(lines, (line) => line ? Array.from({ length: line.length }, (_, i) => line[i] ?? " ").join("") : "").join("\n");
  }
  /** The last window title set (OSC 2). */
  title(): string | undefined {
    return [...this.output.matchAll(/\x1b\]2;([^\x07\x1b]*)\x1b\\/g)].at(-1)?.[1];
  }
  send(text: string) { this.terminal.write(text); }
  async ready() { await waitFor(() => this.output.includes("\x1b[?1049h"), "alternate screen"); }
  async quit() {
    this.send("\x11");
    await waitFor(() => this.process.exitCode !== null, "Ctrl+Q exit");
    return this.process.exited;
  }
  async close() {
    if (this.process.exitCode === null) {
      this.process.kill("SIGTERM");
      await Promise.race([this.process.exited, Bun.sleep(2000)]);
      if (this.process.exitCode === null) this.process.kill("SIGKILL");
      await this.process.exited;
    }
    this.terminal.close();
  }
}
