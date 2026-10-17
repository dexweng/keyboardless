## Purpose
讓 macOS 使用者下載獨立安裝包即可設定自己的語音輸入服務，不必安裝開發工具，並讓使用資料、服務埠及發布簽章有清楚且可驗證的邊界，保護既有本機內容。
## ADDED Requirements
### Requirement: 獨立安裝與資料
App SHALL 內建所需執行環境，使用本機 Application Support 保存資料，金鑰仍使用 Keychain，且不依賴維護者的路徑或機密。
#### Scenario: 乾淨路徑啟動
- **WHEN** 使用者將 App 放到另一個資料夾且 PATH 不含開發工具
- **THEN** 服務可啟動，WAV／MP3／M4A 可轉換，設定可使用自己的金鑰
#### Scenario: 埠已占用或退出
- **WHEN** 其他服務占用指定埠，或 App 已退出
- **THEN** App 不連到非本次啟動的服務；自己啟動的服務隨 App 結束
### Requirement: 可驗證發布
正式直接下載版 MUST 使用 Developer ID 簽章、Apple 公證及校驗檔；未完成時 SHALL 明確標示本機預覽而非宣稱正式版。
#### Scenario: 發布驗證
- **WHEN** 發布 DMG
- **THEN** 驗證簽章、公證票據、架構、內含檔案與秘密掃描，不包含個人資料
