import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { stat, readFile } from "node:fs/promises";
import { createHash } from "node:crypto";
const exec = promisify(execFile);
export async function prepareAudio(input: string, output: string) {
  if (process.env.KEYBOARDLESS_AUDIO_HELPER) {
    let duration: number;
    try {
      const result = await exec(process.env.KEYBOARDLESS_AUDIO_HELPER, [input, output], { timeout: 60000, maxBuffer: 65536 });
      duration = Number(JSON.parse(result.stdout).duration);
    } catch { throw new Error("音檔無法解碼。請使用有效的 WAV、MP3 或 M4A 音檔。"); }
    if (!Number.isFinite(duration) || duration <= 0 || (await stat(output)).size > 25000000)
      throw new Error("音訊長度或大小超出限制，請縮短後再試。");
    return { duration, audioHash: createHash("sha256").update(await readFile(input)).digest("hex") };
  }
  try {
    await exec(
      process.env.FFMPEG_PATH || "ffmpeg",
      [
        "-nostdin",
        "-hide_banner",
        "-loglevel",
        "error",
        "-protocol_whitelist",
        "file,pipe",
        "-format_whitelist",
        "wav,mp3,mov,matroska,webm",
        "-i",
        input,
        "-vn",
        "-ac",
        "1",
        "-ar",
        "16000",
        "-c:a",
        "pcm_s16le",
        "-fs",
        "25000001",
        "-y",
        output,
      ],
      { timeout: 60000, maxBuffer: 64 * 1024 },
    );
  } catch {
    throw new Error(
      "音檔無法解碼。請使用有效的 WAV、MP3、M4A 或 WebM 音檔，並確認已安裝 ffmpeg。",
    );
  }
  if ((await stat(output)).size > 25000000)
    throw new Error("解碼後音訊超過 25 MB，請縮短錄音後再試。");
  const probe = await exec(
    process.env.FFPROBE_PATH || "ffprobe",
    ["-v", "error", "-show_entries", "format=duration", "-of", "json", output],
    { timeout: 10000 },
  );
  const duration = Number(
    (JSON.parse(probe.stdout) as { format: { duration: string } }).format
      .duration,
  );
  if (!Number.isFinite(duration) || duration <= 0)
    throw new Error("音訊沒有有效長度。");
  return {
    duration,
    audioHash: createHash("sha256")
      .update(await readFile(input))
      .digest("hex"),
  };
}
