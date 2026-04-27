# fplayer-ff-service

`fplayer-ff-service` 是独立部署的软件，内置 `ZLMediaKit` 作为媒体分发内核，并通过 `gateway` 向 desktop 提供会话编排接口。

> 文档入口：
> - 使用手册：`doc/使用手册.md`
> - 用户手册：`doc/man/用户手册.md`
> - 打包发布与使用教程：`doc/打包发布与使用教程.md`
> - 技术文档：`doc/技术文档-实现说明.md`
> - Git 提交注意事项：`doc/Git提交注意事项.md`

## 编译环境要求

建议在 Windows 10/11 x64 环境下进行开发与打包，并确保以下工具可用：

- PowerShell 5.1+（用于执行 `scripts/*.ps1`）
- Go 1.22+（用于编译 `gateway`）
- Node.js 20 LTS（建议）+ npm 10+（用于 UI 依赖安装与 Electron 打包）
- Git 2.40+（建议）与 Git LFS（用于大文件管理）

可选但推荐：

- Visual Studio 2022 Build Tools（部分本地原生依赖编译场景需要）

快速自检命令：

```powershell
powershell -v
go version
node -v
npm -v
git --version
git lfs version
```

## 快速启动（Windows）

开发调试：

```powershell
.\scripts\start-all.ps1
```

或直接双击：

- `start-service.bat`

停止：

```powershell
.\scripts\stop-all.ps1
```

或直接双击：

- `stop-service.bat`

发布使用（推荐）：

- 先执行 `.\scripts\build-release.ps1`
- 分发 `release/portable` 整目录
- 用户双击 `portable/FPlayerFFService.exe` 直接运行（无需手动脚本）

## 快速验证

- 健康检查：`http://127.0.0.1:<gateway-port>/healthz`（`gateway-port` 见 `run/runtime.json`）
- 运行时信息：`run/runtime.json`

## 打包为 Windows EXE

在根目录执行：

```powershell
.\scripts\build-win-package.ps1
```

该脚本会：

- 编译 `gateway.exe`（输出到 `gateway/bin/gateway.exe`）
- 安装 UI 依赖
- 调用 `electron-builder` 产出 Windows 安装包（`ui/dist`）

## 生成可发布包（推荐）

在根目录执行：

```powershell
.\scripts\build-release.ps1
```

输出目录：

- `release/`
  - 最新安装包 `.exe`
  - `portable/`（推荐分发目录，双击 `FPlayerFFService.exe` 直接运行）
    - 同级内含 `3rd/`、`gateway/bin/gateway.exe`、`scripts/*`、`resources/*`
  - `win-unpacked/`（electron-builder 原始产物）
  - `README-发布说明.txt`（给使用者的发布说明）

说明：

- `build-release.ps1` 会校验 `portable` 关键依赖是否齐全，避免发包漏 `gateway/3rd/scripts/resources`
- 打包版 UI 启动时会自动拉起 service 内核（ZLM + gateway），并默认隐藏子进程控制台窗口

## 清理可再生产物（可选）

在根目录执行：

```powershell
.\scripts\clean.ps1
```

会清理：

- `ui/dist`
- `release`
- `run`
- `logs`
- `gateway/bin/gateway.exe`

说明：

- 清理后可直接再次执行 `.\scripts\build-release.ps1` 重新生成可发布包
- `clean.ps1` 不会删除 `3rd/`、源码和文档

## 目录

- `3rd/zlm/windows/`：Windows 版 ZLMediaKit（`MediaServer.exe`）
- `gateway/`：Go 网关服务（会话创建、地址编排）
- `ui/`：Electron 控制台
- `scripts/start-all.ps1`：一键启动 ZLM + gateway + UI
- `scripts/stop-all.ps1`：一键停止
- `doc/使用手册.md`：面向使用者
- `doc/技术文档-实现说明.md`：面向开发者
