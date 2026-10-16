import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { APISettings, type SecretStore } from "../src/api-settings.ts";
import { priceCost } from "../src/usage.ts";
import { createApp } from "../src/server.ts";

function memory(): SecretStore {
  let value = "";
  return {
    read: async () => value,
    write: async (v) => {
      value = v;
    },
    remove: async () => {
      value = "";
    },
  };
}
const fakeKey = "sk-" + "synthetic".repeat(5);
const nano = "gpt-5.4-nano-2026-03-17";
test("API settings keep secrets out of JSON, migrate legacy key and prevent fallback after removal", async () => {
  const dir = await mkdtemp(join(tmpdir(), "kb-settings-"));
  const env = join(dir, ".env");
  const secrets = memory();
  try {
    await writeFile(
      env,
      `OPENAI_API_KEY=${fakeKey}\nTRANSCRIBE_MODEL=gpt-transcribe\n`,
    );
    const prefs = new APISettings(env, dir, secrets);
    await prefs.init();
    assert.equal(prefs.key(), fakeKey);
    await prefs.save({ cleanup: nano, migrateKey: true });
    assert.equal(await secrets.read(), fakeKey);
    assert.equal((await readFile(env, "utf8")).includes(fakeKey), false);
    assert.equal(
      (await readFile(join(dir, "api-settings.json"), "utf8")).includes(
        fakeKey,
      ),
      false,
    );
    assert.equal(JSON.stringify(prefs.public()).includes(fakeKey), false);
    assert.equal(prefs.models().transcribe, "gpt-transcribe");
    assert.equal(prefs.models().cleanup, nano);
    const reloaded = new APISettings(env, dir, secrets);
    await reloaded.init();
    assert.equal(reloaded.key(), fakeKey);
    await reloaded.save({ cleanup: nano, removeKey: true });
    await writeFile(env, `OPENAI_API_KEY=${fakeKey}\n`);
    const removed = new APISettings(env, dir, secrets);
    await removed.init();
    assert.equal(removed.key(), "");
    await assert.rejects(removed.save({ cleanup: nano, key: "bad" }));
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
test("Failed Keychain write preserves legacy secret", async () => {
  const dir = await mkdtemp(join(tmpdir(), "kb-settings-"));
  const env = join(dir, ".env");
  try {
    await writeFile(env, `OPENAI_API_KEY=${fakeKey}\n`);
    const prefs = new APISettings(env, dir, {
      read: async () => "",
      write: async () => {
        throw new Error("locked");
      },
      remove: async () => {},
    });
    await prefs.init();
    await assert.rejects(prefs.save({ cleanup: nano, migrateKey: true }));
    assert.equal(prefs.key(), fakeKey);
    assert.ok((await readFile(env, "utf8")).includes(fakeKey));
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
test("Nano pricing includes cached input and preserves mini rates", () => {
  const usage = {
    input_tokens: 1000,
    output_tokens: 100,
    input_tokens_details: { cached_tokens: 500 },
  };
  assert.equal(
    priceCost("cleanup", nano, usage).usd,
    (500 * 0.2 + 500 * 0.02 + 100 * 1.25) / 1e6,
  );
  assert.equal(
    priceCost("cleanup", "gpt-5.4-mini", usage).usd,
    (500 * 0.75 + 500 * 0.075 + 100 * 4.5) / 1e6,
  );
  assert.equal(priceCost("cleanup", "unknown", usage).usd, null);
});
test("Settings API requires token and rejects cross-site requests without exposing key", async () => {
  const dir = await mkdtemp(join(tmpdir(), "kb-settings-api-"));
  const { app } = await createApp({
    dataRoot: dir,
    envPath: join(dir, ".env"),
    secrets: memory(),
    port: 31340,
  });
  const server = app.listen(31340, "127.0.0.1");
  await new Promise<void>((r) => server.once("listening", r));
  const address = server.address();
  assert.ok(address && typeof address !== "string");
  const url = `http://127.0.0.1:${address.port}`;
  const get = () =>
    fetch(url + "/api/config", { headers: { host: "127.0.0.1:31340" } });
  try {
    const cfg = (await (await get()).json()) as { token: string };
    const send = (extra: Record<string, string> = {}) =>
      fetch(url + "/api/preferences", {
        method: "PUT",
        headers: {
          host: "127.0.0.1:31340",
          "content-type": "application/json",
          ...extra,
        },
        body: JSON.stringify({ cleanup: nano, key: fakeKey }),
      });
    assert.equal((await send()).status, 403);
    assert.equal(
      (
        await send({
          "x-pilot-token": cfg.token,
          origin: "https://untrusted.example",
        })
      ).status,
      403,
    );
    const response = await send({ "x-pilot-token": cfg.token });
    assert.equal(response.status, 200);
    assert.equal((await response.text()).includes(fakeKey), false);
    assert.equal((await (await get()).text()).includes(fakeKey), false);
  } finally {
    server.closeAllConnections();
    await new Promise<void>((r, e) =>
      server.close((err) => (err ? e(err) : r())),
    );
    await rm(dir, { recursive: true, force: true });
  }
});
test("Settings mutation locks other writes while Keychain is pending", async () => {
  const dir = await mkdtemp(join(tmpdir(), "kb-settings-lock-"));
  let release!: () => void;
  let started!: () => void;
  const pending = new Promise<void>((r) => {
    release = r;
  });
  const reached = new Promise<void>((r) => {
    started = r;
  });
  let stored = "";
  const secrets: SecretStore = {
    read: async () => stored,
    write: async (k) => {
      started();
      await pending;
      stored = k;
    },
    remove: async () => {
      stored = "";
    },
  };
  const { app } = await createApp({
    dataRoot: dir,
    envPath: join(dir, "missing.env"),
    secrets,
    port: 31341,
  });
  const server = app.listen(31341, "127.0.0.1");
  await new Promise<void>((r) => server.once("listening", r));
  const base = "http://127.0.0.1:31341";
  try {
    const cfg = (await (await fetch(base + "/api/config")).json()) as {
      token: string;
    };
    const request = () =>
      fetch(base + "/api/preferences", {
        method: "PUT",
        headers: {
          "content-type": "application/json",
          "x-pilot-token": cfg.token,
        },
        body: JSON.stringify({ cleanup: nano, key: fakeKey }),
      });
    const first = request();
    await reached;
    assert.equal((await request()).status, 409);
    release();
    assert.equal((await first).status, 200);
  } finally {
    release();
    server.closeAllConnections();
    await new Promise<void>((r) => server.close(() => r()));
    await rm(dir, { recursive: true, force: true });
  }
});
