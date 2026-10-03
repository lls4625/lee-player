#!/bin/zsh
# 以脚本旁的 web 文件夹为站点根目录，供 App 下载测试资源。
set -eu

WEB_ROOT="/Users/javalee/work/proj/leeplayer_v3/v3"

if ! command -v python3 >/dev/null 2>&1; then
  print -u2 -- "启动失败：未找到 python3，请安装 Python 3 后重试。"
  exit 1
fi

if [[ ! -d "$WEB_ROOT" ]]; then
  print -u2 -- "启动失败：站点目录不存在：$WEB_ROOT"
  exit 1
fi

cd "$WEB_ROOT"

exec flutter run -d ip14pm
