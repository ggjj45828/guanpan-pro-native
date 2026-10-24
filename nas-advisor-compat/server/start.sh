#!/bin/sh
# 启动前决定「跑哪一份代码」：宿主机挂载的，还是镜像里 bake 的——**谁的版本新就用谁**。
#
# 历史坑（这次一次性全堵上）：
# 1. 早期 compose 把宿主机目录直接挂到 /app。一旦 ./server 解析不到（目录名不对、
#    更新包解到子文件夹、NAS 面板把 compose 拷到别处执行……），Docker 会**自动建一个空目录**
#    盖住镜像里能跑的 /app，服务直接起不来。所以现在挂到 /opt/guanpan-src，启动时再拷。
# 2. 但"挂载源缺失/是旧代码 → 静默退回镜像内置版本"同样致命：服务照常起来、心跳正常，
#    而跑的其实是旧代码，从外面完全看不出来（/health 没有 codeVersion、模型名还是旧的）。
#    → 现在两边都读 VERSION，用 sort -V 比版本，取新的那份，并把结果写进 .code-source，
#      由 /health 的 codeSource 暴露出来。这样"挂载没落位"不再等于"永远跑旧代码"。
set -e
SRC="${GUANPAN_SRC:-/opt/guanpan-src}"
APP="${GUANPAN_APP:-/app}"
# 剥掉 CR：Windows core.autocrlf=true 会把本文件 checkout 成 CRLF，行尾 \r 会变成
# 变量的一部分，[ -f "$SRC/app.py" ] 永远为假 → 每一次都退回镜像旧代码。
SRC=$(printf '%s' "$SRC" | tr -d '\r')
APP=$(printf '%s' "$APP" | tr -d '\r')

src_ver=$(cat "$SRC/VERSION" 2>/dev/null | tr -d '\r\n' || true)
app_ver=$(cat "$APP/VERSION" 2>/dev/null | tr -d '\r\n' || true)

use_src=no
if [ -f "$SRC/app.py" ]; then
  if [ -z "$src_ver" ] || [ -z "$app_ver" ]; then
    # 有一边读不到版本号，退回老规矩：挂载里有代码就用挂载的。
    use_src=yes
  else
    # sort -V 按版本号排序（3.6.0-r9 < 3.6.0-r10），取更大的那个。
    newer=$(printf '%s\n%s\n' "$src_ver" "$app_ver" | sort -V | tail -1)
    if [ "$newer" = "$src_ver" ]; then use_src=yes; fi
  fi
fi

if [ "$use_src" = "yes" ]; then
  for f in "$SRC"/*.py "$SRC"/VERSION; do
    [ -f "$f" ] && cp -f "$f" "$APP"/ 2>/dev/null || true
  done
  if [ -d "$SRC/web" ]; then
    mkdir -p "$APP/web"
    cp -Rf "$SRC/web/." "$APP/web/" 2>/dev/null || true
  fi
  printf 'host %s (版本 %s)\n' "$SRC" "$src_ver" > "$APP/.code-source" 2>/dev/null || true
  echo "[start] 使用宿主机代码 $SRC -> 版本 $(cat "$APP/VERSION" 2>/dev/null || echo 未知)"
else
  if [ -f "$SRC/app.py" ]; then
    # 挂载源有代码但更旧：说明你把更新包解到了别处，真正的新代码不在挂载源里。
    printf 'image (挂载源 %s 版本 %s 不比镜像内置 %s 新，沿用镜像内置)\n' \
      "$SRC" "$src_ver" "$app_ver" > "$APP/.code-source" 2>/dev/null || true
    echo "[start] 挂载源版本 $src_ver 不新于镜像内置 $app_ver，沿用镜像内置代码"
  else
    printf 'image (未检测到 %s/app.py，用的镜像内置代码)\n' "$SRC" > "$APP/.code-source" 2>/dev/null || true
    echo "[start] 未检测到宿主机代码（$SRC/app.py），使用镜像内置版本 $(cat "$APP/VERSION" 2>/dev/null || echo 未知)"
  fi
fi

exec python app.py
