import {
  mkdir,
  readFile,
  writeFile,
  rename,
  readdir,
  rm,
} from "node:fs/promises";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import type { Run, Settings } from "./model.ts";
export class Store {
  constructor(public root: string) {}
  async init() {
    await mkdir(this.root, { recursive: true, mode: 0o700 });
    await mkdir(join(this.root, "usage"), { recursive: true, mode: 0o700 });
    await mkdir(join(this.root, "runs"), { recursive: true, mode: 0o700 });
  }
  dir(id: string) {
    if (!/^[0-9a-f-]{36}$/.test(id)) throw new Error("Invalid ID");
    return join(this.root, "runs", id);
  }
  async atomic(path: string, value: unknown) {
    const tmp = path + "." + randomUUID() + ".tmp";
    await writeFile(tmp, JSON.stringify(value, null, 2), { mode: 0o600 });
    await rename(tmp, path);
  }
  async save(run: Run) {
    await this.atomic(join(this.dir(run.id), "run.json"), run);
  }
  async get(id: string): Promise<Run> {
    return JSON.parse(
      await readFile(join(this.dir(id), "run.json"), "utf8"),
    ) as Run;
  }
  async list() {
    const results: Run[] = [];
    for (const id of await readdir(join(this.root, "runs"))) {
      try {
        results.push(await this.get(id));
      } catch {
        /* ignore abandoned upload directories */
      }
    }
    return results.sort((a, b) => b.createdAt.localeCompare(a.createdAt));
  }
  async settings(): Promise<Settings> {
    try {
      return JSON.parse(
        await readFile(join(this.root, "settings.json"), "utf8"),
      ) as Settings;
    } catch {
      return {
        glossary: [
          "keyboardless",
          "OpenAI",
        ],
      };
    }
  }
  async setSettings(settings: Settings) {
    await this.atomic(join(this.root, "settings.json"), settings);
  }
  async remove(id: string) {
    await rm(this.dir(id), { recursive: true, force: true });
  }
}
