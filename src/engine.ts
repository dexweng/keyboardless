import { performance } from "node:perf_hooks";
import { join } from "node:path";
import { ServiceError, type Provider } from "./provider.ts";
import { cleanupCost, transcriptionCost, type Run } from "./model.ts";
import { UsageLedger } from "./usage.ts";
import type { Store } from "./store.ts";
export async function processRun(
  run: Run,
  store: Store,
  provider: Provider,
  cleanupOnly = false,
) {
  const ledger = new UsageLedger(store);
  const begin = performance.now();
  async function call(
    stage: "transcribe" | "cleanup",
    operation: () => ReturnType<Provider["clean"]>,
  ) {
    const entry = await ledger.begin(run, stage);
    let result;
    try {
      result = await operation();
    } catch (error) {
      const usage = error instanceof ServiceError ? error.usage : null;
      await ledger.finish(entry, usage, false);
      run.usage[stage] = usage;
      run.costs[stage] = entry.cost;
      throw error;
    }
    await ledger.finish(
      entry,
      result.usage,
      true,
      stage === "transcribe" ? run.duration : undefined,
    );
    return result;
  }
  let stage: "transcribe" | "cleanup" = cleanupOnly ? "cleanup" : "transcribe";
  try {
    if (!cleanupOnly) {
      run.status = "transcribing";
      await store.save(run);
      const start = performance.now();
      try {
        const r = await call("transcribe", () =>
          provider.transcribe(
            join(store.dir(run.id), "normalized.wav"),
            run.models.transcribe,
            run.glossary,
          ),
        );
        run.rawText = r.text;
        run.usage.transcribe = r.usage;
        run.costs.transcribe = transcriptionCost(
          run.models.transcribe,
          run.duration,
          r.usage,
        );
      } finally {
        run.timings.transcribeMs = performance.now() - start;
      }
      await store.save(run);
    }
    stage = "cleanup";
    run.status = "cleaning";
    await store.save(run);
    const start = performance.now();
    try {
      const result = await call("cleanup", () =>
        provider.clean(run.rawText!, run.models.cleanup, run.glossary),
      );
      run.cleanText = result.text;
      run.usage.cleanup = result.usage;
      run.costs.cleanup = cleanupCost(run.models.cleanup, result.usage);
    } finally {
      run.timings.cleanupMs = performance.now() - start;
    }
    run.status = "done";
    run.error = null;
    run.failedStage = null;
  } catch (error) {
    run.status = "failed";
    run.failedStage = stage;
    run.error =
      error instanceof ServiceError
        ? error.message
        : "處理失敗，已保留完成的結果，請重試。";
  }
  run.timings.serverMs = performance.now() - begin;
  await store.save(run);
  return run;
}
