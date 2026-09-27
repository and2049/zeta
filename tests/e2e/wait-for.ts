export async function waitFor(check: () => boolean | Promise<boolean>, label = "condition") {
  for (let i = 0; i < 250; i++) {
    if (await check()) return;
    await Bun.sleep(20);
  }
  throw new Error(`Timed out waiting for ${label}`);
}
