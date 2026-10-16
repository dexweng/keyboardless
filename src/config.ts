import { readFileSync } from "node:fs";
import { parseEnv } from "node:util";
export function readConfig(
  path: string,
  environment: NodeJS.ProcessEnv = process.env,
) {
  let local: Record<string, string | undefined> = {};
  try {
    local = parseEnv(readFileSync(path, "utf8"));
  } catch {
    /* local configuration is optional */
  }
  return {
    key: local.OPENAI_API_KEY || environment.OPENAI_API_KEY || "",
    models: {
      transcribe:
        local.TRANSCRIBE_MODEL ||
        environment.TRANSCRIBE_MODEL ||
        "gpt-transcribe",
      cleanup:
        local.CLEANUP_MODEL ||
        environment.CLEANUP_MODEL ||
        "gpt-5.4-nano-2026-03-17",
    },
  };
}
