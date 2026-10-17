import express from "express";
import multer from "multer";
import { z } from "zod";
import {
  mkdir,
  readFile,
  writeFile,
  copyFile,
  rm,
  readdir,
  stat,
} from "node:fs/promises";
import { resolve, join, extname } from "node:path";
import { randomUUID, randomBytes, createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import { realpathSync } from "node:fs";
import { Store } from "./store.ts";
import { prepareAudio } from "./audio.ts";
import { OpenAIProvider, type Provider } from "./provider.ts";
import { PROMPT_VERSION, costUnknown, type Run } from "./model.ts";
import { processRun } from "./engine.ts";
import { APISettings, keychainStore, settingsInput, type SecretStore } from "./api-settings.ts";
import { UsageLedger, usageSummary, PRICE } from "./usage.ts";
import { insights } from "./insights.ts";
const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
export async function createApp(
  options: { dataRoot?: string; provider?: Provider; port?: number; secrets?: SecretStore; envPath?: string } = {},
) {
  const port = options.port ?? 3018;
  const store = new Store(options.dataRoot ?? process.env.KEYBOARDLESS_DATA_ROOT ?? join(root, ".local"));
  await store.init();
  const uploadDir = join(store.root, "uploads");
  await mkdir(uploadDir, { recursive: true, mode: 0o700 });
  for (const f of await readdir(uploadDir))
    await rm(join(uploadDir, f), { force: true });
  for (const r of await store.list())
    if (r.status === "cleaning" || r.status === "transcribing") {
      r.failedStage = r.status === "cleaning" ? "cleanup" : "transcribe";
      r.status = "failed";
      r.error = "上次執行中斷；已保留結果，可手動重試。";
      await store.save(r);
    }
  const ledger = new UsageLedger(store);
  await ledger.init(await store.list());
  const token = randomBytes(32).toString("hex");
  const app = express();
  let busy = false;
  let preferencesBusy = false;
  let activeId: string | null = null;
  const preferences = new APISettings(options.envPath ?? process.env.KEYBOARDLESS_ENV_FILE ?? join(root, ".env"), store.root,
    options.secrets ?? keychainStore(process.env.KEYBOARDLESS_KEYCHAIN_HELPER ?? join(root, "macos/build/keyboardless.app/Contents/MacOS/Keychain")));
  await preferences.init();
  const models = () => preferences.models();
  const key = () => preferences.key();
  const provider = options.provider ?? new OpenAIProvider(key);
  app.disable("x-powered-by");
  app.use((req, res, next) => {
    res.set({
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
      "Referrer-Policy": "no-referrer",
      "Content-Security-Policy":
        "default-src 'self'; script-src 'self'; style-src 'self'; media-src 'self' blob:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'",
    });
    const allowed = [`127.0.0.1:${port}`, `localhost:${port}`];
    if (!allowed.includes(req.headers.host || ""))
      return res.status(403).json({ error: "不接受這個主機來源。" });
    if (
      req.headers.origin &&
      !allowed.map((v) => "http://" + v).includes(req.headers.origin)
    )
      return res.status(403).json({ error: "不接受跨網站請求。" });
    if (req.headers["sec-fetch-site"] === "cross-site")
      return res.status(403).json({ error: "不接受跨網站請求。" });
    if (
      req.path.startsWith("/api/") &&
      !["GET", "HEAD"].includes(req.method) &&
      req.headers["x-pilot-token"] !== token
    )
      return res.status(403).json({ error: "請重新整理頁面後再試。" });
    if (preferencesBusy && !["GET", "HEAD"].includes(req.method)) return res.status(409).json({error:"API 設定處理中，請稍後再試。"});
    next();
  });
  app.use(express.json({ limit: "256kb" }));
  const upload = multer({
    dest: uploadDir,
    limits: { fileSize: 24000000, files: 1, fields: 8 },
    fileFilter: (_req, file, cb) => {
      if (process.env.KEYBOARDLESS_AUDIO_HELPER && extname(file.originalname).toLowerCase() === ".webm")
        return cb(new Error("請使用 WAV、MP3 或 M4A；獨立 App 不支援 WebM 匯入。"));
      if (
        ![".wav", ".mp3", ".m4a", ".webm", ".mp4"].includes(
          extname(file.originalname).toLowerCase(),
        )
      )
        cb(new Error("請匯入 WAV、MP3、M4A 或 WebM 音檔。"));
      else cb(null, true);
    },
  });
  const idSchema = z.string().uuid();
  const text = z.string().max(40000);
  const small = z.string().max(1000);
  const baseline = z
    .object({
      text: text.min(1),
      inputMethod: z.enum(["same_file", "reread", "speaker_replay", "unknown"]),
      version: small.min(1),
      settings: small.min(1),
      recordedAt: z.string().datetime(),
    })
    .nullable();
  const review = z
    .object({
      meaningErrors: text,
      omissions: text,
      terms: text,
      scriptIssues: text,
      tone: text,
      usability: z.enum(["direct", "minor", "rewrite"]),
      corrected: text,
      notes: text,
      reviewedAt: z.string().datetime(),
      blindOrder: z
        .array(z.enum(["candidate", "typeless"]))
        .length(2)
        .nullable()
        .optional(),
    })
    .nullable();
  const patchSchema = z
    .object({
      baseline: baseline.optional(),
      review: review.optional(),
      reference: z
        .object({ verbatim: text, meaning: text, verified: z.boolean() })
        .optional(),
      endToEndMs: z.number().finite().min(0).max(86400000).optional(),
    })
    .strict();
  async function runById(id: unknown) {
    return store.get(idSchema.parse(id));
  }
  function launch(run: Run, cleanupOnly = false) {
    activeId = run.id;
    void processRun(run, store, provider, cleanupOnly)
      .catch(() => {})
      .finally(() => {
        busy = false;
        activeId = null;
      });
  }
  app.get("/api/config", async (_req, res) =>
    res.json({
      app: "dex-voice-pilot",
      nativeProtocol: 1,
      instanceID: process.env.KEYBOARDLESS_INSTANCE ?? null,
      nativeAudio: Boolean(process.env.KEYBOARDLESS_AUDIO_HELPER),
      token,
      ...preferences.public(),
      provider: "OpenAI",
      models: models(),
      settings: await store.settings(),
      port,
      maxUploadMB: 24,
      pricingChecked: PRICE.version,
    }),
  );
  app.put("/api/preferences", async (req, res) => {
    if (busy) return res.status(409).json({error:"請等目前口述處理完成再更改模型或金鑰。"});
    const input = settingsInput.safeParse(req.body);
    if (!input.success) return res.status(400).json({error:"設定格式不正確，請重新選擇模型。"});
    preferencesBusy = true;
    try { res.json(await preferences.save(input.data)); }
    catch (error) { res.status(400).json({error: error instanceof Error ? error.message : "無法保存設定。"}); }
    finally { preferencesBusy = false; }
  });
  app.post("/api/preferences/check", async (_req, res) => {
    if (busy) return res.status(409).json({error:"請等口述處理完成再測試。"});
    try { await new OpenAIProvider(key).check(models()); res.json({ok:true}); }
    catch (error) { res.status(400).json({error:error instanceof Error ? error.message : "連線測試失敗。"}); }
  });
  app.put("/api/glossary", async (req, res) => {
    const settings = z
      .object({ glossary: z.array(z.string().trim().min(1).max(100)).max(300) })
      .parse(req.body);
    await store.setSettings({ glossary: [...new Set(settings.glossary)] });
    res.json(await store.settings());
  });
  app.get("/api/cases", async (_req, res) =>
    res
      .type("json")
      .send(await readFile(join(root, "fixtures/cases.json"), "utf8")),
  );
  app.get("/api/insights", async (_req, res) =>
    res.json(insights(await store.list())),
  );
  app.get("/api/usage", async (req, res) => {
    const period = z
      .enum(["today", "month", "all"])
      .parse(req.query.period ?? "all");
    res.json(usageSummary(await ledger.list(), period));
  });
  app.get("/api/runs", async (_req, res) => res.json(await store.list()));
  app.get("/api/report", async (_req, res) => {
    const runs = await store.list();
    const done = runs.filter((r) => r.status === "done");
    const caseIds = new Set(
      done
        .filter(
          (r) =>
            r.sourceType === "scripted" &&
            r.reference.verified &&
            r.review &&
            r.baseline,
        )
        .map((r) => r.caseId)
        .filter(Boolean),
    );
    const real = new Set(
      done
        .filter(
          (r) =>
            r.sourceType === "real" &&
            r.reference.verified &&
            r.review &&
            r.baseline,
        )
        .map((r) => r.audioHash),
    );
    const pending = [];
    if (caseIds.size < 12)
      pending.push(`已具基線、人工核對及評分的合成題 ${caseIds.size}/12`);
    if (real.size < 5)
      pending.push(`已具基線、人工核對及評分的真實語音 ${real.size}/5`);
    const unknownCosts = runs.filter(
      (r) => r.costs.transcribe.usd === null || r.costs.cleanup.usd === null,
    ).length;
    const report = {
      generatedAt: new Date().toISOString(),
      verification: pending.length ? "未完成" : "樣本已齊備，仍需 Dex 判斷",
      limitations: [
        "小樣本不能證明長期可靠度",
        "不同輸入方式不得視為相同音訊比較",
        "費用為估算，失敗請求可能仍有供應商計費",
      ],
      pending,
      knownEstimatedUSD: runs.reduce(
        (s, r) =>
          s + (r.costs.transcribe.usd ?? 0) + (r.costs.cleanup.usd ?? 0),
        0,
      ),
      runsWithUnknownCost: unknownCosts,
      runs,
    };
    res
      .set(
        "Content-Disposition",
        'attachment; filename="dictation-report.json"',
      )
      .json(report);
  });
  app.post(
    "/api/runs",
    (req, res, next) => {
      if (busy)
        return res.status(409).json({ error: "已有一筆正在處理，請稍候。" });
      busy = true;
      next();
    },
    upload.single("audio"),
    async (req, res, next) => {
      let id: string | null = null;
      try {
        if (!req.file) throw new Error("請先錄音或選擇音檔。");
        const sourceType = z
          .enum(["scripted", "real"])
          .parse(req.body.sourceType);
        const caseId = z
          .string()
          .regex(/^T(0[1-9]|1[0-2])$/)
          .nullable()
          .parse(req.body.caseId || null);
        const timingOrigin = z
          .enum(["recording_stop", "upload_submit"])
          .parse(req.body.timingOrigin || "upload_submit");
        id = randomUUID();
        const dir = store.dir(id);
        await mkdir(dir, { mode: 0o700 });
        await copyFile(
          req.file.path,
          join(dir, "original" + extname(req.file.originalname).toLowerCase()),
        );
        const audio = await prepareAudio(
          req.file.path,
          join(dir, "normalized.wav"),
        );
        const { glossary } = await store.settings();
        const run: Run = {
          id,
          parentId: null,
          createdAt: new Date().toISOString(),
          sourceType,
          caseId,
          filename: req.file.originalname,
          ...audio,
          status: "transcribing",
          rawText: null,
          cleanText: null,
          error: null,
          failedStage: null,
          models: models(),
          glossary,
          glossaryVersion: createHash("sha256")
            .update(JSON.stringify(glossary))
            .digest("hex"),
          promptVersion: PROMPT_VERSION,
          transcriptionSettings: {
            model: models().transcribe,
            glossary: [...glossary],
          },
          timings: {
            transcribeMs: null,
            cleanupMs: null,
            serverMs: null,
            endToEndMs: null,
            timingOrigin,
          },
          usage: { transcribe: null, cleanup: null },
          costs: { transcribe: costUnknown(), cleanup: costUnknown() },
          baseline: null,
          reference: { verbatim: "", meaning: "", verified: false },
          review: null,
        };
        await store.save(run);
        await rm(req.file.path, { force: true });
        launch(run);
        res.status(202).json(run);
      } catch (error) {
        if (id) await store.remove(id);
        if (req.file) await rm(req.file.path, { force: true });
        busy = false;
        next(error);
      }
    },
  );
  app.get("/api/runs/:id", async (req, res) =>
    res.json(await runById(req.params.id)),
  );
  app.get("/api/runs/:id/audio", async (req, res) => {
    const r = await runById(req.params.id);
    res
      .type("audio/wav")
      .sendFile(join(store.dir(r.id), "normalized.wav"), { dotfiles: "allow" });
  });
  app.patch("/api/runs/:id", async (req, res) => {
    const patch = patchSchema.parse(req.body);
    const r = await runById(req.params.id);
    if (activeId === r.id)
      return res.status(409).json({ error: "請等本次處理結束再儲存。" });
    if (patch.baseline !== undefined) r.baseline = patch.baseline;
    if (patch.review !== undefined) r.review = patch.review;
    if (patch.reference) r.reference = patch.reference;
    if (patch.endToEndMs !== undefined && r.timings.endToEndMs === null)
      r.timings.endToEndMs = patch.endToEndMs;
    await store.save(r);
    res.json(r);
  });
  app.post("/api/runs/:id/retry", async (req, res, next) => {
    if (busy)
      return res.status(409).json({ error: "已有一筆正在處理，請稍候。" });
    busy = true;
    let id: string | null = null;
    try {
      const old = await runById(req.params.id);
      const mode = z.enum(["cleanup", "full"]).parse(req.body.mode);
      if (mode === "cleanup" && !old.rawText)
        throw new Error("尚無原始轉錄，請重新辨識。");
      id = randomUUID();
      await mkdir(store.dir(id), { mode: 0o700 });
      for (const file of await readdir(store.dir(old.id)))
        if (file !== "run.json" && !file.endsWith(".tmp"))
          await copyFile(
            join(store.dir(old.id), file),
            join(store.dir(id), file),
          );
      const { glossary } = await store.settings();
      const r: Run = {
        ...old,
        id,
        parentId: old.id,
        rootId: old.rootId ?? old.parentId ?? old.id,
        rootCreatedAt: old.rootCreatedAt ?? old.createdAt,
        createdAt: new Date().toISOString(),
        status: mode === "cleanup" ? "cleaning" : "transcribing",
        rawText: mode === "cleanup" ? old.rawText : null,
        cleanText: null,
        error: null,
        failedStage: null,
        models: {
          transcribe:
            mode === "cleanup" ? old.models.transcribe : models().transcribe,
          cleanup: models().cleanup,
        },
        glossary,
        glossaryVersion: createHash("sha256")
          .update(JSON.stringify(glossary))
          .digest("hex"),
        promptVersion: PROMPT_VERSION,
        transcriptionSettings:
          mode === "cleanup"
            ? (old.transcriptionSettings ?? {
                model: old.models.transcribe,
                glossary: old.glossary,
              })
            : { model: models().transcribe, glossary: [...glossary] },
        review: null,
        timings: {
          transcribeMs: null,
          cleanupMs: null,
          serverMs: null,
          endToEndMs: null,
          timingOrigin: "retry_submit",
        },
        usage: { transcribe: null, cleanup: null },
        costs: {
          transcribe:
            mode === "cleanup"
              ? { ...costUnknown("沿用父紀錄原始轉錄；本次未呼叫辨識"), usd: 0 }
              : costUnknown(),
          cleanup: costUnknown(),
        },
      };
      await store.save(r);
      launch(r, mode === "cleanup");
      res.status(202).json(r);
    } catch (error) {
      if (id) await store.remove(id);
      busy = false;
      next(error);
    }
  });
  app.delete("/api/runs/:id", async (req, res) => {
    const r = await runById(req.params.id);
    if (activeId === r.id)
      return res.status(409).json({ error: "請等處理結束再刪除。" });
    await store.remove(r.id);
    res.status(204).end();
  });
  app.use(express.static(join(root, "public"), { etag: false }));
  app.use(
    (
      err: unknown,
      req: express.Request,
      res: express.Response,
      _next: express.NextFunction,
    ) => {
      if (req.path === "/api/runs" && req.method === "POST" && !activeId)
        busy = false;
      if (err instanceof z.ZodError)
        return res.status(400).json({ error: "欄位格式不正確，請檢查輸入。" });
      if (err instanceof multer.MulterError)
        return res
          .status(400)
          .json({ error: "檔案超過 24 MB 或上傳格式不正確。" });
      const e = err as NodeJS.ErrnoException;
      if (e.code === "ENOENT")
        return res.status(404).json({ error: "找不到這筆資料。" });
      const safe =
        e.message && /^(音檔|解碼|音訊|請|尚無)/.test(e.message)
          ? e.message
          : "無法完成操作，請重新整理後再試。";
      res.status(400).json({ error: safe });
    },
  );
  return { app, store };
}
if (
  process.argv[1] &&
  realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))
) {
  const at = process.argv.indexOf("--port");
  const port = at >= 0 ? Number(process.argv[at + 1]) : 3018;
  if (!Number.isInteger(port) || port < 1024 || port > 65535)
    throw new Error("Invalid port");
  const { app } = await createApp({ port });
  const parentPID = Number(process.env.KEYBOARDLESS_PARENT_PID);
  if (Number.isInteger(parentPID) && parentPID > 1) {
    setInterval(() => {
      if (process.ppid !== parentPID) process.exit(0);
      try { process.kill(parentPID, 0); } catch { process.exit(0); }
    }, 1000).unref();
  }
  const server = app.listen(port, "127.0.0.1", () =>
    console.log(`語音實驗室：http://127.0.0.1:${port}`),
  );
  server.on("error", () => {
    console.error(`無法啟動，port ${port} 可能已占用。`);
    process.exitCode = 1;
  });
}
