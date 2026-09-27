import { afterEach, beforeEach, expect, test } from "bun:test";
import { existsSync, mkdirSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { Sandbox, zetaBin } from "./harness";
import { waitFor } from "./wait-for";

let sb: Sandbox;
let server: ReturnType<typeof Bun.spawn>;
beforeEach(async () => {
  sb = new Sandbox();
  mkdirSync(join(sb.project, "src"));
  mkdirSync(join(sb.project, ".hidden"));
  mkdirSync(join(sb.project, "node_modules"));
  writeFileSync(join(sb.project, "src", "foo.zig"), "hello workspace\n");
  writeFileSync(join(sb.project, "f--o--o"), "other");
  writeFileSync(join(sb.project, ".hidden", "foo.txt"), "secret");
  writeFileSync(join(sb.project, "node_modules", "foo.js"), "ignored");
  writeFileSync(join(sb.project, "binary"), Buffer.from([0, 1, 2]));
  writeFileSync(join(sb.root, "outside"), "outside");
  symlinkSync(join(sb.root, "outside"), join(sb.project, "linked"));
  server = Bun.spawn([zetaBin, "serve"], { cwd: sb.project, env: sb.env, stdout: "ignore", stderr: "ignore" });
  await waitFor(() => existsSync(sb.discoveryPath), "file server discovery");
});
afterEach(async () => { await sb.cleanup(); await server.exited; });

test("file list, ranked find, bounded text read and path confinement", async () => {
  const loc = `location=${encodeURIComponent(sb.project)}`;
  const list = await sb.api(`/files?${loc}`);
  expect(list.status).toBe(200);
  const entries = (await list.json()).entries;
  expect(entries[0]).toMatchObject({ name: ".hidden", type: "dir" });
  expect(entries.find((e: any) => e.name === "linked").type).toBe("symlink");
  const found = await sb.api(`/files/find?${loc}&q=foo`);
  expect(found.status).toBe(200);
  expect((await found.json()).matches.map((m: any) => m.path)).toEqual(["src/foo.zig", "f--o--o"]);
  const read = await sb.api(`/files/read?${loc}&path=src%2Ffoo.zig&offset=6&limit=9`);
  expect(read.status).toBe(200);
  expect(await read.json()).toEqual({ content: "workspace", size: 16, offset: 6 });
  for (const path of ["..%2Foutside", "%2Fetc%2Fpasswd", "linked"]) {
    const response = await sb.api(`/files/read?${loc}&path=${path}`);
    expect(response.status).toBe(400);
    expect((await response.json()).error).toBeTruthy();
  }
  expect((await sb.api(`/files?${loc}&path=linked`)).status).toBe(400);
  expect((await sb.api(`/files/read?${loc}&path=binary`)).status).toBe(422);
  expect((await sb.api(`/files/read?${loc}&path=missing`)).status).toBe(404);
  const { url } = sb.discovery();
  expect((await fetch(`${url}/files?${loc}`)).status).toBe(401);
});
