## 1. 判斷規則
- [x] 1.1 新增視窗層級保護與保護層級選擇規則；以 16 種視窗組合與 6 種情境原生測試驗證。
- [x] 1.2 擷取與貼上前檢查依保護層級分流；原生 App 維持欄位精準檢查，32 種欄位組合測試仍通過。
## 2. 驗收
- [x] 2.1 以 Developer ID 重新建置獨立 App、check-standalone 通過，並對前景 Chrome 實測擷取與貼上前檢查（不實際貼上）通過。
- [ ] 2.2 Dex 在 VS Code 與 Chrome 實際口述，確認文字貼到游標位置；通過後歸檔。

## Validation — 2026-11-04
- `bash macos/scripts/test.sh` 全數通過，含新增「16 window guards and insertion scope fallback」。
- 前景 Chrome：焦點欄位查詢 -25212，改用視窗層級擷取，2 秒後檢查 sameApp／sameWindow 皆為 true、secureInput false，判定可貼。
- 新版 designated requirement 與 0.6.0 安裝版相同（local.dex.voice＋FQ8Z9PZX67），輔助使用與麥克風權限沿用。
