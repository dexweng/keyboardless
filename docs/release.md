# 發布檢查

本版交付可重建原始碼。請先從 README 在另一個路徑完成 `npm ci`、測試與 App 建置。

1. 執行 `npm run check`、原生測試及 `python3 scripts/test-release.py`。
2. 在私人原庫執行 `python3 scripts/release.py --history`。工具只回報物件編號，不輸出疑似秘密。即使通過也不要發布私人歷史。
3. 執行 `python3 scripts/release.py`；檢查 ZIP 與 SOURCE-MANIFEST.json。它只匯出允許清單中的程式、合成測試和公開文件，不含 .git、.env、.local、舊截圖及私人規劃文件。
4. 解壓到全新資料夾，人工複核後建立全新 Git repository；第一次 commit 只含這份公開包。不要從私人庫 push --all，也不要加入私人庫 remote 後直接推送歷史。
5. 在 GitHub 建立公開 repo，啟用秘密掃描／push protection（可用時），發布 source ZIP 及 SHA-256。發布前逐項確認 repo、授權與下載內容。

不要把目前本機 build/keyboardless.app 直接當下載版：它包含本機專案及 Node 路徑。一般使用者的獨立 App 下載版需另完成內嵌執行環境與依賴授權、Apple Developer ID 簽章、公證、乾淨 Mac 安裝與升級測試。沒有發布者憑證時，不宣稱已公證。

參考：[Apple 公證](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)、[GitHub 授權](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/licensing-a-repository)。
