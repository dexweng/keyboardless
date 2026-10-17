# 建置與發布

## 原始碼

執行 `npm ci`、`npm run check`、`bash macos/scripts/test.sh`、`python3 scripts/test-release.py` 與 `python3 scripts/release.py`。來源包採允許清單，排除 .env、.local、舊 Git 歷史及私人資料。SHA-256 與 SOURCE-MANIFEST.json 可驗證下載內容。不要從私人開發庫直接推送 Git 歷史。

## 獨立 App

建置環境需要 macOS、Xcode Command Line Tools、Node 24.11+ 與 npm；測試音訊需 ffmpeg。使用者安裝完成的 App 不需要這些工具。

```sh
npm ci
/usr/bin/python3 scripts/build-standalone.py
/usr/bin/python3 scripts/check-standalone.py
bash macos/scripts/package-dmg.sh
```

建置工具下載固定官方 Node 版本並驗證內建 SHA-256，產生含 arm64 與 x86_64 的通用 App。音訊轉換使用 Core Audio，依賴 LICENSE 完整隨包保留。預設只產生 ad-hoc 簽章的 `local-preview.dmg`，供本機驗證，不得宣稱已公證或要求使用者停用 Gatekeeper。

## 正式簽章與公證

先在 Xcode 的 Apple Account → Manage Certificates 建立 Developer ID Application 憑證。Apple Development 憑證不能代替它。憑證私鑰不可放入 Git、公開附件或聊天。

在本機使用 `xcrun notarytool store-credentials keyboardless-notary` 互動式保存公證登入至 Keychain；輸入需由帳戶持有人操作。設定下列非秘密值後重新建置：

```sh
export KEYBOARDLESS_SIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)'
export KEYBOARDLESS_NOTARY_PROFILE='keyboardless-notary'
/usr/bin/python3 scripts/build-standalone.py
/usr/bin/python3 scripts/check-standalone.py
bash macos/scripts/package-dmg.sh
```

腳本依序簽署內嵌程式與 App、開啟 hardened runtime、只對 Node 配置 JIT entitlement，再提交 App 公證、staple、Gatekeeper 檢查，最後簽署／公證／staple DMG。任一步失敗即停止。正式 DMG 不含 `local-preview` 後綴。

發布前應從掛載的唯讀 DMG 複製到不同資料夾或乾淨 Mac，驗證啟動、自己的 API Key、麥克風、快捷鍵與原游標貼上。以 PR 合入 main，CI 通過後建立版本 Release，附上 DMG、原始碼 ZIP 與 SHA-256。重新下載並比對檔案及標籤提交。

## 舊版升級

先退出舊 App，保留原資料備份。獨立 App 使用 `~/Library/Application Support/keyboardless/`；原始碼版的 `.local/` 不會自動遷移。可在首次開啟前只複製 `runs/`、`usage/`、`settings.json`、`api-settings.json`、`mac-pending/` 至新資料目錄；不可覆蓋已存在的新資料，勿複製 .env、log、runtime 或建置產物。Keychain 與快捷鍵偏好沿用相同識別；macOS 仍可能要求刷新既有權限。

[Apple 公證說明](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
