# 第三方套件與資產

本專案程式採 MIT。第三方依賴仍依各自授權；精確版本記錄於 package-lock.json，`npm ci` 後可查看各套件 LICENSE。

主要直接依賴：Express、Multer、Zod（MIT）；開發工具 TypeScript（Apache-2.0）、esbuild、tsx、Prettier 與 DefinitelyTyped 型別（MIT）。Node.js、npm 與 ffmpeg 由使用者另外安裝，本原始碼包不重新散布其二進位；ffmpeg 實際授權取決於安裝組態。

原生介面使用 macOS 系統元件及系統 symbol。錄音提示音為此專案產生的 PCM 波形，隨本專案 MIT 授權。公開包不包含 Typeless 擷取程式、截圖或資產。keyboardless 與 Typeless 無隸屬關係。
