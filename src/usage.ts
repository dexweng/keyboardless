import { mkdir, readdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import type { Run, Usage, Cost } from "./model.ts";
import type { Store } from "./store.ts";
export const PRICE = {
  version: "2026-10-16",
  source: "https://developers.openai.com/api/docs/pricing",
  minute: 0.0045,
  input: 0.75,
  cached: 0.075,
  output: 4.5,
  nano: { input: 0.2, cached: 0.02, output: 1.25 },
} as const;
const number = (v: unknown): v is number =>
  typeof v === "number" && Number.isFinite(v) && v >= 0;
const integer = (v: unknown): v is number =>
  number(v) && Number.isSafeInteger(v);
export function normalizeUsage(u: Usage) {
  const input = integer(u?.input_tokens) ? u.input_tokens : null;
  const output = integer(u?.output_tokens) ? u.output_tokens : null;
  const detail = u?.input_tokens_details as Record<string, unknown> | undefined;
  const c = detail?.cached_tokens ?? 0;
  const cached = input !== null && integer(c) && c <= input ? c : null;
  return {
    input,
    output,
    cached,
    total:
      input !== null && output !== null
        ? input + output
        : integer(u?.total_tokens)
          ? u.total_tokens
          : null,
    seconds: number(u?.seconds) ? u.seconds : null,
  };
}
export function priceCost(
  stage: "transcribe" | "cleanup",
  model: string,
  usage: Usage,
  fallbackSeconds?: number,
): Cost {
  const u = normalizeUsage(usage);
  let usd: number | null = null,
    basis = "模型單價或用量缺失；費用未知";
  if (stage === "transcribe" && model === "gpt-transcribe") {
    const seconds =
      u.seconds ?? (number(fallbackSeconds) ? fallbackSeconds : null);
    if (seconds !== null) {
      usd = (seconds / 60) * PRICE.minute;
      basis = `${u.seconds !== null ? "API 回報秒數" : "本地音長回推"} × USD ${PRICE.minute}／分鐘；估算非帳單`;
    }
  }
  if (
    stage === "cleanup" &&
    ["gpt-5.4-mini", "gpt-5.4-mini-2026-03-17", "gpt-5.4-nano", "gpt-5.4-nano-2026-03-17"].includes(model) &&
    u.input !== null &&
    u.output !== null &&
    u.cached !== null
  ) {
    const rates = model.startsWith("gpt-5.4-nano") ? PRICE.nano : PRICE;
    usd =
      ((u.input - u.cached) * rates.input +
        u.cached * rates.cached +
        u.output * rates.output) /
      1e6;
    basis = "API token 用量 × 標準單價；估算非帳單";
  }
  return { usd, basis, checked: PRICE.version, source: PRICE.source };
}
export interface UsageEntry {
  schemaVersion: 1;
  id: string;
  runId: string;
  rootId: string;
  stage: "transcribe" | "cleanup";
  model: string;
  startedAt: string;
  endedAt: string | null;
  status: "pending" | "known" | "unknown";
  origin: "legacy" | "live";
  usage: ReturnType<typeof normalizeUsage>;
  cost: Cost;
  priceSnapshot: typeof PRICE;
}
export function entryFor(
  run: Run,
  stage: UsageEntry["stage"],
  origin: UsageEntry["origin"],
): UsageEntry {
  return {
    schemaVersion: 1,
    id: `${run.id}-${stage}`,
    runId: run.id,
    rootId: run.rootId ?? run.parentId ?? run.id,
    stage,
    model: run.models[stage],
    startedAt: origin === "legacy" ? run.createdAt : new Date().toISOString(),
    endedAt: null,
    status: "pending",
    origin,
    usage: normalizeUsage(null),
    cost: priceCost(stage, run.models[stage], null),
    priceSnapshot: PRICE,
  };
}
export class UsageLedger {
  constructor(private store: Store) {}
  get dir() {
    return join(this.store.root, "usage");
  }
  async save(entry: UsageEntry) {
    await this.store.atomic(join(this.dir, entry.id + ".json"), entry);
  }
  async list(): Promise<UsageEntry[]> {
    const files = (await readdir(this.dir)).filter((f) =>
      /^[0-9a-f-]{36}-(transcribe|cleanup)\.json$/.test(f),
    );
    // Corrupt accounting data must surface, never silently reduce the total.
    return Promise.all(
      files.map(
        async (f) =>
          JSON.parse(await readFile(join(this.dir, f), "utf8")) as UsageEntry,
      ),
    );
  }
  async init(runs: Run[]) {
    await mkdir(this.dir, { recursive: true, mode: 0o700 });
    const existing = await this.list();
    const ids = new Set(existing.map((e) => e.id));
    for (const e of existing)
      if (e.status === "pending") {
        e.status = "unknown";
        await this.save(e);
      }
    for (const run of runs)
      for (const stage of ["transcribe", "cleanup"] as const) {
        if (ids.has(`${run.id}-${stage}`)) continue;
        if (
          stage === "transcribe" &&
          run.parentId &&
          run.costs.transcribe.usd === 0
        )
          continue;
        if (stage === "cleanup" && !run.rawText && !run.usage.cleanup) continue;
        const e = entryFor(run, stage, "legacy");
        const usage = run.usage[stage];
        e.usage = normalizeUsage(usage);
        const completed =
          stage === "transcribe" ? !!run.rawText : !!run.cleanText;
        e.cost = priceCost(
          stage,
          e.model,
          usage,
          stage === "transcribe" && completed ? run.duration : undefined,
        );
        e.status = usage || completed ? "known" : "unknown";
        e.endedAt = run.createdAt;
        await this.save(e);
      }
  }
  async begin(run: Run, stage: UsageEntry["stage"]) {
    const e = entryFor(run, stage, "live");
    await this.save(e);
    return e;
  }
  async finish(
    e: UsageEntry,
    usage: Usage,
    succeeded: boolean,
    seconds?: number,
  ) {
    e.usage = normalizeUsage(usage);
    e.status = usage || succeeded ? "known" : "unknown";
    e.cost = priceCost(
      e.stage,
      e.model,
      usage,
      succeeded ? seconds : undefined,
    );
    e.endedAt = new Date().toISOString();
    await this.save(e);
  }
}
export const dayKey = (date: string | Date) =>
  new Date(new Date(date).getTime() + 8 * 3600000).toISOString().slice(0, 10);
export const dayOffset = (day: string, n: number) =>
  new Date(new Date(day + "T00:00:00Z").getTime() + n * 86400000)
    .toISOString()
    .slice(0, 10);
export function usageSummary(
  entries: UsageEntry[],
  period = "all",
  now = new Date(),
) {
  const today = dayKey(now);
  const start =
    period === "today"
      ? today
      : period === "month"
        ? today.slice(0, 7) + "-01"
        : null;
  const selected = entries
    .filter((e) => {
      const d = dayKey(e.startedAt);
      return (!start || d >= start) && d <= today;
    })
    .sort((a, b) => b.startedAt.localeCompare(a.startedAt));
  const sum = (es: UsageEntry[]) => ({
    usd: es.reduce((s, e) => s + (e.cost.usd ?? 0), 0),
    tokens: es.reduce((s, e) => s + (e.usage.total ?? 0), 0),
    input: es.reduce((s, e) => s + (e.usage.input ?? 0), 0),
    output: es.reduce((s, e) => s + (e.usage.output ?? 0), 0),
    cached: es.reduce((s, e) => s + (e.usage.cached ?? 0), 0),
    seconds: es.reduce((s, e) => s + (e.usage.seconds ?? 0), 0),
    unknown: es.filter(
      (e) =>
        e.cost.usd === null || e.status === "unknown" || e.status === "pending",
    ).length,
  });
  const daily = new Map<string, UsageEntry[]>();
  for (const e of selected) {
    const d = dayKey(e.startedAt);
    daily.set(d, [...(daily.get(d) ?? []), e]);
  }
  const first = entries.map((e) => dayKey(e.startedAt)).sort()[0] ?? null;
  const chartStart = start ?? first ?? today;
  const days = [];
  for (let d = chartStart; d <= today; d = dayOffset(d, 1))
    days.push({ date: d, ...sum(daily.get(d) ?? []) });
  return {
    period,
    ...sum(selected),
    firstDate: first,
    stages: {
      transcribe: sum(selected.filter((e) => e.stage === "transcribe")),
      cleanup: sum(selected.filter((e) => e.stage === "cleanup")),
    },
    days,
    entries: selected,
  };
}
