#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 -m unittest discover -s Server -v
python3 scripts/generate-project.py
if ! command -v xcrun >/dev/null 2>&1; then
  echo "Backend checks passed. SKIPPED: native executable tests and iOS archive require a Mac with Xcode."
  exit 0
fi
mkdir -p build
xcrun swiftc -parse-as-library Sources/NativeCore.swift Tests/NativeCoreTests.swift -o build/core
build/core
xcrun swiftc -parse-as-library Sources/NativeScrollPolicy.swift Tests/NativeScrollPolicyTests.swift -o build/scroll
build/scroll
xcrun swiftc -parse-as-library Sources/NativeCore.swift Sources/NativeSessionHistory.swift Tests/NativeHistoryTests.swift -o build/history
build/history
xcrun swiftc -parse-as-library Sources/NativeCore.swift Sources/NativeNetworking.swift Sources/NativeDownloadLinks.swift Sources/NativeMediaReferences.swift Sources/NativeConversationPresentation.swift Tests/NativePresentationTests.swift -o build/presentation
build/presentation
xcrun swiftc -parse-as-library Sources/NativeAttachmentReader.swift Sources/NativePhotoEncoding.swift Tests/NativeAttachmentTests.swift -o build/attachments
build/attachments
xcrun swiftc -parse-as-library Sources/AGYFilePresentation.swift Tests/AGYFilePresentationTests.swift -o build/files
build/files
echo "Local executable checks passed; use bash scripts/package.sh for the separate iPhone archive. No Actions are invoked."
