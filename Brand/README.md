# Official Antigravity artwork

The full-color PNG and SVG in this directory are original Google assets downloaded unchanged from [Google Antigravity Press Assets](https://antigravity.google/press) on 2026-10-27:

- https://antigravity.google/assets/image/brand/antigravity-icon__full-color.png
- https://antigravity.google/assets/image/brand/antigravity-icon__full-color.svg

`Sources/Assets.xcassets/AntigravityMark.imageset/Mark.png` is a byte-identical copy of the official PNG. Login, welcome and assistant-message marks use this image.

`scripts/prepare-icon.swift` packages the same full-color artwork on an opaque white 1024×1024 iOS icon canvas. It preserves the original mark and proportions. It runs before every device archive; no custom replacement letter or symbol is used.

Antigravity and its artwork belong to Google. This repository is an independent client, not an official Google iOS application.
