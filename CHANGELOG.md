# Changelog

## 0.9.0 — 2026-10-19
- **Getting Started guide** on first launch: choose your language first, then a demo of the wheel, permissions with live status (ticks itself once granted), one-click component install, and the three ways to open the wheel. Reopen it from the menu bar icon › Getting Started….
- The Services entry is now **Process with Peel** on English systems (用 Peel 处理 on Chinese ones); the Finder permission prompt is localized too.
- Accessibility is described as recommended, not required: long-press still works without it.

## 0.8.4 — 2026-10-19
- Removed the globe icon from the 语言 / Language menu item so it matches the other items.

## 0.8.3 — 2026-10-19
- Language follows the system language on first launch (English on non-Chinese Macs).
- Language switch moved to the menu bar as **语言 / Language**, readable in both languages; switching now updates open windows immediately.
- Fixed the color swatch's selection ring being clipped on the left.

## 0.8.2 — 2026-10-19
- The default watermark text now follows the app language (English UI no longer starts with Chinese text).
- "1 page" instead of "1 pages" in the watermark window.
- README: screenshots of watermark, signature, redaction and settings.

## 0.8.1 — 2026-10-19
- Fixed: in **Redact**, the black box landed away from where you dragged (offset by the page margin).
- Fixed the release build script on GitHub Actions.

## 0.8.0 — 2026-10-19
First public release.
- English README, MIT license, privacy note, automatic DMG builds on GitHub.

## 0.7.3 — 2026-10-19
- Tidier credit line in About.

## 0.7.2 — 2026-10-19
- Shorter component descriptions so the Components window doesn't wrap awkwardly.

## 0.7.1 — 2026-10-17
- New **Settings window** (⌘,): long-press, hold / hover timings, shortcuts, language, permissions. The menu-bar menu now only holds everyday actions.

## 0.7.0 — 2026-10-17
- **⌥⇧P** opens the wheel for the files selected in Finder.
- Right-click › Services › **用 Peel 处理** (Process with Peel).

## 0.6.x — 2026-10-16
- **Watermark** for PDFs and images: tiled diagonal text, templates, color / opacity / size / angle / spacing, optional flattening so it can't be removed.
- **PDF signature**: hand-drawn, typed or saved signatures, optional date, placed by dragging.
- Hold / hover timings adjustable with sliders; ID-photo framing never crops past the bottom of the photo.

## 0.5.0 — 2026-10-16
- **ID photo**: background swap, face-aware framing, Chinese and visa sizes, optional 6-inch print sheet.
- **Cutout** to transparent PNG (on-device Vision).

## 0.4.0 — 2026-10-16
- **Compress to a target size** (≤ 2 MB / 1 MB / 500 KB / custom) for images and PDFs, each file meeting the limit on its own.

## 0.3.x — 2026-10-16
- **Screenshots** with ⌥⇧S: Save / Copy / Copy Text (OCR) / Pin. Never auto-saved.
- Drag the screenshot thumbnail straight into a folder or another app.

## 0.2.0 — 2026-10-13
- Long-press wheel with multi-level sectors per file type.
- Documents, images and PDFs: convert, compress, merge, zip; audio & video conversion with progress.
- Image / PDF editing: crop, resize, background, metadata, split, rotate, redact.
- App icon, universal DMG, one-click component installer, Chinese / English UI.
