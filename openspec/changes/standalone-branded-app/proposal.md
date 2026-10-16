## Why
現有原始碼版需要安裝開發工具，無法直接分享給一般 macOS 使用者。獨立安裝包與一致的品牌設計可讓首次設定只剩填入自己的 API Key 與授權。
## What Changes
- 內建執行環境與原生音訊轉換，提供 Apple Silicon／Intel 通用 App 與 DMG。
- 將使用者資料保存在 Application Support；與原始碼服務隔離，避免錯連舊服務或把資料寫進 App。
- 套用使用者提供的 logo，調整黑白暖色階、細線卡片、曲線裝飾與單色圖表。
- 加入簽章、公證、校驗與乾淨路徑驗證；只有公證通過才能標示正式直接下載版。
## Capabilities
### New Capabilities
- `standalone-installation`: 無外部開發工具的安裝、資料與服務生命週期、簽章發布。
- `brand-interface`: 使用指定圖示及一致、可讀的介面風格。
### Modified Capabilities
無。
## Impact
原生 App 啟動／資料路徑、音訊轉換、後端封裝、品牌資源、建置與發布工作流程。保留既有語音模型、Keychain、快捷鍵與費用邏輯。WebM 匯入僅原始碼 ffmpeg 模式支援，獨立版以 WAV／MP3／M4A 為主並明示格式限制。
