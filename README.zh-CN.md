<p align="center">
  <img src="Resources/AppIcon.png" width="128" alt="Peel 图标">
</p>

<h1 align="center">Peel</h1>

<p align="center">
  在访达里按住文件，弹出轮盘，拖到扇区上松手，就能转换、压缩或编辑。<br>
  一个住在菜单栏里的 macOS 小工具，所有处理都在本机完成。
</p>

<p align="center">
  <a href="README.md">English</a> ·
  <a href="../../releases/latest">下载</a> ·
  <a href="CHANGELOG.md">更新日志</a>
</p>

<p align="center">
  <img src="Docs/images/demo-zh.gif" width="720" alt="演示：按住文件，拖到扇区上">
</p>

<p align="center">
  <img src="Docs/images/wheel-photo-zh.png" width="300" alt="图片的轮盘">
</p>

## 用法

1. 在访达里**左键按住文件不动**（默认 1 秒），鼠标旁弹出轮盘。
2. 继续按住，**把文件拖到扇区上松手**。拖到分类扇区（如「转换」）上停一会儿，外圈进度条跑满就展开下一层；拖回中心返回上一层。
3. 结果会**在原文件旁边生成副本**，原文件不会被改动。

1 秒内移动鼠标就是普通拖动，不影响平时移动文件。先选中多个文件再长按，可以批量处理。

**不想长按**：在访达选中文件后按 **⌥⇧P**，轮盘在鼠标处弹出；或右键 › 服务 › **用 Peel 处理**。
（右键里看不到的话，到「系统设置 › 键盘 › 键盘快捷键 › 服务 › 文件和文件夹」里勾选。）

轮盘只显示这种文件能做的事：Word 文档是 PDF / HTML / TXT，照片是转换 / 压缩 / 编辑。

## 功能

| | |
|---|---|
| **文档** | Word / PPT / Excel 转 PDF（用 LibreOffice，完全离线）、Pages / Keynote / Numbers 导出、docx ⇄ txt ⇄ html |
| **PDF** | 压缩、压缩到指定大小、转 Word / 图片、合并、拆分、旋转、涂黑（真正移除内容）、元数据、**平铺水印**（可防移除）、**签名**（手写 / 打字 / 已保存，可加日期） |
| **图片** | 转换（JPG / PNG / HEIC / WebP / PDF）、压缩、**压缩到指定大小**（≤ 2 MB / 1 MB / 500 KB / 自定义）、裁剪、改尺寸、加背景、去掉位置 / 元数据、**证件照**（换底色、按人脸构图、国内及签证尺寸、可选 6 寸排版）、抠图（透明 PNG） |
| **音频、视频** | 转换、压缩（预估大小、显示进度）、提取音频、视频转 GIF |
| **截图** | **⌥⇧S** 框选 → 保存（选位置）/ 复制 / 识别文字（本地 OCR）/ 钉在屏幕上。不会自动保存，只复制到剪贴板；缩略图可直接拖到文件夹或其他 App |
| **其他** | ZIP 压缩、中英文界面（默认跟随系统语言，可在菜单栏图标 › 语言 / Language 里切换）、设置窗口（⌘,）里调时长和快捷键 |

## 截图

<p align="center">
  <img src="Docs/images/watermark.png" width="720" alt="加水印窗口">
  <br><sub>给 PDF 或照片加水印，实时预览；可选「防移除」，水印无法被删掉</sub>
</p>

| PDF 签名 | 涂黑（内容被真正移除） |
|---|---|
| <img src="Docs/images/sign-result.jpg" alt="签名效果"> | <img src="Docs/images/redact-result.jpg" alt="涂黑效果"> |

<p align="center">
  <img src="Docs/images/settings.png" width="380" alt="设置窗口">
  <br><sub>设置窗口：长按 / 悬停时长、快捷键、权限</sub>
</p>

## 安装

1. 在 [Releases](../../releases/latest) 下载 `Peel-版本号.dmg`，把 Peel 拖进「应用程序」。支持 Apple 芯片和 Intel，macOS 13 及以上。
2. Peel 没有经过苹果公证，第一次打开会被拦下：打开「系统设置 › 隐私与安全性」，往下找到 Peel 的提示，点「仍要打开」。
3. 会打开一个使用引导：先选语言，再开启权限（见下）、可选安装组件。以后可以从菜单栏图标 › 使用引导… 再打开。
4. Peel 会询问是否一键安装需要的转换组件（通过 Homebrew），之后也可以在菜单栏图标 › 组件… 里查看。

### 权限

| 权限 | 用途 |
|---|---|
| 辅助功能（推荐） | 让长按更准：只有按住文件才弹出轮盘，按住标题栏、空白处不会误触 |
| 自动化 › 访达 | 读取访达里选中的文件 |
| 屏幕录制 | 仅截图需要（macOS 对所有截图软件的要求） |

### 转换组件

| 工具 | 用途 | 安装方式 |
|---|---|---|
| LibreOffice | Word / PPT / Excel 转换 | `brew install --cask libreoffice` |
| Ghostscript | PDF 压缩 | `brew install ghostscript` |
| cwebp | 输出 WebP | `brew install webp` |
| pngquant | PNG 压缩 | `brew install pngquant` |
| pdf2docx | PDF 转 Word | 装在 `~/Library/Application Support/Peel/venv` |
| FFmpeg | 音频、视频 | `brew install ffmpeg` |

其他功能（图片处理、PDF 编辑、文字识别、抠图、人脸检测）都用 macOS 自带的框架。
LibreOffice 在无界面模式下找不到 macOS 字体，Peel 会生成 fontconfig 配置，把微软雅黑、宋体等映射到苹方、宋体-简，避免中文变成方框。

## 隐私

Peel 只在你的 Mac 上处理文件，不会上传任何文件；文字识别、抠图、证件照都用苹果的本地 Vision 框架。
没有统计或遥测。只有在**你**选择安装组件时才会联网（Homebrew / pip 下载）。日志只保存在本机 `~/Library/Logs/Peel.log`。

## 从源码构建

需要 Xcode 命令行工具（不需要完整的 Xcode）。

```bash
./scripts/build_app.sh        # 编译本机版本 → ~/Applications/Peel.app
open ~/Applications/Peel.app
./scripts/package.sh          # 通用版安装包 → Build/Peel-版本号.dmg
```

可选：`./scripts/setup_signing.sh` 生成本地自签名证书，重新编译后「辅助功能」授权仍然有效（没有证书时用临时签名，每次编译后需要重新授权）。
版本号在 `Resources/Info.plist` 里改，构建号自动用编译时间。推送 `v0.8.0` 这样的标签，GitHub Actions 会自动打包 DMG 并发布。

## 许可证

[MIT](LICENSE)
