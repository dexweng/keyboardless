import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, writeFile, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { countWords, insights } from "../src/insights.ts";
import {
  normalizeUsage,
  priceCost,
  UsageLedger,
  usageSummary,
} from "../src/usage.ts";
import { Store } from "../src/store.ts";
import { processRun } from "../src/engine.ts";
import { OpenAIProvider, ServiceError } from "../src/provider.ts";
import { costUnknown, type Run } from "../src/model.ts";
function run(extra: Partial<Run> = {}): Run {
  return {
    id: randomUUID(),
    parentId: null,
    createdAt: "2026-10-14T15:59:00Z",
    status: "done",
    sourceType: "real",
    duration: 60,
    rawText: "hello",
    cleanText: "你好 world",
    models: { transcribe: "gpt-transcribe", cleanup: "gpt-5.4-mini" },
    usage: {
      transcribe: { type: "duration", seconds: 61 },
      cleanup: { input_tokens: 100, output_tokens: 20 },
    },
    costs: { transcribe: costUnknown(), cleanup: costUnknown() },
    timings: {},
    glossary: [],
    ...extra,
  } as Run;
}
test("mixed language, retry chains, timezone, streak and zero data", () => {
  assert.equal(countWords("你好 world，don't stop 123! 😄"), 6);
  const a = run();
  const b = run({
    parentId: a.id,
    createdAt: "2026-10-14T16:01:00Z",
    cleanText: "新的 text",
  });
  const c = run({ createdAt: "2026-10-14T16:00:00Z" });
  const s = insights([a, b, c], new Date("2026-10-15T16:01:00Z"));
  assert.equal(s.count, 2);
  assert.equal(s.words, 6);
  assert.equal(s.currentStreak, 2);
  assert.equal(s.longestStreak, 2);
  assert.equal(s.activeDays, 2);
  assert.equal(s.days.length, 364);
  assert.equal(insights([], new Date()).speed, null);
  assert.equal(insights([run({ parentId: randomUUID() })]).count, 1);
  assert.equal(insights([run({ status: "failed" })]).count, 0);
});
test("pricing validates and never double counts subsets", () => {
  const usage = {
    input_tokens: 100,
    output_tokens: 20,
    input_tokens_details: { cached_tokens: 40 },
    output_tokens_details: { reasoning_tokens: 10 },
  };
  assert.equal(normalizeUsage(usage).total, 120);
  assert.equal(priceCost("cleanup", "gpt-5.4-mini", usage).usd, 0.000138);
  assert.equal(
    priceCost("transcribe", "gpt-transcribe", { seconds: 60 }, 59).usd,
    0.0045,
  );
  assert.equal(priceCost("cleanup", "unknown", usage).usd, null);
  assert.equal(
    priceCost("cleanup", "gpt-5.4-mini", { ...usage, input_tokens: -1 }).usd,
    null,
  );
  assert.equal(
    priceCost("cleanup", "gpt-5.4-mini", {
      ...usage,
      input_tokens_details: { cached_tokens: 101 },
    }).usd,
    null,
  );
  assert.equal(
    priceCost("cleanup", "gpt-5.4-mini", { total_tokens: 100 }).usd,
    null,
  );
});
test("ledger migration, retries, deletion, pending recovery and known failure usage", async () => {
  const root = await mkdtemp(join(tmpdir(), "kb-ledger-"));
  try {
    const store = new Store(root);
    await store.init();
    const a = run();
    const b = run({
      parentId: a.id,
      usage: {
        transcribe: null,
        cleanup: { input_tokens: 10, output_tokens: 10 },
      },
      costs: {
        transcribe: { ...costUnknown(), usd: 0 },
        cleanup: costUnknown(),
      },
    });
    const ledger = new UsageLedger(store);
    await ledger.init([a, b]);
    await ledger.init([a, b]);
    let entries = await ledger.list();
    assert.equal(entries.length, 3);
    assert.equal(usageSummary(entries).tokens, 140);
    assert.equal(
      usageSummary(entries, "today", new Date("2026-10-14T16:00:00Z")).tokens,
      0,
    );
    await store.remove(a.id);
    await ledger.init([]);
    assert.equal((await ledger.list()).length, 3);
    const c = run({ status: "transcribing" });
    await mkdir(store.dir(c.id));
    const pending = await ledger.begin(c, "transcribe");
    await ledger.init([]);
    assert.equal(
      (await ledger.list()).find((e) => e.id === pending.id)?.status,
      "unknown",
    );
    await processRun(c, store, {
      async transcribe() {
        throw new ServiceError("empty", { seconds: 5 });
      },
      async clean() {
        throw Error("must not call");
      },
    });
    entries = await ledger.list();
    assert.equal(
      entries.find((e) => e.runId === c.id)?.cost.usd,
      (5 / 60) * 0.0045,
    );
    assert.equal(c.status, "failed");
    assert.equal(c.usage.transcribe?.seconds, 5);
    const encoded = JSON.stringify(entries);
    assert.ok(!encoded.includes("你好"));
    assert.ok(!encoded.includes("rawText"));
    const d = run({ status: "transcribing" });
    await mkdir(store.dir(d.id));
    await processRun(d, store, {
      async transcribe() {
        throw new ServiceError("timeout");
      },
      async clean() {
        throw Error("must not call");
      },
    });
    assert.equal(usageSummary(await ledger.list()).unknown, 1);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
test("provider keeps usage on empty/incomplete/error responses", async () => {
  const dir = await mkdtemp(join(tmpdir(), "kb-provider-"));
  try {
    const audio = join(dir, "a.wav");
    await writeFile(audio, "fake");
    for (const response of [
      { status: "incomplete", usage: { input_tokens: 5, output_tokens: 2 } },
      {
        status: "completed",
        output: [],
        usage: { input_tokens: 5, output_tokens: 2 },
      },
    ]) {
      const p = new OpenAIProvider(
        () => "test",
        async () => new Response(JSON.stringify(response)),
      );
      await assert.rejects(
        p.clean("text", "model", []),
        (e) => e instanceof ServiceError && e.usage?.input_tokens === 5,
      );
    }
    const p = new OpenAIProvider(
      () => "test",
      async () =>
        new Response(JSON.stringify({ text: "", usage: { seconds: 3 } })),
    );
    await assert.rejects(
      p.transcribe(audio, "model", []),
      (e) => e instanceof ServiceError && e.usage?.seconds === 3,
    );
    const q = new OpenAIProvider(
      () => "test",
      async () =>
        new Response(JSON.stringify({ usage: { input_tokens: 9 } }), {
          status: 400,
        }),
    );
    await assert.rejects(
      q.clean("text", "model", []),
      (e) => e instanceof ServiceError && e.usage?.input_tokens === 9,
    );
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
