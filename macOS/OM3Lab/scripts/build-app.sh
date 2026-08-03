#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
repo_dir="$(cd "$project_dir/../.." && pwd)"
output_dir="$repo_dir/outputs"
bundle_id="com.yimingshen.om3lab"
app_name="OM3 Lab.app"
archive_name="OM3-Lab-macOS-arm64.zip"
sign_identity="${OM3_SIGN_IDENTITY:--}"

fallback_sdk="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
if [[ -n "${OM3_SDK_PATH:-}" ]]; then
    sdk_path="$OM3_SDK_PATH"
elif [[ -d "$fallback_sdk" ]]; then
    sdk_path="$fallback_sdk"
else
    sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
fi

if [[ ! -d "$sdk_path" ]]; then
    echo "SDK 不存在：$sdk_path" >&2
    exit 1
fi

build_dir="$project_dir/.build/direct"
module_cache="$project_dir/.build/direct-module-cache"
mkdir -p "$build_dir" "$module_cache" "$output_dir"
export CLANG_MODULE_CACHE_PATH="$module_cache"

swiftc_bin="${OM3_SWIFTC:-$(xcrun --find swiftc)}"
if [[ ! -x "$swiftc_bin" ]]; then
    echo "swiftc 不可执行：$swiftc_bin" >&2
    exit 1
fi

"$swiftc_bin" \
    -swift-version 5 \
    -sdk "$sdk_path" \
    -target arm64-apple-macosx14.0 \
    -module-cache-path "$module_cache" \
    -module-name OM3ProtocolSelfTest \
    "$project_dir/Sources/OM3Lab/OM3Protocol.swift" \
    "$project_dir/Sources/OM3Lab/OM3HardwareMotionLimits.swift" \
    "$project_dir/Sources/OM3Lab/PersonTracking.swift" \
    "$project_dir/Sources/OM3Lab/GimbalMotionAnalysis.swift" \
    "$project_dir/Tests/ProtocolSelfTest/main.swift" \
    -o "$build_dir/OM3ProtocolSelfTest"

"$build_dir/OM3ProtocolSelfTest"

sources=("$project_dir"/Sources/OM3Lab/*.swift)
"$swiftc_bin" \
    -swift-version 5 \
    -parse-as-library \
    -O \
    -whole-module-optimization \
    -sdk "$sdk_path" \
    -target arm64-apple-macosx14.0 \
    -module-cache-path "$module_cache" \
    -module-name OM3Lab \
    "${sources[@]}" \
    -o "$build_dir/OM3Lab"

temp_root="$(mktemp -d "${TMPDIR:-/tmp}/om3lab-build.XXXXXX")"
trap 'rm -rf "$temp_root"' EXIT

staged_app="$temp_root/$app_name"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
install -m 755 "$build_dir/OM3Lab" "$staged_app/Contents/MacOS/OM3Lab"
install -m 644 "$project_dir/Resources/Info.plist" "$staged_app/Contents/Info.plist"
install -m 644 "$project_dir/Resources/PkgInfo" "$staged_app/Contents/PkgInfo"

plutil -lint "$staged_app/Contents/Info.plist"

codesign \
    --force \
    --sign "$sign_identity" \
    --identifier "$bundle_id" \
    --timestamp=none \
    "$staged_app"

archs="$(lipo -archs "$staged_app/Contents/MacOS/OM3Lab")"
if [[ "$archs" != "arm64" ]]; then
    echo "架构验证失败：期望 arm64，实际为 $archs" >&2
    exit 1
fi

codesign --verify --deep --strict --verbose=2 "$staged_app"
otool -L "$staged_app/Contents/MacOS/OM3Lab" > "$temp_root/linked-libraries.txt"

output_app="$output_dir/$app_name"
output_archive="$output_dir/$archive_name"
if [[ "$output_app" != "$repo_dir/outputs/OM3 Lab.app" ]]; then
    echo "拒绝覆盖意外路径：$output_app" >&2
    exit 1
fi

rm -rf "$output_app"
rm -f "$output_archive"
ditto "$staged_app" "$output_app"
ditto -c -k --sequesterRsrc --keepParent "$output_app" "$output_archive"
install -m 644 "$project_dir/README.md" "$output_dir/OM3-Lab-使用说明.md"

verify_dir="$temp_root/verify"
mkdir -p "$verify_dir"
ditto -x -k "$output_archive" "$verify_dir"
codesign --verify --deep --strict --verbose=2 "$verify_dir/$app_name"

echo "已生成：$output_app"
echo "已生成：$output_archive"
echo "架构：$archs"
echo "SDK：$sdk_path"
