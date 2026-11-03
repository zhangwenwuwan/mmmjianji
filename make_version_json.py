#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从打好的 APK 生成 version.json（简记「检查更新」用的清单）。

用法（在 JianjiApp 目录下）：

  python make_version_json.py \
      --apk jianji1.4.21-arm64.apk \
      --name 1.4.21 \
      --code 65 \
      --url https://你的域名/jianji/jianji1.4.21-arm64.apk \
      --notes "1. 左滑删除\n2. 日期头吸顶"

  可选：--min-code 60   # 低于 60 的旧版强制更新
        --out D:/网站/jianji/version.json

然后把生成出来的 version.json 和 APK 一起传到网站**同一个目录**，
App 里的 kUpdateManifestUrl 指到那个 json 就行。

⚠️ 两个数字别写错：
  --code 必须比上一版**大**（本地用 appBuild 比；和字符串版本号无关）。
  --name 只是显示用，写成 1.4.21 这种。
"""
import argparse
import hashlib
import json
import os
import sys


def sha256_of(path: str) -> str:
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument('--apk', required=True, help='打好的 APK 路径')
    ap.add_argument('--name', required=True, help='版本名，如 1.4.21')
    ap.add_argument('--code', required=True, type=int, help='versionCode，必须大于上一版')
    ap.add_argument('--url', required=True, help='APK 的公网地址（建议 https）')
    ap.add_argument('--notes', default='', help='更新说明，用 \\n 换行')
    ap.add_argument('--min-code', type=int, default=None,
                    help='低于这个 versionCode 的客户端强制更新')
    ap.add_argument('--out', default='version.json', help='输出文件（默认当前目录）')
    a = ap.parse_args()

    if not os.path.isfile(a.apk):
        sys.exit(f'找不到 APK：{a.apk}')
    if a.code <= 0:
        sys.exit('--code 必须是正整数')
    if not a.url.lower().startswith('https://'):
        print('⚠️  apkUrl 不是 HTTPS：中间人能把下载地址换掉，'
              '而 sha256 也在这份清单里，一起被改就校验不了什么。', file=sys.stderr)

    size = os.path.getsize(a.apk)
    payload = {
        'versionName': a.name,
        'versionCode': a.code,
        'size': size,
        'sha256': sha256_of(a.apk),
        'apkUrl': a.url,
        # 允许命令行里用字面量 \n（Windows 下写多行说明方便）
        'notes': a.notes.replace('\\n', '\n'),
    }
    if a.min_code is not None:
        payload['minSupportedCode'] = a.min_code

    with open(a.out, 'w', encoding='utf-8') as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
        f.write('\n')

    print(f'已生成 {a.out}')
    print(f'  版本   {a.name}+{a.code}')
    print(f'  大小   {size / 1024 / 1024:.1f} MB')
    print(f'  sha256 {payload["sha256"]}')
    print('把 version.json 和 APK 传到网站同一目录，再把 App 里的'
          'kUpdateManifestUrl 指过去即可。')


if __name__ == '__main__':
    main()
