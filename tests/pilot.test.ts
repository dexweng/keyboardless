import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import {
  mkdtemp,
  rm,
  readFile,
  writeFile,
  access,
  stat,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { request as httpRequest, type Server } from "node:http";
import { createApp } from "../src/server.ts";
import {
  OpenAIProvider,
  ServiceError,
  type Provider,
} from "../src/provider.ts";
import { cleanupCost, type Run } from "../src/model.ts";
let root: string, server: Server, url: string, token: string;
let transcriptions = 0,
  cleanups = 0,
  failCleanup = false;
let release: (() => void) | undefined;
const provider: Provider = {
  async transcribe() {
    transcriptions++;
    return { text: "週四寄出，不對，改週五，先不要通知客人。", usage: null };
  },
  async clean() {
    cleanups++;
    if (release === undefined && failCleanup)
      throw new ServiceError("測試：整理失敗");
    return {
      text: "週五寄出，先不要通知客人。",
      usage: { input_tokens: 100, output_tokens: 20 },
    };
  },
};
function wav() {
  const buffer = Buffer.alloc(32044);
  buffer.write("RIFF");
  buffer.writeUInt32LE(buffer.length - 8, 4);
  buffer.write("WAVEfmt ", 8);
  buffer.writeUInt32LE(16, 16);
  buffer.writeUInt16LE(1, 20);
  buffer.writeUInt16LE(1, 22);
  buffer.writeUInt32LE(16000, 24);
  buffer.writeUInt32LE(32000, 28);
  buffer.writeUInt16LE(2, 32);
  buffer.writeUInt16LE(16, 34);
  buffer.write("data", 36);
  buffer.writeUInt32LE(32000, 40);
  for (let i = 0; i < 16000; i++)
    buffer.writeInt16LE(
      Math.round(Math.sin((i * 2 * Math.PI * 440) / 16000) * 1000),
      44 + i * 2,
    );
  return buffer;
}
async function request(
  path: string,
  method = "GET",
  body?: unknown,
  extra: Record<string, string> = {},
) {
  return fetch(url + "/api" + path, {
    method,
    headers: {
      Host: "127.0.0.1:31339",
      "X-Pilot-Token": token,
      ...(body && !(body instanceof FormData)
        ? { "Content-Type": "application/json" }
        : {}),
      ...extra,
    },
    body:
      body instanceof FormData ? body : body ? JSON.stringify(body) : undefined,
  });
}
async function upload(name = "signal.wav", data = wav()) {
  const form = new FormData();
  form.set("sourceType", "scripted");
  form.set("caseId", "T02");
  form.set("audio", new Blob([new Uint8Array(data)]), name);
  return request("/runs", "POST", form);
}
async function finished(id: string) {
  for (let i = 0; i < 100; i++) {
    const r = (await (await request("/runs/" + id)).json()) as Run;
    if (["done", "failed"].includes(r.status)) return r;
    await new Promise((resolve) => setTimeout(resolve, 30));
  }
  throw new Error("Timed out");
}
before(async () => {
  root = await mkdtemp(join(tmpdir(), "dictation-test-"));
  const { app } = await createApp({
    dataRoot: join(root, ".local"),
    provider,
    port: 31339,
    secrets: {read:async()=>"",write:async()=>{},remove:async()=>{}},
    envPath: join(root, "missing.env"),
  });
  server = await new Promise((resolve) => {
    const s = app.listen(31339, "127.0.0.1", () => resolve(s));
  });
  const a = server.address();
  if (!a || typeof a === "string") throw Error("address");
  url = `http://127.0.0.1:${a.port}`;
  token = ((await (await request("/config")).json()) as { token: string })
    .token;
});
after(async () => {
  server.closeAllConnections();
  await new Promise<void>((resolve) => server.close(() => resolve()));
  await rm(root, { recursive: true, force: true });
});
test("cross-site calls and unauthenticated writes are denied", async () => {
  assert.equal(
    (
      await request("/config", "GET", undefined, {
        Origin: "https://example.com",
      })
    ).status,
    403,
  );
  assert.equal(
    (
      await request(
        "/glossary",
        "PUT",
        { glossary: [] },
        { "X-Pilot-Token": "wrong" },
      )
    ).status,
    403,
  );
  assert.equal(
    await new Promise<number | undefined>((resolve, reject) => {
      const req = httpRequest(
        url + "/api/config",
        { headers: { Host: "evil.example:3018" } },
        (res) => {
          res.resume();
          resolve(res.statusCode);
        },
      );
      req.on("error", reject);
      req.end();
    }),
    403,
  );
});
test("invalid audio rejected without a ghost run; subsequent uploads still work", async () => {
  const count = ((await (await request("/runs")).json()) as Run[]).length;
  assert.equal((await upload("bad.wav", Buffer.from("not audio"))).status, 400);
  assert.equal(
    ((await (await request("/runs")).json()) as Run[]).length,
    count,
  );
});
test("WAV, MP3 and M4A decode and preserve separate raw/clean text", async () => {
  await writeFile(join(root, "signal.wav"), wav());
  for (const extension of ["wav", "mp3", "m4a"]) {
    const path = join(root, "signal." + extension);
    if (extension !== "wav")
      await promisify(execFile)("ffmpeg", [
        "-v",
        "error",
        "-i",
        join(root, "signal.wav"),
        "-y",
        path,
      ]);
    const response = await upload("signal." + extension, await readFile(path));
    assert.equal(response.status, 202);
    const r = await finished(((await response.json()) as Run).id);
    assert.equal(r.status, "done");
    assert.notEqual(r.rawText, r.cleanText);
    assert.ok(r.duration > 0.9);
    assert.equal(r.usage.transcribe, null);
    assert.ok(r.costs.transcribe.usd !== null);
    assert.equal((await request("/runs/" + r.id + "/audio")).status, 200);
    assert.equal(r.reference.verified, false);
    assert.ok(r.audioHash.match(/^[a-f0-9]{64}$/));
  }
});
test("cleanup failure retains transcript; cleanup-only retry never retranscribes and preserves old run", async () => {
  failCleanup = true;
  const failed = await finished(((await (await upload()).json()) as Run).id);
  assert.equal(failed.status, "failed");
  assert.ok(failed.rawText);
  assert.equal(failed.cleanText, null);
  const before = transcriptions;
  failCleanup = false;
  const response = await request("/runs/" + failed.id + "/retry", "POST", {
    mode: "cleanup",
  });
  assert.equal(response.status, 202);
  const r = await finished(((await response.json()) as Run).id);
  assert.equal(r.status, "done");
  assert.equal(transcriptions, before);
  assert.equal(r.parentId, failed.id);
  assert.equal(r.audioHash, failed.audioHash);
  assert.equal(r.costs.transcribe.usd, 0);
  const original = (await (await request("/runs/" + failed.id)).json()) as Run;
  assert.equal(original.status, "failed");
  assert.equal(original.cleanText, null);
});
test("baseline missing stays null; export marks experiment incomplete and excludes secrets", async () => {
  const response = await request("/report");
  const report = (await response.json()) as {
    verification: string;
    runs: Run[];
  };
  assert.equal(report.verification, "未完成");
  assert.ok(report.runs.every((r) => r.baseline === null));
  assert.ok(!JSON.stringify(report).includes("OPENAI_API_KEY"));
  assert.ok(!JSON.stringify(report).includes(token));
});
test("review persists, timings immutable once saved, deletion removes audio and result", async () => {
  const r = ((await (await request("/runs")).json()) as Run[]).find(
    (r) => r.status === "done",
  )!;
  const baseline = {
    text: "基線",
    version: "2.8.1",
    settings: "人工測試設定",
    inputMethod: "reread",
    recordedAt: new Date().toISOString(),
  };
  assert.equal(
    (await request("/runs/" + r.id, "PATCH", { baseline, endToEndMs: 1250 }))
      .status,
    200,
  );
  await request("/runs/" + r.id, "PATCH", { endToEndMs: 9000 });
  const updated = (await (await request("/runs/" + r.id)).json()) as Run;
  assert.equal(updated.baseline?.inputMethod, "reread");
  assert.equal(updated.timings.endToEndMs, 1250);
  assert.equal((await request("/runs/" + r.id, "DELETE")).status, 204);
  assert.equal((await request("/runs/" + r.id + "/audio")).status, 404);
  await assert.rejects(access(join(root, ".local", "runs", r.id)));
});
test("provider redacts server errors and refuses truncated cleanup", async () => {
  const forbidden = "private-token-must-not-leak";
  const p = new OpenAIProvider(
    () => forbidden,
    (async () =>
      new Response(JSON.stringify({ error: forbidden }), {
        status: 401,
      })) as typeof fetch,
  );
  await assert.rejects(
    p.clean("test", "model", []),
    (e) =>
      e instanceof Error &&
      !e.message.includes(forbidden) &&
      e.message.includes("金鑰"),
  );
  const incomplete = new OpenAIProvider(() => forbidden, (async () =>
    Response.json({
      status: "incomplete",
      output: [
        {
          type: "message",
          content: [{ type: "output_text", text: "partial" }],
        },
      ],
    })) as typeof fetch);
  await assert.rejects(incomplete.clean("test", "model", []), /未完整完成/);
});
test("missing usage remains unknown; cached-token pricing applied only to known model", () => {
  assert.equal(cleanupCost("gpt-5.4-mini", null).usd, null);
  assert.equal(
    cleanupCost("unknown", { input_tokens: 10, output_tokens: 1 }).usd,
    null,
  );
  assert.equal(
    cleanupCost("gpt-5.4-mini", {
      input_tokens: 1000,
      output_tokens: 100,
      input_tokens_details: { cached_tokens: 500 },
    }).usd,
    (500 * 0.75 + 500 * 0.075 + 100 * 4.5) / 1e6,
  );
});

test("local configuration refreshes without restarting and does not require a browser key", async () => {
  const { readConfig } = await import("../src/config.ts");
  const path = join(root, "fixture.env");
  assert.equal(readConfig(path, {}).key, "");
  await writeFile(
    path,
    "OPENAI_API_KEY=test-only-key\nCLEANUP_MODEL=example-model\n",
    { mode: 0o600 },
  );
  assert.equal(readConfig(path, {}).key, "test-only-key");
  assert.equal(readConfig(path, {}).models.cleanup, "example-model");
  await rm(path);
  assert.equal(readConfig(path, {}).key, "");
});

test("insights and usage API totals reconcile and retain origin protection", async () => {
  const usage = await (await request("/usage?period=all")).json();
  assert.equal(
    usage.tokens,
    usage.entries.reduce((s: number, e: any) => s + (e.usage.total ?? 0), 0),
  );
  assert.ok(
    Math.abs(
      usage.usd - usage.days.reduce((s: number, d: any) => s + d.usd, 0),
    ) < 1e-12,
  );
  assert.equal((await request("/usage?period=invalid")).status, 400);
  assert.equal(
    (
      await request("/insights", "GET", undefined, {
        Origin: "https://evil.example",
      })
    ).status,
    403,
  );
  assert.equal(
    (
      await request("/usage", "GET", undefined, {
        Origin: "https://evil.example",
      })
    ).status,
    403,
  );
  const insights = await (await request("/insights")).json();
  assert.equal(insights.count, 0);
  assert.equal(insights.days.length, 364);
});
