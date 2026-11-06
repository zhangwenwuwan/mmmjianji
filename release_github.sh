#!/usr/bin/env bash
# 一条命令发版到 GitHub Releases（简记）。
#
# 用法：
#   export GH_USER=你的GitHub用户名
#   export GH_REPO=jianji
#   ./release_github.sh 1.4.42 86 "1. 左滑删除\n2. 日期头吸顶"
#
# 它做五件事：校验版本号三个地方一致 → 构建（含全量测试）→ 生成 version.json
#            → 打 tag 并推送 → 建 GitHub Release 并上传 APK + 清单
#
# 前置条件：
#   1. 仓库已建好、`git push -u origin master` 成功过（Git Credential Manager 记住了登录）
#   2. 装了 gh CLI 才会自动建 release；没装的话脚本会把要上传的文件和网页地址打出来
#
# ⚠️ 仓库必须是 **public**。私有仓库的 Release 资产下载需要 token，
#    App 里带不了 → 检查更新永远 404。
set -euo pipefail

VER="${1:-}"
CODE="${2:-}"
NOTES="${3:-}"

if [ -z "$VER" ] || [ -z "$CODE" ]; then
  echo "用法: ./release_github.sh <版本名 如 1.4.42> <versionCode 如 86> [更新说明]"
  exit 1
fi
: "${GH_USER:?请先 export GH_USER=你的GitHub用户名}"
: "${GH_REPO:?请先 export GH_REPO=仓库名}"

TAG="v$VER"
APK="jianji$VER-arm64.apk"
ASSET_URL="https://github.com/$GH_USER/$GH_REPO/releases/download/$TAG/$APK"
MANIFEST_URL="https://github.com/$GH_USER/$GH_REPO/releases/latest/download/version.json"

# ---------------------------------------------------------------- 1. 版本号三处一致
echo "[1/5] 校验版本号"
PUBS=$(grep -E '^version:' pubspec.yaml | awk '{print $2}')
if [ "$PUBS" != "$VER+$CODE" ]; then
  echo "✗ pubspec.yaml 写的是 $PUBS，命令给的是 $VER+$CODE"
  exit 1
fi
grep -q "defaultValue: '$VER'" lib/core/version.dart \
  || { echo "✗ core/version.dart 的版本名不是 $VER"; exit 1; }
grep -q "defaultValue: $CODE" lib/core/version.dart \
  || { echo "✗ core/version.dart 的 versionCode 不是 $CODE"; exit 1; }
if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "✗ tag $TAG 已存在，先确认版本号有没有写错"
  exit 1
fi
echo "    ok: $VER+$CODE"

# ---------------------------------------------------------------- 2. 构建（含全量测试）
echo "[2/5] 构建（跑全量测试，失败会中断）"
# ⚠️ 两个不能省：
#  1) UPDATE_URL 必须注入，否则打出来的包「检查更新」永远是「未接入更新服务」，
#     而清单地址在本文件上面第 34 行已经算好了（releases/latest/download/version.json）。
#  2) 用 --full-clean 而不是 --incr：release 复用陈旧 AOT 时包能装能跑、
#     UI 完全看不出异常，只有 libapp.so 的 md5 能验出来（见项目构建铁律）。
#     它自带 analyze + 全量 flutter test，不用再单独跑一次 --check。
UPDATE_URL="$MANIFEST_URL" ./build_jianji.sh --full-clean
[ -f "$APK" ] || { echo "✗ 没找到产物 $APK"; exit 1; }

# ---------------------------------------------------------------- 3. 生成更新清单
echo "[3/5] 生成 version.json"
mkdir -p build/release_assets
python make_version_json.py \
  --apk "$APK" \
  --name "$VER" \
  --code "$CODE" \
  --url "$ASSET_URL" \
  --notes "$NOTES" \
  --out build/release_assets/version.json

# ---------------------------------------------------------------- 4. 打 tag 并推送
echo "[4/5] 推送代码与 tag"
git push origin HEAD
git tag -a "$TAG" -m "简记 $VER+$CODE"
git push origin "$TAG"

# ---------------------------------------------------------------- 5. 建 Release
echo "[5/5] 建 GitHub Release"
if command -v gh >/dev/null 2>&1; then
  gh release create "$TAG" "$APK" build/release_assets/version.json \
    --title "简记 $VER" \
    --notes "${NOTES:-简记 $VER}"
  echo "✅ 已发布：https://github.com/$GH_USER/$GH_REPO/releases/tag/$TAG"
else
  cat <<EOS
本机没有 gh CLI，最后一步手动点（两分钟）：

  1. 打开 https://github.com/$GH_USER/$GH_REPO/releases/new?tag=$TAG
  2. 标题填「简记 $VER」，把这两个文件拖进 Attachments：
       $(pwd)/$APK
       $(pwd)/build/release_assets/version.json
  3. 点 Publish release

装 gh 更省事：winget install --id GitHub.cli  然后 gh auth login
EOS
fi

echo
echo "本包已注入 UPDATE_URL=$MANIFEST_URL（第 2 步自动传入，无需手动加 dart-define）。"
echo "没装 gh CLI 时，也可以走 GitHub API 发版：凭据用"
echo "  printf 'protocol=https\\nhost=github.com\\n\\n' | git credential fill"
echo "取 token，再 POST /repos/$GH_USER/$GH_REPO/releases 并上传资产。"
