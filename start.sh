#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"
PORT="${PORT:-8787}"
echo "Đang khởi động Thiên Minh AI Agent tại http://127.0.0.1:${PORT} ..."
exec ruby --disable-gems -E UTF-8 server.rb
