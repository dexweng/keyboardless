import type { Run, Settings } from "./model.ts";
interface Config {
  token: string;
  configured: boolean;
  provider: string;
  models: Run["models"];
  settings: Settings;
}
interface Case {
  id: string;
  script: string;
  meaning: string;
}
const $ = <T extends HTMLElement = HTMLElement>(id: string) =>
  document.getElementById(id)! as T;
const esc = (s: unknown) =>
  String(s ?? "").replace(
    /[&<>"']/g,
    (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        c
      ]!,
  );
let config: Config;
let cases: Case[] = [];
let selected: string | null = null;
let file: File | null = null;
let recorder: MediaRecorder | null = null;
let stream: MediaStream | null = null;
let timer: number | undefined;
let started = 0;
let stopped = 0;
let previewURL: string | null = null;
let blind = false;
let flip = false;
let pending = false;
let recordingPending = false;
const endTimes = new Map<string, number>();
function notify(message = "") {
  $("notice").textContent = message;
}
async function api<T>(path: string, options: RequestInit = {}): Promise<T> {
  const headers = new Headers(options.headers);
  if (options.method && options.method !== "GET") {
    headers.set("X-Pilot-Token", config.token);
    if (!(options.body instanceof FormData))
      headers.set("Content-Type", "application/json");
  }
  const r = await fetch("/api" + path, { ...options, headers });
  if (!r.ok) {
    let message = "操作失敗，請重試。";
    try {
      message = ((await r.json()) as { error: string }).error;
    } catch {}
    throw new Error(message);
  }
  return r.status === 204 ? (undefined as T) : ((await r.json()) as T);
}
function action(id: string, fn: () => Promise<void> | void) {
  $(id).addEventListener("click", () => {
    void Promise.resolve()
      .then(fn)
      .catch((e) => notify((e as Error).message));
  });
}
function busyUI(value: boolean) {
  pending = value;
  $<HTMLButtonElement>("submit").disabled = value || !file;
  $<HTMLButtonElement>("record").disabled = value;
  $<HTMLInputElement>("audioFile").disabled = value;
}
function setFile(f: File) {
  file = f;
  if (previewURL) URL.revokeObjectURL(previewURL);
  previewURL = URL.createObjectURL(f);
  const p = $<HTMLAudioElement>("preview");
  p.src = previewURL;
  p.hidden = false;
  $("fileLabel").textContent = f.name;
  $<HTMLButtonElement>("submit").disabled = pending;
}
function releaseMic() {
  stream?.getTracks().forEach((t) => t.stop());
  stream = null;
  $<HTMLInputElement>("audioFile").disabled = pending;
  clearInterval(timer);
  $("record").classList.remove("recording");
  $("record").setAttribute("aria-label", "開始錄音");
  $("recordLabel").textContent = "點一下開始錄音";
}
async function toggleRecord() {
  if (recorder?.state === "recording") {
    stopped = performance.now();
    recorder.stop();
    releaseMic();
    return;
  }
  if (recordingPending) return;
  recordingPending = true;
  notify();
  try {
    if (!navigator.mediaDevices?.getUserMedia || !window.MediaRecorder)
      throw new Error("這個瀏覽器無法錄音。請改用 Chrome，或直接匯入音檔。");
    stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    const chunks: BlobPart[] = [];
    const mime = ["audio/webm;codecs=opus", "audio/mp4"].find((t) =>
      MediaRecorder.isTypeSupported(t),
    );
    recorder = new MediaRecorder(stream, mime ? { mimeType: mime } : undefined);
    const current = recorder;
    let bytes = 0;
    current.ondataavailable = (e) => {
      chunks.push(e.data);
      bytes += e.data.size;
      if (bytes > 23000000 && current.state === "recording") {
        stopped = performance.now();
        current.stop();
        releaseMic();
        notify("錄音已接近大小上限，自動停止。");
      }
    };
    current.onstop = () => {
      const type = current.mimeType;
      const suffix = type.includes("mp4") ? "m4a" : "webm";
      setFile(
        new File(
          chunks,
          `錄音-${new Date().toISOString().replace(/[:.]/g, "-")}.${suffix}`,
          { type },
        ),
      );
      releaseMic();
    };
    current.onerror = () => {
      releaseMic();
      notify("錄音失敗，請重試或匯入音檔。");
    };
    current.start(500);
    $<HTMLInputElement>("audioFile").disabled = true;
    started = performance.now();
    stopped = 0;
    $<HTMLButtonElement>("submit").disabled = true;
    $("record").classList.add("recording");
    $("record").setAttribute("aria-label", "停止錄音");
    $("recordLabel").textContent = "正在錄音，再點一下停止";
    timer = window.setInterval(() => {
      const s = Math.floor((performance.now() - started) / 1000);
      $("timer").textContent =
        `${String(Math.floor(s / 60)).padStart(2, "0")}:${String(s % 60).padStart(2, "0")}`;
    }, 250);
  } catch (e) {
    releaseMic();
    notify(
      (e as Error).name === "NotAllowedError"
        ? "麥克風權限未開啟。請在瀏覽器允許麥克風，或直接匯入音檔。"
        : (e as Error).message,
    );
  } finally {
    recordingPending = false;
  }
}
const time = (n: number | null) =>
  n === null ? "未量測" : (n / 1000).toFixed(1) + " 秒";
const date = (s: string) =>
  new Date(s).toLocaleString("zh-TW", {
    timeZone: "Asia/Taipei",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  });
const statuses = {
  done: "待人工核對",
  failed: "處理未完成",
  transcribing: "辨識中",
  cleaning: "整理中",
};
async function history() {
  const runs = await api<Run[]>("/runs");
  $("count").textContent = String(runs.length);
  $("history").innerHTML = runs.length
    ? runs
        .map(
          (r) =>
            `<button class="history-item ${r.id === selected ? "selected" : ""}" data-run="${r.id}">${esc(r.rawText?.slice(0, 22) || r.filename)}<small>${date(r.createdAt)} · ${r.review && r.status === "done" ? "已評分" : statuses[r.status]}</small></button>`,
        )
        .join("")
    : '<p class="hint">你的第一筆測試會出現在這裡。</p>';
  $("history")
    .querySelectorAll<HTMLButtonElement>("[data-run]")
    .forEach(
      (b) =>
        (b.onclick = () => {
          void select(b.dataset.run!).catch((e) => notify(e.message));
        }),
    );
}
function field(id: string, label: string, value = "", wide = false) {
  return `<label class="${wide ? "wide" : ""}">${label}<textarea id="${id}" rows="2">${esc(value)}</textarea></label>`;
}
function render(r: Run) {
  const running = ["transcribing", "cleaning"].includes(r.status);
  const cost =
    r.costs.transcribe.usd !== null && r.costs.cleanup.usd !== null
      ? "$" + (r.costs.transcribe.usd + r.costs.cleanup.usd).toFixed(5)
      : "未知／部分";
  const texts = [
    { label: "保守整理", text: r.cleanText },
    { label: "Typeless", text: r.baseline?.text || null },
  ];
  if (blind && flip) texts.reverse();
  const cards = [
    { label: "原始轉錄", text: r.rawText },
    ...texts.map((t, i) => ({
      label: blind ? `結果 ${i ? "B" : "A"}` : t.label,
      text: t.text,
    })),
  ];
  $("result").innerHTML =
    `<div class="result-top"><div><div class="eyebrow">LISTEN · COMPARE · REFINE</div><h1>${r.caseId ? esc(r.caseId) + " · " : ""}這段話，整理得如何？</h1><div class="meta">${date(r.createdAt)} · ${r.sourceType === "real" ? "實際工作口述" : "合成題朗讀"} · ${r.duration.toFixed(1)} 秒</div></div><span class="badge">${r.review && r.status === "done" ? "已評分" : statuses[r.status]}</span></div>
 ${running ? `<p class="progress">${r.status === "transcribing" ? "正在辨識音訊…" : "正在保守整理文字…"} 結果會自動更新。</p>` : ""}${r.error ? `<div class="callout">${esc(r.error)}</div>` : ""}
 <div class="metrics"><div class="metric"><small>語音辨識</small><b>${time(r.timings.transcribeMs)}</b></div><div class="metric"><small>文字整理</small><b>${time(r.timings.cleanupMs)}</b></div><div class="metric"><small>${r.timings.timingOrigin === "recording_stop" ? "停止錄音至結果可用" : r.timings.timingOrigin === "retry_submit" ? "重試至結果可用" : "送出至結果可用"}</small><b>${time(r.timings.endToEndMs)}</b></div><div class="metric"><small>本次估算 · USD</small><b>${cost}</b></div></div>
 <audio controls src="/api/runs/${r.id}/audio"></audio><div class="result-actions"><button id="blind" class="secondary" ${!r.baseline || !r.cleanText ? "disabled" : ""}>${blind ? "顯示產品名稱" : "隱藏名稱比較"}</button><button id="copy" class="secondary" ${!r.cleanText ? "disabled" : ""}>複製整理文字</button><button id="retryCleanup" class="secondary" ${running || !r.rawText ? "disabled" : ""}>只重做整理</button><button id="rerun" class="secondary" ${running ? "disabled" : ""}>重新辨識</button><button id="delete" class="text-button danger" ${running ? "disabled" : ""}>刪除此筆與音訊</button></div>
 <div class="compare">${cards.map((c, i) => `<article class="text-card ${i === 0 ? "muted" : ""}"><header>${esc(c.label)}</header><p class="${!c.text ? "empty" : ""}">${esc(c.text ?? "尚未測試／尚無結果")}</p></article>`).join("")}</div>
 ${r.baseline?.inputMethod !== "same_file" ? '<p class="comparison-note">Typeless 若使用重新朗讀或喇叭回放，輸入條件不同，結果只作實用性參考。</p>' : ""}
 <details><summary>加入 Typeless 實際結果</summary><div><div class="form-grid">${field("baselineText", "貼入這次 Typeless 的輸出", r.baseline?.text, true)}<label>輸入方式<select id="baselineMethod"><option value="reread">重新朗讀（不同音訊）</option><option value="speaker_replay">喇叭回放（有錄音差異）</option><option value="same_file">同一音檔直接輸入</option><option value="unknown">無法確認</option></select></label><label>Typeless 版本<input id="baselineVersion" value="${esc(r.baseline?.version || "")}" placeholder="例如 2.8.1"></label>${field("baselineSettings", "語言、詞庫、個人化設定", r.baseline?.settings, true)}</div><button id="saveBaseline" class="primary" ${running ? "disabled" : ""}>儲存基線</button></div></details>
 <details><summary>核對音訊與評分</summary><div><div class="form-grid">${field("reference", "人工核對的逐字稿", r.reference.verbatim, true)}${field("meaning", "必須保留的意思", r.reference.meaning || cases.find((c) => c.id === r.caseId)?.meaning || "", true)}</div><label class="inline-check"><input id="verified" type="checkbox" ${r.reference.verified ? "checked" : ""}>我已聽過音訊並核對逐字稿</label><div class="form-grid">${field("meaningErrors", "改錯原意（沒有請填「無」）", r.review?.meaningErrors)}${field("omissions", "遺漏資訊", r.review?.omissions)}${field("terms", "專有名詞錯誤", r.review?.terms)}${field("scriptIssues", "繁簡問題", r.review?.scriptIssues)}${field("tone", "語氣是否像我", r.review?.tone)}<label>使用程度<select id="usability"><option value="">請選擇</option><option value="direct">可以直接使用</option><option value="minor">需要小修</option><option value="rewrite">需要重寫</option></select></label>${field("corrected", "我修改後的版本", r.review?.corrected, true)}${field("notes", "備註與偏好（盲評時請註記 A／B）", r.review?.notes, true)}</div><button id="saveReview" class="primary" ${running ? "disabled" : ""}>儲存核對與評分</button></div></details>
 <details><summary>這次使用的設定與費用依據</summary><div><pre>${esc(JSON.stringify({ models: r.models, promptVersion: r.promptVersion, glossary: r.glossary, transcriptionSettings: r.transcriptionSettings, blindOrder: r.review?.blindOrder, audioHash: r.audioHash, parentId: r.parentId, costs: r.costs, usage: r.usage, timings: r.timings }, null, 2))}</pre></div></details>`;
  if (r.baseline)
    $<HTMLSelectElement>("baselineMethod").value = r.baseline.inputMethod;
  if (r.review) $<HTMLSelectElement>("usability").value = r.review.usability;
  action("blind", () => {
    blind = !blind;
    if (blind) flip = Math.random() < 0.5;
    render(r);
  });
  action("copy", async () => {
    await navigator.clipboard.writeText(r.cleanText!);
    notify("已複製整理文字。");
  });
  action("saveBaseline", async () => {
    const value = (id: string) => $<HTMLInputElement>(id).value.trim();
    if (
      !value("baselineText") ||
      !value("baselineVersion") ||
      !value("baselineSettings")
    )
      throw new Error("請補上 Typeless 結果、版本與設定。");
    const updated = await api<Run>("/runs/" + r.id, {
      method: "PATCH",
      body: JSON.stringify({
        baseline: {
          text: value("baselineText"),
          version: value("baselineVersion"),
          settings: value("baselineSettings"),
          inputMethod: value("baselineMethod"),
          recordedAt: new Date().toISOString(),
        },
      }),
    });
    render(updated);
    notify("已儲存 Typeless 基線。");
  });
  action("saveReview", async () => {
    const value = (id: string) => $<HTMLInputElement>(id).value.trim();
    if (!value("usability")) throw new Error("請選擇使用程度。");
    if ($<HTMLInputElement>("verified").checked && !value("reference"))
      throw new Error("請填寫已核對的逐字稿。");
    const updated = await api<Run>("/runs/" + r.id, {
      method: "PATCH",
      body: JSON.stringify({
        reference: {
          verbatim: value("reference"),
          meaning: value("meaning"),
          verified: $<HTMLInputElement>("verified").checked,
        },
        review: {
          meaningErrors: value("meaningErrors"),
          omissions: value("omissions"),
          terms: value("terms"),
          scriptIssues: value("scriptIssues"),
          tone: value("tone"),
          usability: value("usability"),
          corrected: value("corrected"),
          notes: value("notes"),
          reviewedAt: new Date().toISOString(),
          blindOrder: blind
            ? flip
              ? ["typeless", "candidate"]
              : ["candidate", "typeless"]
            : null,
        },
      }),
    });
    render(updated);
    notify("已儲存人工評分。");
  });
  const retry = async (mode: string) => {
    const begin = performance.now();
    const next = await api<Run>("/runs/" + r.id + "/retry", {
      method: "POST",
      body: JSON.stringify({ mode }),
    });
    endTimes.set(next.id, begin);
    await select(next.id);
    void poll(next.id);
  };
  action("retryCleanup", () => retry("cleanup"));
  action("rerun", () => retry("full"));
  action("delete", async () => {
    if (!confirm("刪除此筆結果及它的音訊？其他重跑紀錄仍會保留；不含口述文字的用量與費用帳目也會保留。")) return;
    await api("/runs/" + r.id, { method: "DELETE" });
    selected = null;
    $("result").hidden = true;
    $("capture").hidden = false;
    await history();
    notify("已刪除此筆結果與音訊。");
  });
}
async function select(id: string) {
  if (recorder?.state === "recording")
    throw new Error("請先停止錄音，再查看其他紀錄。");
  selected = id;
  blind = false;
  $("capture").hidden = true;
  $("result").hidden = false;
  const r = await api<Run>("/runs/" + id);
  render(r);
  await history();
}
async function poll(id: string) {
  try {
    let r = await api<Run>("/runs/" + id);
    if (r.status === "done" || r.status === "failed") {
      const begin = endTimes.get(id);
      if (begin !== undefined) {
        if (r.status === "done")
          r = await api<Run>("/runs/" + id, {
            method: "PATCH",
            body: JSON.stringify({ endToEndMs: performance.now() - begin }),
          });
        endTimes.delete(id);
      }
      busyUI(false);
      if (selected === id) render(r);
      await history();
      return;
    }
    if (selected === id) render(r);
    window.setTimeout(() => void poll(id), 750);
  } catch (e) {
    busyUI(false);
    notify((e as Error).message);
  }
}
action("record", toggleRecord);
$<HTMLInputElement>("audioFile").onchange = () => {
  const f = $<HTMLInputElement>("audioFile").files?.[0];
  if (!f) return;
  if (f.size > 24000000) {
    notify("音檔超過 24 MB，請縮短後再匯入。");
    return;
  }
  stopped = 0;
  setFile(f);
  notify();
};
$<HTMLSelectElement>("case").onchange = () => {
  const c = cases.find((c) => c.id === $<HTMLSelectElement>("case").value);
  $("casePrompt").hidden = !c;
  if (c) {
    $("casePrompt").textContent = c.script;
    $<HTMLSelectElement>("source").value = "scripted";
  }
};
action("submit", async () => {
  if (!file) return;
  const begin = stopped || performance.now();
  const data = new FormData();
  data.set("audio", file);
  data.set("sourceType", $<HTMLSelectElement>("source").value);
  data.set("caseId", $<HTMLSelectElement>("case").value);
  data.set("timingOrigin", stopped ? "recording_stop" : "upload_submit");
  busyUI(true);
  notify();
  try {
    const r = await api<Run>("/runs", { method: "POST", body: data });
    endTimes.set(r.id, begin);
    await select(r.id);
    void poll(r.id);
  } catch (e) {
    busyUI(false);
    throw e;
  }
});
action("new", () => {
  if (recorder?.state === "recording") return;
  selected = null;
  $("result").hidden = true;
  $("capture").hidden = false;
  notify();
  void history();
});
action("settingsToggle", () => {
  $("settings").hidden = !$("settings").hidden;
});
action("closeSettings", () => {
  $("settings").hidden = true;
});
action("saveGlossary", async () => {
  await api("/glossary", {
    method: "PUT",
    body: JSON.stringify({
      glossary: $<HTMLTextAreaElement>("glossary")
        .value.split("\n")
        .map((s) => s.trim())
        .filter(Boolean),
    }),
  });
  notify("已儲存詞庫，下一次處理會使用新設定。");
});
window.addEventListener("beforeunload", () => releaseMic());
async function init() {
  config = await api<Config>("/config");
  cases = await api<Case[]>("/cases");
  $("serviceStatus").textContent = config.configured
    ? "OpenAI · 已設定"
    : "待設定 API 金鑰";
  $("serviceStatus").classList.toggle("warn", !config.configured);
  $("modelInfo").textContent =
    `辨識：${config.models.transcribe}　整理：${config.models.cleanup}`;
  $<HTMLTextAreaElement>("glossary").value =
    config.settings.glossary.join("\n");
  for (const c of cases) {
    const option = document.createElement("option");
    option.value = c.id;
    option.textContent = `${c.id} · ${c.script.slice(0, 19)}…`;
    $("case").append(option);
  }
  if (!config.configured)
    notify("可以先錄音或匯入音檔；使用 AI 辨識前，請先在本機設定 API 金鑰。");
  await history();
  const runs = await api<Run[]>("/runs");
  const active = runs.find(
    (r) => r.status === "transcribing" || r.status === "cleaning",
  );
  if (active) {
    busyUI(true);
    void poll(active.id);
  }
}
void init().catch((e) => notify(e.message));
