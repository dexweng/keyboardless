## 1. 獨立執行
- [x] 1.1 分離 App 資源與使用者資料、服務識別與生命週期；以隔離路徑及埠衝突測試驗證。
- [x] 1.2 加入原生音訊轉換與格式能力；以合成音訊、無效檔及限制測試驗證。
- [x] 1.3 封裝已驗證 Node、服務及授權；建置通用 App 並以精簡 PATH 啟動驗證。
## 2. 品牌介面
- [x] 2.1 套用 logo/icns、設計 token、細線卡片與單色圖表；建置並實際開啟視窗確認。
## 3. 發布
- [x] 3.1 完成簽章／公證／DMG 腳本、文件與 CI；檢查私人資料排除及套件完整性。
- [x] 3.2 取得 Developer ID 簽章並通過 Apple 公證、stapler 與 Gatekeeper；發布前驗證下載包。
- [x] 3.3 PR、CI、正式 Release 與本機升級驗收，保存驗證結果後歸檔。

## Validation — 2026-10-17
- 本機 19 項後端測試、原生測試與通用 App 建置通過；修正後的 Apple Silicon／Intel CI 全部通過（e2314f0）。
- 正式唯讀 DMG 搬移測試通過：精簡 PATH、WAV／MP3／M4A、無效音訊、埠衝突、父程序退出與未授權修改。
- App 與 DMG 均通過 Apple 公證、stapler 與 Gatekeeper。App 申請 02f6fa45-0f64-4f21-8c71-fd667aba0007；DMG 申請 b7f4ec12-a500-4b5c-a0b9-6ac2e81c7abb。
- App 與原始碼共 1,419 個檔案比對實際 API Key 未發現金鑰；掃描未輸出或儲存值。來源允許清單排除個人資料及私人歷史。
- 已備份並校驗搬移既有使用資料；使用者驗收混語口述、提示音、浮動條、貼上與去白邊 logo。
- 後續發現舊開發 App 影響啟動，已壓縮備份並取消舊版註冊。修正每次啟動顯示主視窗、權限恢復後重新註冊快捷鍵；Finder 啟動及權限就緒狀態已驗證，修正後已有新錄音完成。
- [PR #2](https://github.com/dexweng/keyboardless/pull/2) 已合併（b501f41）；[v0.6.0](https://github.com/dexweng/keyboardless/releases/tag/v0.6.0) 已發布。公開 DMG／原始碼下載與本機已驗證檔案及 SHA-256 完全相符。
