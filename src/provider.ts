import { readFile } from "node:fs/promises";
import { CLEANUP_INSTRUCTIONS, type Usage } from "./model.ts";
export interface Result {
  text: string;
  usage: Usage;
}
export interface Provider {
  transcribe(path: string, model: string, glossary: string[]): Promise<Result>;
  clean(text: string, model: string, glossary: string[]): Promise<Result>;
}
export class ServiceError extends Error {
  constructor(
    message: string,
    public usage: Usage = null,
  ) {
    super(message);
  }
}
export class OpenAIProvider implements Provider {
  constructor(
    private key: () => string,
    private request: typeof fetch = fetch,
  ) {}
  private async call(
    endpoint: string,
    body: BodyInit,
    json = false,
  ): Promise<Record<string, unknown>> {
    const key = this.key();
    if (!key)
      throw new ServiceError(
        "尚未設定 OpenAI API 金鑰，請執行「設定模型金鑰.command」。",
      );
    let response: Response;
    try {
      response = await this.request("https://api.openai.com/v1/" + endpoint, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${key}`,
          ...(json ? { "Content-Type": "application/json" } : {}),
        },
        body,
        signal: AbortSignal.timeout(120000),
        redirect: "error",
      });
    } catch {
      throw new ServiceError(
        "模型服務連線失敗或等待超過兩分鐘。已保留本機資料，可手動重試。",
      );
    }
    let payload: Record<string, unknown>;
    try {
      payload = (await response.json()) as Record<string, unknown>;
    } catch {
      throw new ServiceError("模型服務回傳無法辨識的格式。");
    }
    if (!response.ok) {
      const messages: Record<number, string> = {
        401: "API 金鑰無效，請重新設定。",
        403: "帳戶無權限使用此模型。",
        429: "API 額度不足或請求受限，請檢查帳務後重試。",
        400: "模型不接受這次輸入，請確認模型名稱與音訊格式。",
        404: "此帳戶找不到指定模型，請確認模型設定。",
      };
      throw new ServiceError(
        messages[response.status] ||
          `模型服務暫時失敗（HTTP ${response.status}），可手動重試。`,
        (payload.usage as Usage) ?? null,
      );
    }
    return payload;
  }

  async check(models: {transcribe:string;cleanup:string}): Promise<void> {
    if (!this.key()) throw new ServiceError("尚未設定 OpenAI 金鑰。");
    for (const model of [models.transcribe, models.cleanup]) {
      let response: Response;
      try { response = await this.request("https://api.openai.com/v1/models/" + encodeURIComponent(model), {
        headers: {Authorization: `Bearer ${this.key()}`}, redirect: "error", signal: AbortSignal.timeout(15000),
      }); } catch { throw new ServiceError("無法連到 OpenAI，請檢查網路。"); }
      if (!response.ok) throw new ServiceError(response.status === 401 ? "API 金鑰無效。" : "此帳戶目前無法讀取所選模型，請檢查模型權限或稍後重試。");
    }
  }

  async transcribe(
    path: string,
    model: string,
    glossary: string[],
  ): Promise<Result> {
    const data = new FormData();
    data.set(
      "file",
      new Blob([new Uint8Array(await readFile(path))], { type: "audio/wav" }),
      "recording.wav",
    );
    data.set("model", model);
    data.set(
      "prompt",
      "請忠實轉錄中英夾雜語音，保留改口與否定。專有名詞拼字參考：" +
        glossary.join("、"),
    );
    const r = await this.call("audio/transcriptions", data);
    if (typeof r.text !== "string" || !r.text.trim())
      throw new ServiceError(
        "未辨識出文字，請檢查音訊是否有清楚的人聲。",
        (r.usage as Usage) ?? null,
      );
    return { text: r.text, usage: (r.usage as Usage) ?? null };
  }
  async clean(
    text: string,
    model: string,
    glossary: string[],
  ): Promise<Result> {
    const r = await this.call(
      "responses",
      JSON.stringify({
        model,
        store: false,
        instructions: CLEANUP_INSTRUCTIONS,
        input: JSON.stringify({ transcript: text, glossary }),
        reasoning: { effort: "low" },
        max_output_tokens: 6000,
      }),
      true,
    );
    if (r.status !== "completed")
      throw new ServiceError(
        "整理未完整完成，原始轉錄已保留，請重試。",
        (r.usage as Usage) ?? null,
      );
    const output =
      (r.output as
        | Array<{
            type: string;
            content?: Array<{ type: string; text?: string }>;
          }>
        | undefined) || [];
    const clean = output
      .filter((v) => v.type === "message")
      .flatMap((v) => v.content || [])
      .filter((v) => v.type === "output_text")
      .map((v) => v.text || "")
      .join("\n");
    if (!clean.trim())
      throw new ServiceError(
        "整理結果為空，原始轉錄已保留。",
        (r.usage as Usage) ?? null,
      );
    return { text: clean, usage: (r.usage as Usage) ?? null };
  }
}
