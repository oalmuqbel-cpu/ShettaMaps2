#!/bin/bash
# تجهيز مشروع خرائط شتة 2 على جهاز Mac
set -e
cd "$(dirname "$0")"
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "تثبيت XcodeGen عبر Homebrew..."
  if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew غير مثبت. ثبّته من https://brew.sh ثم أعد التشغيل."; exit 1
  fi
  brew install xcodegen
fi
xcodegen generate
echo "تم إنشاء ShettaMaps2.xcodeproj"
open ShettaMaps2.xcodeproj
