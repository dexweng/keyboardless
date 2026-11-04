## Why
在 VS Code、Chrome、Slack、Notion、Claude 桌面版等 Chromium／Electron App 口述時，約 95% 顯示「原游標位置無法確認」而不貼上。2026-11-04 實測：這些 App 對焦點欄位查詢一律回 kAXErrorNoValue（-25212），開啟 AXManualAccessibility 或 AXEnhancedUserInterface 也無法取得；原本「無法取得目標資訊就不輸入」的規則因此在這類 App 永遠不成立。原生 App（Terminal、LINE）可正常取得欄位與游標。
## What Changes
- 能取得焦點欄位與游標時，維持原本精準檢查：同 App、同欄位、同選取範圍、非密碼欄。
- 取得不到欄位或游標時，改以同 App、同焦點視窗、且系統安全輸入未開啟作為保護，貼到當下游標位置。
- 密碼欄、切換 App、切換視窗、未授權輔助使用時仍不自動輸入，改提示複製。
- 診斷檔記錄採用的保護層級與比對結果，不含口述或欄位文字。
## Capabilities
### New Capabilities
- `focus-safe-insertion`: 自動貼上的焦點保護規則，含 Chromium／Electron App 的視窗層級備援。
### Modified Capabilities
無。
## Impact
原生 App 的 `TextTarget` 擷取與貼上前檢查（macos/Sources/Input.swift、Core.swift）與原生測試。同一視窗內，等待結果期間若使用者點到另一欄位，文字會貼到新的游標位置；這是為了讓 Chromium 類 App 可用而接受的取捨。剪貼簿保護、不按 Enter、不覆寫整欄等既有規則不變。
