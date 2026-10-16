# 第三方套件與資產

本專案程式採 MIT。第三方依賴仍依各自授權；精確版本記錄於 package-lock.json，`npm ci` 後可查看各套件 LICENSE。

主要直接依賴：Express、Multer、Zod（MIT）；開發工具 TypeScript（Apache-2.0）、esbuild、tsx、Prettier 與 DefinitelyTyped 型別（MIT）。原始碼模式的 Node.js、npm 與 ffmpeg 由開發者另行安裝。獨立 App 內建官方 Node.js 24.22.0，授權及其內含第三方聲明完整放在 App Resources/NODE-LICENSE.txt；JavaScript 依賴的 LICENSE 隨 node_modules 保留。獨立 App 使用 macOS Core Audio 轉換音訊，不散布 ffmpeg。

原生介面使用 macOS 系統元件及系統 symbol。錄音提示音為此專案產生的 PCM 波形，隨本專案 MIT 授權。公開包不包含 Typeless 擷取程式、截圖或資產。keyboardless 與 Typeless 無隸屬關係。

keyboardless 品牌圖示由專案維護者提供，原始圖檔及轉製 icns 供本專案顯示使用。
