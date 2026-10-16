# keyboardless

macOS 語音輸入工具：自訂快捷鍵、按住或按一下切換錄音、保留中英原文的文字整理、原游標貼上、歷史、詞庫及用量費用統計。使用自己的 OpenAI API Key，直接向 OpenAI 支付 API 費用。

目前開發版本為 **0.6.0**，非 Typeless 官方產品。獨立 App 支援 macOS 14+、Apple Silicon 與 Intel。

## 直接安裝

正式 DMG 會發布在 [GitHub Releases](https://github.com/dexweng/keyboardless/releases)。請選不含 `local-preview` 的已公證版本；若最新版本仍只有 source.zip，代表直接下載版尚未完成發布。

1. 下載 DMG，將 keyboardless 拖入 Applications。
2. 開啟 App，在設定填入自己的 OpenAI API Key，按「儲存 API 設定」。
3. 允許麥克風與輔助使用，設定習慣的快捷鍵即可使用。

不需要安裝 Node、ffmpeg、Xcode 或開啟 Terminal。獨立 App 支援 WAV、MP3、M4A 匯入；WebM 請先轉成上述格式。資料保存在 `~/Library/Application Support/keyboardless/`，金鑰在 Keychain，更新 App 不會刪除資料。

## 從原始碼安裝

需要 macOS 14+、Xcode Command Line Tools、Node.js 24.11+（建議 24 LTS）、npm、ffmpeg／ffprobe，以及可用的 OpenAI API 帳戶。使用 Homebrew 時可安裝 `node@24` 與 `ffmpeg`；請確認 `node`、`npm`、`ffmpeg`、`ffprobe`、`xcrun` 在 PATH。

1. 解壓原始碼至自己的資料夾，保留整個資料夾，不要只移動建置出的 App。
2. 在 Terminal 執行 `npm ci`、`npm run check`、`bash macos/scripts/build.sh`。
3. 雙擊 `start-mac.command`（或執行 `bash start-mac.command`）；腳本先確認本機服務啟動，再開啟 App。
4. 在「設定 → 語音與整理」貼入自己的 API Key，按「儲存 API 設定」與「測試已儲存設定」。金鑰存入 macOS Keychain；不要貼到 issue、聊天或 Git。
5. 依 App 引導允許麥克風及輔助使用。預設按住 Control＋Option＋空白鍵說話，放開送出；可更改快捷鍵及錄音模式。

音訊與整理文字送至 OpenAI。英文保留英文，中英混合維持原樣；模型仍可能出錯，送出重要訊息前請核對。App 不會自動按 Enter 發送。

## 模型與費用

辨識維持 `gpt-transcribe`。新安裝預設整理 `gpt-5.4-nano-2026-03-17`，設定可切回 `gpt-5.4-mini-2026-03-17`。nano 品質需自行實測；模型存取權與額度以帳戶為準。設定頁目前支援 OpenAI，不接受任意供應商網址。

費用以 API 用量及記錄當時單價估算，不是帳單。語音可按秒計費，不能只看 tokens；缺失用量／未知價格不視為免費。既有帳目不會因切模型重新計價。[官方價格](https://developers.openai.com/api/docs/pricing)

## 資料與金鑰

紀錄、錄音、詞庫、待送出錄音及費用帳目在原始碼模式保存在專案 `.local/`，獨立 App 則使用 Application Support，不會自動同步。原始碼服務為 **127.0.0.1:3018**；獨立 App 為 **127.0.0.1:3028**，不要對外代理或開放。`start.command` 開啟進階網頁實驗室。

舊版 `.env` 使用者可按「將現有金鑰移至 Keychain」；驗證寫入後才移除 `.env` 的金鑰行。按「移除金鑰」後不回退到舊環境金鑰。原始碼環境仍可用 `.env.example` 或環境變數設定，但 Keychain 是建議方式。

## 開發與發布

- `npm run check`：TypeScript、前端建置、隔離測試（不需要真實 API）。
- `bash macos/scripts/test.sh`：原生狀態與 API 測試。
- `bash macos/scripts/build.sh`：本機建置，使用 ad-hoc 簽章。
- `python3 scripts/test-release.py`：發布防洩漏回歸測試。
- `/usr/bin/python3 scripts/build-standalone.py`：建置內建執行環境的通用 App（預設本機預覽簽章）。
- `/usr/bin/python3 scripts/check-standalone.py`：搬移、精簡 PATH、音訊與隔離驗證。
- `bash macos/scripts/package-dmg.sh`：製作 DMG；正式簽章及公證流程見發布文件。
- `python3 scripts/release.py`：產生 `.local/releases/` 的安全原始碼包與 SHA-256。

安裝資料夾移動、更新程式或 ad-hoc 重編譯後，需重建 App；macOS 可能要求重新允許既有權限。請勿停用 Gatekeeper 或 SIP。

[隱私](PRIVACY.md) · [安全](SECURITY.md) · [貢獻](CONTRIBUTING.md) · [發布流程](docs/release.md) · [第三方授權](THIRD_PARTY_NOTICES.md)

採 [MIT License](LICENSE)。
