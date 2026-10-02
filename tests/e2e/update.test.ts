import { afterEach, beforeEach, expect, test } from "bun:test";
import { chmodSync, copyFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { join } from "node:path";
import { Sandbox, zetaBin } from "./harness";

let sb: Sandbox;
let releases: ReturnType<typeof Bun.serve> | undefined;

beforeEach(() => { sb = new Sandbox(); });
afterEach(async () => { releases?.stop(true); releases = undefined; await sb.cleanup(); });

const asset = `zeta-${process.platform === "darwin" ? "darwin" : "linux"}-${process.arch === "arm64" ? "aarch64" : "x86_64"}.tar.gz`;

/** A release v9.9.9 whose `zeta` is a script; `sums` may lie about it. */
async function serveRelease(lie = false) {
  const dir = join(sb.root, "release");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "zeta"), "#!/bin/sh\necho 'zeta 9.9.9'\n", { mode: 0o755 });
  writeFileSync(join(dir, "README.md"), "readme\n");
  const tar = Bun.spawnSync(["tar", "-czf", join(sb.root, asset), "-C", dir, "."]);
  expect(tar.exitCode).toBe(0);
  const archive = readFileSync(join(sb.root, asset));
  const sum = lie ? "0".repeat(64) : createHash("sha256").update(archive).digest("hex");
  releases = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch: (req) => {
      const path = new URL(req.url).pathname;
      if (path === "/releases/latest") return new Response(null, { status: 302, headers: { location: `http://127.0.0.1:${releases!.port}/releases/tag/v9.9.9` } });
      if (path === `/releases/download/v9.9.9/${asset}`) return new Response(null, { status: 302, headers: { location: "/storage/archive" } });
      if (path === "/storage/archive") return new Response(archive);
      if (path === "/releases/download/v9.9.9/SHA256SUMS") return new Response(`${sum}  ${asset}\n`);
      return new Response("not found", { status: 404 });
    },
  });
  return `http://127.0.0.1:${releases.port}`;
}

function installed() {
  const exe = join(sb.root, "bin", "zeta");
  mkdirSync(join(sb.root, "bin"), { recursive: true });
  copyFileSync(zetaBin, exe);
  chmodSync(exe, 0o755);
  return exe;
}

async function update(exe: string, base: string, args: string[] = []) {
  const proc = Bun.spawn([exe, "update", ...args], { env: { ...sb.env, ZETA_UPDATE_URL: base }, stdout: "pipe", stderr: "pipe" });
  const [stdout, code] = await Promise.all([new Response(proc.stdout).text(), proc.exited]);
  return { stdout, code };
}

test("zeta update replaces itself with the latest release after checking its checksum", async () => {
  const base = await serveRelease();
  const exe = installed();
  const result = await update(exe, base);
  expect(result.code).toBe(0);
  expect(result.stdout).toContain("Downloading zeta 9.9.9");
  expect(result.stdout).toContain(`-> 9.9.9 (${exe})`);
  const after = Bun.spawnSync([exe, "--version"]);
  expect(after.stdout.toString()).toBe("zeta 9.9.9\n");
});

test("a checksum mismatch or a missing release leaves the executable alone", async () => {
  const base = await serveRelease(true);
  const exe = installed();
  const before = readFileSync(exe);
  const mismatch = await update(exe, base);
  expect(mismatch.code).toBe(1);
  expect(mismatch.stdout).toContain("checksum mismatch");
  const missing = await update(exe, base, ["1.2.3"]);
  expect(missing.code).toBe(1);
  expect(missing.stdout).toContain("downloading v1.2.3");
  expect(readFileSync(exe).equals(before)).toBe(true);
});
