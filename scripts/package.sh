#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist
swift scripts/prepare-icon.swift
xcodebuild -project AGY.xcodeproj -scheme AGY -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/AGY.xcarchive \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' archive 2>&1 | tee dist/build.log
mkdir -p build/package/Payload
ditto build/AGY.xcarchive/Products/Applications/AGY.app build/package/Payload/AGY.app
codesign --force --sign - --generate-entitlement-der build/package/Payload/AGY.app
codesign --verify --deep --strict build/package/Payload/AGY.app
(cd build/package && ditto -c -k --keepParent Payload ../../dist/AGY-iPhone-resign.ipa)
python3 scripts/verify-ipa.py dist/AGY-iPhone-resign.ipa
