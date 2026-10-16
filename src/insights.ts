import type { Run } from "./model.ts";
import { dayKey, dayOffset } from "./usage.ts";
export function countWords(text: string) {
  const han = text.match(/\p{Script=Han}/gu)?.length ?? 0;
  const rest = text.replace(/\p{Script=Han}/gu, " ");
  return (
    han + (rest.match(/[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)*/gu)?.length ?? 0)
  );
}
export function insights(runs: Run[], now = new Date()) {
  const byId = new Map(runs.map((r) => [r.id, r]));
  const groups = new Map<string, { root: Run; run: Run }>();
  for (const run of runs) {
    if (run.status !== "done" || run.sourceType !== "real") continue;
    let root = run;
    const seen = new Set([run.id]);
    while (
      root.parentId &&
      byId.has(root.parentId) &&
      !seen.has(root.parentId)
    ) {
      seen.add(root.parentId);
      root = byId.get(root.parentId)!;
    }
    const key = run.rootId ?? root.rootId ?? root.parentId ?? root.id;
    const previous = groups.get(key);
    if (!previous || previous.run.createdAt < run.createdAt)
      groups.set(key, { root, run });
  }
  const daily = new Map<
    string,
    { count: number; words: number; seconds: number }
  >();
  for (const { root, run } of groups.values()) {
    const date = run.rootCreatedAt ?? root.createdAt;
    if (!Number.isFinite(Date.parse(date))) continue;
    const d = dayKey(date),
      previous = daily.get(d) ?? { count: 0, words: 0, seconds: 0 };
    previous.count++;
    previous.words += countWords(run.cleanText ?? "");
    previous.seconds += Number.isFinite(run.duration)
      ? Math.max(0, run.duration)
      : 0;
    daily.set(d, previous);
  }
  const today = dayKey(now);
  const active = [...daily.keys()].filter((d) => d <= today).sort();
  let longest = 0,
    streak = 0,
    previous = "";
  for (const d of active) {
    streak = previous && dayOffset(previous, 1) === d ? streak + 1 : 1;
    longest = Math.max(longest, streak);
    previous = d;
  }
  let current = 0;
  for (
    let d = daily.has(today) ? today : dayOffset(today, -1);
    daily.has(d);
    d = dayOffset(d, -1)
  )
    current++;
  const totals = active.reduce(
    (s, d) => {
      const v = daily.get(d)!;
      return {
        count: s.count + v.count,
        words: s.words + v.words,
        seconds: s.seconds + v.seconds,
      };
    },
    { count: 0, words: 0, seconds: 0 },
  );
  const days = [];
  for (let d = dayOffset(today, -363); d <= today; d = dayOffset(d, 1))
    days.push({
      date: d,
      ...(daily.get(d) ?? { count: 0, words: 0, seconds: 0 }),
    });
  return {
    ...totals,
    speed: totals.seconds > 0 ? totals.words / (totals.seconds / 60) : null,
    activeDays: active.length,
    currentStreak: current,
    longestStreak: longest,
    days,
    timezone: "Asia/Taipei",
    counting:
      "漢字逐字，英文及其他字母／數字詞串逐詞；不計標點與 emoji。只計現存實際口述，重試合併為一次。",
  };
}
