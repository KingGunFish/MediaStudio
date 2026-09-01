# Media Studio (Electron)

把视频/GIF 转为透明背景 GIF 的桌面应用。

## 架构

```
electron-app/
├── binding.gyp                # node-gyp 配置(N-API addon)
├── package.json
├── tsconfig.json / .main.json / .renderer.json
├── vite.config.ts             # Vite (renderer 打包)
├── electron-builder.yml       # 安装包配置
├── native/
│   └── media_studio_addon.cpp # N-API 包装(调 libmedia_studio.{so,dll,dylib})
├── src/
│   ├── main/main.ts           # Electron 主进程 + IPC handlers
│   ├── preload/preload.ts     # contextBridge 安全桥
│   └── renderer/              # React + Vite 前端
│       ├── index.html
│       └── src/
│           ├── main.tsx
│           ├── App.tsx
│           ├── pages/         # Converter / Keying / History / Settings
│           ├── components/    # Dropzone / ProgressBar
│           └── lib/           # mediaStudio.ts (TS wrapper)
└── dist/                      # 编译产物
```

## 开发

```bash
# 1. 装依赖
cd electron-app
npm install

# 2. 编译 native addon
npm run build:native

# 3. 编译 renderer + main
npm run build

# 4. 跑(Electron)
npm start
```

## 开发模式(热重载)

```bash
# Terminal 1: vite dev server
npm run dev:renderer

# Terminal 2: 等 vite 起来后,跑 main + electron
npm run build:main
npx electron .
```

## 打包

```bash
npm run package
# 产物在 release/ 目录
# Windows: Media Studio-0.1.0-setup.exe (NSIS)
# macOS:   Media Studio-0.1.0-x64.dmg
# Linux:   Media Studio-0.1.0.AppImage
```

## 关键路径

- **libmedia_studio.so/dll/dylib** 在 `../sdk/build/`,装包时 asarUnpack 释放到 native
- **ffmpeg / ffprobe**:在 `PATH` 中,或设置 `FFMPEG_EXECUTABLE` / `FFPROBE_EXECUTABLE` 环境变量(SDK 接受 C API 路径)

## 跨平台原生模块构建

第一次跑 `npm install` 时,`@electron/rebuild` 会根据 Electron 的 Node ABI 重新编译 native addon。如果失败,手动跑:

```bash
npx electron-rebuild
```