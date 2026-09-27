import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { FakeOpenAI } from "./fake-openai";
import { Sandbox } from "./harness";

let sb: Sandbox;
let llm: FakeOpenAI;
const provider = (url: string) => ({ fake: { options: { baseURL: url } } });

beforeEach(() => {
  sb = new Sandbox();
  llm = new FakeOpenAI();
  sb.writeConfig({ model: "fake/base", provider: provider(llm.baseURL) });
});
afterEach(async () => {
  await sb.cleanup();
  llm.stop();
});

describe("session configuration", () => {
  test("project profile overrides global profile, both layered over defaults", async () => {
    const global = join(sb.env.XDG_CONFIG_HOME, "zeta", "profiles");
    const project = join(sb.project, ".zeta", "profiles");
    mkdirSync(global, { recursive: true });
    mkdirSync(project, { recursive: true });
    writeFileSync(join(global, "review.jsonc"), JSON.stringify({ model: "fake/global-profile" }));
    writeFileSync(join(project, "review.jsonc"), JSON.stringify({ model: "fake/project-profile" }));
    llm.reply({ text: "project" });
    const result = await sb.zeta(["run", "--profile", "review", "hi"]);
    expect(result.code).toBe(0);
    expect(llm.requests[0].model).toBe("project-profile");
    expect(llm.requests[0].messages[0].role).toBe("system");
    expect(result.stdout).toBe("project\n");
  });

  test("CLI --model and caller ZETA_MODEL override config on a reused daemon", async () => {
    llm.reply({ text: "first" }, { text: "second" }, { text: "third" });
    expect((await sb.zeta(["run", "initial"])).code).toBe(0);
    const pid = sb.discovery().pid;
    expect((await sb.zeta(["run", "--model", "fake/cli", "cli"])).code).toBe(0);
    expect((await sb.zeta(["run", "--model", "fake/cli", "env"], { ZETA_MODEL: "fake/caller-env" })).code).toBe(0);
    expect(sb.discovery().pid).toBe(pid);
    expect(llm.requests.map((request) => request.model)).toEqual(["base", "cli", "caller-env"]);
  });

});
