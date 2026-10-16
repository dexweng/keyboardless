// Isolated UI verification server: deterministic fake provider, no network calls.
import { mkdtemp, rm, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createApp } from "../src/server.ts";
const root = await mkdtemp(join(tmpdir(), "pilot-ui-"));
const { app } = await createApp({
  dataRoot: root,
  port: 31340,
  provider: {
    async transcribe() {
      return {
        text: "【介面測試替身】週四，不對，週五，先不要通知。",
        usage: null,
      };
    },
    async clean() {
      return { text: "【介面測試替身】週五，先不要通知。", usage: null };
    },
  },
});
const server = app.listen(31340, "127.0.0.1", () =>
  console.log("UI fixture http://127.0.0.1:31340 — no real model calls"),
);
async function stop() {
  server.closeAllConnections();
  server.close();
  await rm(root, { recursive: true, force: true });
  process.exit();
}
process.on("SIGINT", () => void stop());
process.on("SIGTERM", () => void stop());
