#!/bin/bash
# WDA「点开即启动」补丁（standalone boot）
#
# 目标：不依赖 Mac/xcodebuild，用户直接点开 App 图标即可启动 WDA 服务
#       （对齐神目 PandaHelper 的使用体验，但我们用开源 WDA 自己打）。
#
# 原理：WDA 正常入口在 UITestingUITests.m 的 testRunner（XCTest 会话里跑），
#   本补丁往 WebDriverAgentLib/Routing/FBWebServer.m 追加一个 +load 钩子：
#   App 任何模式加载该类时都会执行 +load —— 若检测到不在 XCTest 会话
#   （无 XCTestConfigurationFilePath 环境变量），延迟 2 秒自启服务；
#   若是 XCTest 模式（xcodebuild/远程拉起）则跳过，避免双实例抢 8100 端口。
#   不改 pbxproj、不新增文件，纯源码追加，对多版本 WDA 布局通用。
#
# 追加项：
#   1. FBWebServer.m 末尾：+load 自启钩子
#   2. WebDriverAgentRunner/Info.plist：UIBackgroundModes（audio/processing，
#      尽量缓解后台挂起；保活效果以真机回归为准，不稳则用 PC 端 go-ios 自动唤醒）
#
# 用法（CI 中，工作目录 = WDA 源码根目录）：
#   bash patch-standalone.sh
set -euo pipefail

TARGET=$(find . -name 'FBWebServer.m' -not -path '*/build/*' 2>/dev/null | head -1)
if [ -z "$TARGET" ]; then
  echo "[patch] 未找到 FBWebServer.m，中止" >&2
  exit 1
fi

if grep -q "YUZHOU_STANDALONE" "$TARGET"; then
  echo "[patch] FBWebServer.m 已含补丁，跳过"
else
  cat >> "$TARGET" <<'EOF'

// ---------------------------------------------------------------
// #YUZHOU_STANDALONE 点开即启动（非 XCTest 会话时自启 WDA 服务）
// 原生 testRunner 路径不受影响：XCTest 模式检测到
// XCTestConfigurationFilePath 会直接 return，避免双实例抢端口。
// ---------------------------------------------------------------
@implementation FBWebServer (YuzhouStandaloneBoot)
+ (void)load
{
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
    if (nil != [NSProcessInfo.processInfo.environment objectForKey:@"XCTestConfigurationFilePath"]) {
      return;
    }
    NSLog(@"[yuzhou] standalone boot: starting WDA server");
    FBWebServer *webServer = [[FBWebServer alloc] init];
    [webServer startServing];
  });
}
@end
EOF
  echo "[patch] 已追加 standalone 自启钩子 -> $TARGET"
fi

PLIST=$(find . -path '*WebDriverAgentRunner/Info.plist' -not -path '*/build/*' 2>/dev/null | head -1)
if [ -n "$PLIST" ]; then
  if ! /usr/libexec/PlistBuddy -c "Print :UIBackgroundModes" "$PLIST" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Add :UIBackgroundModes array" "$PLIST" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :UIBackgroundModes:0 string audio" "$PLIST" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :UIBackgroundModes:1 string processing" "$PLIST" 2>/dev/null || true
    echo "[patch] 已写入 UIBackgroundModes(audio, processing) -> $PLIST"
  else
    echo "[patch] UIBackgroundModes 已存在，跳过"
  fi
else
  echo "[patch] 未找到 Runner Info.plist（后台模式未写入，仅影响后台保活）"
fi

# ---------------------------------------------------------------
# 3. 应用显示名（手机桌面图标下方的名字）
#    环境变量 APP_NAME 可覆盖，默认「宇宙投屏」
# ---------------------------------------------------------------
APP_NAME="${APP_NAME:-宇宙投屏}"
if [ -n "$PLIST" ]; then
  if ! /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$PLIST" 2>/dev/null; then
    /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $APP_NAME" "$PLIST" 2>/dev/null || true
  fi
  if ! /usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$PLIST" 2>/dev/null; then
    /usr/libexec/PlistBuddy -c "Add :CFBundleName string $APP_NAME" "$PLIST" 2>/dev/null || true
  fi
  echo "[patch] 应用显示名 -> $APP_NAME"
fi

# ---------------------------------------------------------------
# 4. 应用图标（1024x1024 单尺寸，Xcode 编译时自动派生全尺寸）
#    环境变量 APP_ICON 指向图标 PNG，缺省跳过
# ---------------------------------------------------------------
APP_ICON="${APP_ICON:-}"
if [ -n "$APP_ICON" ] && [ -f "$APP_ICON" ]; then
  AC=$(find . -type d -name 'Assets.xcassets' -path '*Runner*' -not -path '*/build/*' 2>/dev/null | head -1)
  if [ -z "$AC" ]; then
    AC=$(find . -type d -name 'Assets.xcassets' -not -path '*/build/*' 2>/dev/null | head -1)
  fi
  if [ -n "$AC" ]; then
    SET="$AC/AppIcon.appiconset"
    rm -rf "$SET"
    mkdir -p "$SET"
    cp "$APP_ICON" "$SET/icon-1024.png"
    cat > "$SET/Contents.json" <<'JSONEOF'
{
  "images" : [
    {
      "filename" : "icon-1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSONEOF
    echo "[patch] 应用图标 -> $SET"
    PROJ=$(find . -name 'project.pbxproj' -not -path '*/build/*' 2>/dev/null | head -1)
    if [ -n "$PROJ" ]; then
      APPICON_SETTING=$(grep -m1 'ASSETCATALOG_COMPILER_APPICON_NAME' "$PROJ" || echo "(默认 AppIcon)")
      echo "[patch] 工程 AppIcon 设置: $APPICON_SETTING（若非 AppIcon 需在 CI 里改 build setting）"
    fi
  else
    echo "[patch] 未找到 Assets.xcassets，图标未替换" >&2
  fi
else
  echo "[patch] 未提供 APP_ICON，跳过图标替换"
fi

echo "[patch] 完成"
