import { execFile } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";
import { writeFile, rename, chmod } from "node:fs/promises";
import { join } from "node:path";
import { z } from "zod";
import { readConfig } from "./config.ts";

export const CLEANUP_MODELS = [
  "gpt-5.4-nano-2026-03-17",
  "gpt-5.4-mini-2026-03-17",
] as const;
export const settingsInput = z
  .object({
    cleanup: z.enum(CLEANUP_MODELS),
    key: z.string().trim().max(1024).optional(),
    removeKey: z.boolean().optional(),
    migrateKey: z.boolean().optional(),
  })
  .strict()
  .refine((v) => !(v.removeKey && (v.key || v.migrateKey)), "金鑰操作衝突");
export interface SecretStore {
  read(): Promise<string>;
  write(key: string): Promise<void>;
  remove(): Promise<void>;
}
export function keychainStore(helper: string): SecretStore {
  function call(action: string, input?: string): Promise<string> {
    return new Promise((resolve, reject) => {
      const child = execFile(
        helper,
        [action],
        { timeout: 20000, maxBuffer: 4096 },
        (error, stdout) => {
          if (error)
            reject(
              new Error(
                "無法存取 Keychain，請確認已建置 App 並解鎖登入鑰匙圈。",
              ),
            );
          else resolve(stdout);
        },
      );
      child.stdin?.on("error", () => {});
      child.stdin?.end(input ?? "");
    });
  }
  return {
    read: () => call("read"),
    write: async (key) => {
      await call("write", key);
    },
    remove: async () => {
      await call("delete");
    },
  };
}
export class APISettings {
  private saved: { cleanup?: string; managed?: boolean } = {};
  private secret = "";
  private keyError = false;
  private readonly file: string;
  constructor(
    private envPath: string,
    dataRoot: string,
    private secrets: SecretStore,
  ) {
    this.file = join(dataRoot, "api-settings.json");
    if (existsSync(this.file)) {
      this.saved = z
        .object({
          cleanup: z.enum(CLEANUP_MODELS).optional(),
          managed: z.boolean().optional(),
        })
        .strict()
        .parse(JSON.parse(readFileSync(this.file, "utf8")));
    }
  }
  async init() {
    try {
      this.secret = await this.secrets.read();
    } catch {
      this.keyError = true;
    }
  }
  key() {
    return (
      this.secret || (this.saved.managed ? "" : readConfig(this.envPath).key)
    );
  }
  models() {
    const models = readConfig(this.envPath).models;
    return { ...models, cleanup: this.saved.cleanup ?? models.cleanup };
  }
  public() {
    return {
      configured: !!this.key(),
      models: this.models(),
      keySource: this.secret
        ? "Keychain"
        : this.key()
          ? "環境設定（建議移至 Keychain）"
          : "未設定",
      keychainError: this.keyError,
      cleanupModels: CLEANUP_MODELS,
    };
  }
  async save(input: z.infer<typeof settingsInput>) {
    const v = settingsInput.parse(input);
    const newKey = v.migrateKey ? this.key() : v.key;
    if (newKey && !/^sk-[A-Za-z0-9_-]{16,}$/.test(newKey))
      throw new Error("OpenAI 金鑰格式不正確。");
    if (v.migrateKey && !newKey)
      throw new Error("沒有可移至 Keychain 的金鑰。");
    if (v.removeKey) {
      await this.secrets.remove();
      this.secret = "";
      this.saved.managed = true;
      this.keyError = false;
    } else if (newKey) {
      await this.secrets.write(newKey);
      if ((await this.secrets.read()) !== newKey)
        throw new Error("Keychain 寫入驗證失敗，原設定未刪除。");
      this.secret = newKey;
      this.saved.managed = true;
      this.keyError = false;
    }
    this.saved.cleanup = v.cleanup;
    await writeFile(this.file + ".tmp", JSON.stringify(this.saved), {
      mode: 0o600,
    });
    await rename(this.file + ".tmp", this.file);
    await chmod(this.file, 0o600);
    // Remove only the legacy secret after verified storage (or explicit removal).
    if ((newKey || v.removeKey) && existsSync(this.envPath)) {
      const source = readFileSync(this.envPath, "utf8");
      const cleaned = source.replace(
        /^\s*(?:export\s+)?OPENAI_API_KEY\s*=.*(?:\r?\n|$)/gm,
        "",
      );
      if (source !== cleaned) {
        await writeFile(this.envPath, cleaned, { mode: 0o600 });
        await chmod(this.envPath, 0o600);
      }
    }
    return this.public();
  }
}
