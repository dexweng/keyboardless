## Context
見 proposal.md。現有 App 內含絕對原始碼路徑，依賴 Node/tsx/ffmpeg，資料在專案 .local；公開版須改為唯讀 App 與獨立可寫資料目錄。
## Goals / Non-Goals
目標為 macOS 14+ 通用 App、DMG、Developer ID 簽章與公證；保留目前辨識與整理流程。不重做模型、不增加登入或訂閱。
## Decisions
- 內建經官方 SHA-256 驗證的 Node 24 通用二進位與編譯後服務；保留第三方授權。原生 Core Audio 轉換 WAV/MP3/M4A，避免重新分發多個 Homebrew 動態依賴；原始碼模式保留 ffmpeg/WebM。
- 正式 App 資料放 Application Support/keyboardless；本機 3028 埠與 3018 原始碼服務隔離。每次啟動使用隨機服務識別，退出終止自己服務，子程序偵測父程序退出。
- Logo 保留中央圖形，依使用者要求移除外圍白邊，讓黑色圓角區塊填滿，再轉成標準 icns；墨黑／暖白設計 token 統一原生介面，低對比曲線僅作裝飾，圖表資料標記保持高對比。
- 使用由內而外簽章、hardened runtime、Node JIT entitlement，notarytool 與 stapler；缺正式憑證時可建置本機預覽，但禁止發布為已公證版。
## Risks / Trade-offs
- [舊版權限與資料] → 保留 bundle identifier 與 Keychain service；先備份、測試後才安裝，不在建置時自動搬動使用者資料。
- [Core Audio 格式限制] → 獨立版明示可支援格式並拒絕 WebM；原生錄音為 WAV，不受影響。
- [憑證需本人建立] → 完成 App 後由本人在 Xcode 建立憑證，秘密不進 Git。
## Migration Plan
建置到獨立 staging，完成無外部工具與異路徑驗證、介面檢查後，接上正式簽章／公證，再以 PR 與 Release 發布。原 App 保留備份，既有資料先安全複製至新目錄且不得覆蓋已存在資料。
