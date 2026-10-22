#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# phpallinone 构建与冒烟验证
#
#   ./verify.sh            # 静态检查 + 构建 + 起容器冒烟测试
#   ./verify.sh --static   # 只跑静态检查（不需要 docker）
#   IMAGE=foo:tag ./verify.sh
# ---------------------------------------------------------------------------
set -uo pipefail
cd "$(dirname "$0")"

# Windows Git Bash 下必须关掉 MSYS 路径转换，否则传给容器的 /usr/local/... 会被改写成
# D:/WorkBuddy/.../usr/local/...，表现为莫名其妙的 "not found"。
if [ -n "${MSYSTEM:-}" ]; then
  export MSYS_NO_PATHCONV=1
  export MSYS2_ARG_CONV_EXCL='*'
fi

IMAGE="${IMAGE:-phpallinone:verify}"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$*"; }
skip() { printf '  \033[33mSKIP\033[0m  %s\n' "$*"; }
head_() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

STATIC_ONLY=0
[ "${1:-}" = "--static" ] && STATIC_ONLY=1

# --- 1. 静态检查 -----------------------------------------------------------
head_ "1. 静态检查"

BASE=$(grep -m1 '^FROM ' Dockerfile | awk '{print $2}')
case "$BASE" in
  php:8.2.35-fpm-alpine3.24) ok "基础镜像 $BASE" ;;
  *) bad "基础镜像异常: $BASE（期望 php:8.2.35-fpm-alpine3.24）" ;;
esac

NGX_VER=$(awk -F= '/^ *NGINX_VERSION=/{gsub(/[ \t\\]/,"",$2); print $2; exit}' Dockerfile)
NGX_SUM=$(awk -F= '/^ *NGINX_SHA256=/{gsub(/[ \t\\]/,"",$2); print $2; exit}' Dockerfile)

TMP=$(mktemp -d)
trap 'rm -rf "$TMP" >/dev/null 2>&1 || true' EXIT

if curl -fsSL -o "$TMP/nginx.tgz" "https://nginx.org/download/nginx-${NGX_VER}.tar.gz"; then
  if echo "${NGX_SUM}  $TMP/nginx.tgz" | sha256sum -c - >/dev/null 2>&1; then
    ok "nginx ${NGX_VER} 下载成功且 SHA256 匹配"
  else
    bad "nginx ${NGX_VER} SHA256 不匹配（Dockerfile 里的校验值需要更新）"
  fi
else
  bad "nginx ${NGX_VER} 下载失败"
fi

curl -fsSL -o "$TMP/inst.php" https://getcomposer.org/installer
SIG=$(curl -fsSL https://composer.github.io/installer.sig)
if command -v php >/dev/null 2>&1; then
  ACT=$(php -r "echo hash_file('sha384', '$TMP/inst.php');")
elif command -v openssl >/dev/null 2>&1; then
  ACT=$(openssl dgst -sha384 "$TMP/inst.php" | awk '{print $NF}')
else
  ACT=""
fi
if [ -z "$ACT" ]; then
  skip "composer 签名（无 php / openssl）"
elif [ "$SIG" = "$ACT" ]; then
  ok "composer installer 签名匹配"
else
  bad "composer installer 签名不匹配"
fi

missing=0
for f in $(grep -E '^COPY ' Dockerfile | awk '{print $2}'); do
  [ -e "$f" ] || { bad "COPY 源缺失: $f"; missing=1; }
done
[ $missing -eq 0 ] && ok "所有 COPY 源文件存在"

crlf=0
for f in Dockerfile scripts/start.sh conf/nginx/*.conf conf/supervisord/*.conf; do
  [ -f "$f" ] || continue
  if od -An -tx1 "$f" | tr ' ' '\n' | grep -qx '0d'; then
    bad "$f 含 CR 字节（应为 LF）"; crlf=1
  fi
done
[ $crlf -eq 0 ] && ok "全部配置文件为 LF 行尾"

grep -q 'session.upload_progress.enabled=0' Dockerfile \
  && ok "php2shell 缓解项 session.upload_progress.enabled=0 已配置" \
  || bad "缺少 session.upload_progress.enabled=0"
grep -q 'expose_php=Off' Dockerfile \
  && ok "expose_php=Off 已配置" || bad "缺少 expose_php=Off"
grep -q 'LD_PRELOAD' Dockerfile && bad "Dockerfile 仍有 LD_PRELOAD（新版 Alpine 无 preloadable_libiconv.so）" \
  || ok "已移除失效的 LD_PRELOAD hack"

if [ $STATIC_ONLY -eq 1 ]; then
  head_ "结果：PASS=$PASS FAIL=$FAIL（仅静态检查）"
  [ $FAIL -eq 0 ] || exit 1
  exit 0
fi

# --- 2. 构建 ---------------------------------------------------------------
head_ "2. 构建镜像 $IMAGE"
if ! docker info >/dev/null 2>&1; then
  bad "docker daemon 不可用（先启动 Docker Desktop）"; exit 1
fi
if docker build -t "$IMAGE" .; then
  ok "构建成功"
else
  bad "构建失败"; exit 1
fi

# --- 3. 启动容器 -----------------------------------------------------------
head_ "3. 启动容器"
NAME=phpallinone-verify
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" "$IMAGE" >/dev/null
sleep 5

docker exec "$NAME" supervisorctl status 2>&1 | sed 's/^/    /'
docker exec "$NAME" supervisorctl status 2>/dev/null | grep -q 'php-fpm.*RUNNING' \
  && ok "php-fpm 由 supervisor 拉起并在运行" \
  || { bad "php-fpm 未运行"; docker logs "$NAME" 2>&1 | tail -30; }
docker exec "$NAME" supervisorctl status 2>/dev/null | grep -q 'nginx.*RUNNING' \
  && ok "nginx 在运行" \
  || { bad "nginx 未运行"; docker logs "$NAME" 2>&1 | tail -30; }

# --- 4. php2shell 修复校验 -------------------------------------------------
head_ "4. php2shell 修复校验"
PV=$(docker exec "$NAME" php -r 'echo PHP_VERSION;' 2>/dev/null | tr -d '\r')
if [ "$(printf '%s\n8.2.35\n' "$PV" | sort -V | head -1)" = "8.2.35" ]; then
  ok "PHP $PV >= 8.2.35（CVE-2026-109618/109619 已修复）"
else
  bad "PHP $PV 低于 8.2.35，仍受 php2shell 影响"
fi

# php -i 输出形如 "session.upload_progress.enabled => Off => Off"，第 3 列才是值
UP=$(docker exec "$NAME" php -i 2>/dev/null | tr -d '\r' \
      | grep -i '^session\.upload_progress\.enabled' | awk '{print $3}')
[ "$UP" = "Off" ] && ok "session.upload_progress.enabled = Off" || bad "session.upload_progress.enabled = [$UP]"

EX=$(docker exec "$NAME" php -i 2>/dev/null | tr -d '\r' \
      | grep -i '^expose_php' | awk '{print $3}')
[ "$EX" = "Off" ] && ok "expose_php = Off" || bad "expose_php = [$EX]"

JIT=$(docker exec "$NAME" php -i 2>/dev/null | tr -d '\r' \
      | grep -i '^opcache\.jit =>' | awk '{print $3}')
printf '    opcache.jit = %s\n' "${JIT:-未设置}"

# --- 5. 组件版本与扩展 -----------------------------------------------------
head_ "5. 组件版本与扩展"
docker exec "$NAME" php -v 2>&1 | head -1 | sed 's/^/    /'
docker exec "$NAME" nginx -v 2>&1 | sed 's/^/    /'
for e in pdo_mysql mysqli gd exif fileinfo intl redis mcrypt; do
  docker exec "$NAME" php -r "exit(extension_loaded('$e')?0:1);" 2>/dev/null \
    && ok "扩展 $e" || bad "扩展 $e 缺失"
done
# opcache 的模块名是 "Zend OPcache"，不是 "opcache"
docker exec "$NAME" php -r "exit(extension_loaded('Zend OPcache')?0:1);" 2>/dev/null \
  && ok "扩展 Zend OPcache" || bad "扩展 Zend OPcache 缺失"

# --- 6. 服务可用性 ---------------------------------------------------------
head_ "6. 服务可用性"
if docker exec "$NAME" sh -c 'command -v wget >/dev/null' 2>/dev/null; then
  # 判断放在容器内做：避免 Windows 下超长输出经 MSYS 管道时被截断/转码
  if docker exec "$NAME" sh -c 'wget -qO- http://127.0.0.1/ 2>/dev/null | grep -qi phpinfo' 2>/dev/null; then
    ok "80 端口返回 phpinfo 页面（nginx→php-fpm 链路通）"
  else
    bad "首页异常，nginx 与 php-fpm 可能未打通"
    docker exec "$NAME" sh -c 'wget -S -O - http://127.0.0.1/ 2>&1 | head -12' 2>&1 | sed 's/^/      /'
  fi
else
  skip "容器内无 wget"
fi
docker exec "$NAME" sh -c 'test -S /dev/shm/php-fpm.sock' 2>/dev/null \
  && ok "php-fpm unix socket 存在" || bad "php-fpm socket 缺失"

# nginx 里写 "error_log off" 会生成名为 off 的文件，确认这个坑没被引入
docker exec "$NAME" sh -c 'test -f /usr/local/nginx/off' 2>/dev/null \
  && bad "nginx 生成了名为 off 的错误日志文件（error_log off 的坑）" \
  || ok "未生成 /usr/local/nginx/off 垃圾文件"

# supervisord 主日志应打到 stdout，能被 docker logs 收到
docker logs "$NAME" 2>&1 | grep -qE 'supervisord (started|started with pid)' \
  && ok "supervisord 主日志已进入 docker logs" \
  || printf '    （supervisord 启动日志未在 docker logs 中匹配到，可人工核对）\n'

FPMUSER=$(docker exec "$NAME" sh -c 'ps -o user,args 2>/dev/null | grep "[p]hp-fpm: master" | head -1' 2>/dev/null | awk '{print $1}')
[ "$FPMUSER" = "root" ] && ok "php-fpm master 以 root 运行（worker 降权到 www）" \
  || printf '    php-fpm master user = %s\n' "${FPMUSER:-未知}"

# --- 7. 清理 ---------------------------------------------------------------
head_ "7. 清理"
docker rm -f "$NAME" >/dev/null 2>&1 && ok "已删除测试容器"

head_ "结果：PASS=$PASS FAIL=$FAIL"
[ $FAIL -eq 0 ] || exit 1
