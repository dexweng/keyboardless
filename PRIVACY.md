# 隱私與資料處理

keyboardless 不代管 API 金鑰、不提供共享 API 帳戶，也不包含分析追蹤或自動遙測。

- 錄音送至 OpenAI 轉錄；原始逐字稿及詞庫送至 OpenAI 整理。文字請求設 `store:false`，但這不代表供應商完全不保留資料；請自行查閱 [OpenAI 資料政策](https://developers.openai.com/api/docs/guides/your-data)。
- 金鑰由使用者填入，建議保存在 macOS Keychain；僅在本機記憶體及向 OpenAI 驗證請求時使用。設定介面不回傳原文金鑰。
- `.local/`（原始碼模式）或 `~/Library/Application Support/keyboardless/`（獨立 App） 保存錄音、逐字稿、詞庫、失敗與待送出錄音、費用帳目及本機日誌。這些是私人資料，請自行保護備份。Git 忽略不等於磁碟加密。
- 歷史紀錄刪除不會消除已發生的 API 支出；不含口述文字的費用帳目仍保留。退出 App 並刪除 `.local/`（原始碼模式）或 `~/Library/Application Support/keyboardless/`（獨立 App） 才會清除全部本機資料（先確認不再需要）。Keychain 金鑰需在設定中另行移除。
- 輔助使用用於全域快捷鍵、確認原欄位與貼上；麥克風用於收音。App 不自動送出訊息。
- 連線測試只查已儲存金鑰是否可存取所選模型，不傳送錄音，不驗證帳戶尚餘多少額度。
