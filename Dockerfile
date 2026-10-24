# ---------------------------------------------------------------------------
# 全功能 PHP 栈：Nginx + PHP-FPM + Supervisor（面向 Symfony）
#
# 【2026-10-24 升级：PHP 8.2 -> 8.5】
#   8.2 安全支持 2026-12-31 到期；8.4 的 active support 同样在 2026-12-31 结束。
#   8.5 active 到 2027-12-31、security 到 2029-12-31，故一步到位跳 8.5。
#
# 【2026-10-22 安全升级：php2shell】
#   CVE-2026-109618 / CVE-2026-109619，UAF -> 未授权 RCE，CVSS 4.0 = 9.2
#   官方修复版本：8.5.12 / 8.4.27 / 8.3.36 / 8.2.35
# ---------------------------------------------------------------------------

FROM php:8.5.12-fpm-alpine3.24

LABEL org.opencontainers.image.title="phpallinone" \
      org.opencontainers.image.description="Nginx + PHP-FPM + Supervisor all-in-one image for Symfony (OPcache + JIT)" \
      org.opencontainers.image.authors="nICKZHUO <sidewindermax@hotmail.com>" \
      org.opencontainers.image.source="https://github.com/nickzhuo/phpallinone" \
      org.opencontainers.image.licenses="MIT"

ENV php_conf=/usr/local/etc/php-fpm.conf \
    fpm_conf=/usr/local/etc/php-fpm.d/www.conf \
    php_vars=/usr/local/etc/php/conf.d/docker-vars.ini \
    NGINX_VERSION=1.30.6 \
    NGINX_SHA256=3cf46f5ed7504d460125866b7bea99fb357f31d887e2e63b35503310e9b8b6c8 \
    PATH=/usr/local/nginx/sbin:${PATH}

# ---------------------------------------------------------------------------
# 1. 运行期基础包 + www 用户
#    注意：这里装的都是"最终镜像要留的"；构建期工具一律走 --virtual，用完即删
#
#    刻意不装 git / openssh-client / python3 / py3-pip：
#      - 本镜像定位是"运行时"。composer 装依赖请用 --prefer-dist，
#        delta 项目的 95 个依赖实测全部带 dist 包，不需要 git 命令
#      - 若你的项目有包只能从 git source 安装，或要拉 SSH 私有仓库，
#        请在自己的子镜像里补装 git / openssh-client
# ---------------------------------------------------------------------------
RUN set -eux; \
    addgroup -S www; \
    adduser -D -S -h /var/cache/www -s /sbin/nologin -G www www; \
    apk add --no-cache \
        bash \
        ca-certificates \
        curl \
        freetype \
        icu-libs \
        less \
        libjpeg-turbo \
        libmcrypt \
        libpng \
        supervisor \
        tzdata \
        vim \
        wget

# ---------------------------------------------------------------------------
# 2. Nginx：源码编译
#    - 1.24.0 -> 1.30.6（1.24 已进 legacy）
#    - 加 SHA256 校验：原脚本裸 curl 下载，无任何完整性校验
#    - 走 PCRE2（nginx 1.30 默认），不再需要 pcre-dev
#    - 补 realip / stub_status / threads 模块
# ---------------------------------------------------------------------------
RUN set -eux; \
    apk add --no-cache --virtual .nginx-build-deps \
        gcc make musl-dev linux-headers pcre2-dev zlib-dev openssl-dev; \
    mkdir -p /usr/src /var/log/nginx; \
    curl -fsSL -o /tmp/nginx.tar.gz "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz"; \
    echo "${NGINX_SHA256}  /tmp/nginx.tar.gz" | sha256sum -c -; \
    tar -zxC /usr/src -f /tmp/nginx.tar.gz; \
    rm -f /tmp/nginx.tar.gz; \
    cd "/usr/src/nginx-${NGINX_VERSION}"; \
    ./configure \
        --prefix=/usr/local/nginx \
        --user=www --group=www \
        --error-log-path=/var/log/nginx/nginx_error.log \
        --http-log-path=/var/log/nginx/nginx_access.log \
        --pid-path=/var/run/nginx.pid \
        --with-threads \
        --with-http_ssl_module \
        --with-http_v2_module \
        --with-http_realip_module \
        --with-http_gzip_static_module \
        --with-http_stub_status_module \
        --with-cc-opt="-O2"; \
    make -j"$(nproc)"; \
    make install; \
    cd /; \
    rm -rf "/usr/src/nginx-${NGINX_VERSION}"; \
    apk del --no-network .nginx-build-deps; \
    /usr/local/nginx/sbin/nginx -V

# ---------------------------------------------------------------------------
# 3. PHP 扩展
#    - 构建期依赖放 .php-build-deps，编译完删掉（原脚本把 gcc/rust/cargo 全留下了）
#    - 运行期库（libpng/libjpeg-turbo/freetype/icu-libs/libmcrypt）已在第 1 步显式安装，
#      避免 apk del 时被当作孤儿依赖连带删除
# ---------------------------------------------------------------------------
RUN set -eux; \
    apk add --no-cache --virtual .php-build-deps \
        autoconf gcc make musl-dev linux-headers \
        icu-dev libjpeg-turbo-dev libmcrypt-dev libpng-dev freetype-dev; \
    pecl update-channels; \
    # mcrypt 必须 >= 1.0.9：1.0.7 在 PHP 8.4/8.5 上能编译通过但运行时崩
    # （Undefined symbol "php_rand"），1.0.9 的 changelog 明确支持 8.4/8.5
    pecl install mcrypt-1.0.9 redis; \
    docker-php-ext-configure gd --enable-gd --with-freetype --with-jpeg; \
    # 注意：PHP 8.5 起 opcache 已静态编译进 PHP 核心（镜像里 php -m 直接有 Zend OPcache），
    # 不能再走 docker-php-ext-install opcache —— 那会因为 ext/opcache 不产出 modules/*.so 而失败：
    #   cp: can't stat 'modules/*': No such file or directory
    docker-php-ext-install -j"$(nproc)" pdo_mysql mysqli gd exif fileinfo intl; \
    docker-php-ext-enable redis mcrypt; \
    docker-php-source delete; \
    rm -rf /tmp/pear; \
    apk del --no-network .php-build-deps; \
    php -v

# 构建期断言：扩展真的被编译进去了，而不是"看起来装过"
# 注意：opcache 的模块名是 "Zend OPcache"（Zend 扩展），用 extension_loaded('opcache') 永远是 false
RUN set -eux; \
    for ext in pdo_mysql mysqli gd exif fileinfo intl redis mcrypt; do \
        php -r "exit(extension_loaded('$ext') ? 0 : 1);" \
          || { echo "FATAL: PHP extension missing: $ext"; php -m; exit 1; }; \
    done; \
    php -r "exit(extension_loaded('Zend OPcache') ? 0 : 1);" \
      || { echo "FATAL: PHP extension missing: Zend OPcache"; php -m; exit 1; }; \
    echo "OK: all PHP extensions loaded"; \
    php -m

# ---------------------------------------------------------------------------
# 4. Composer（官方 SHA384 签名校验；校验不过直接 fail，不再静默继续）
# ---------------------------------------------------------------------------
RUN set -eux; \
    EXPECTED_SIGNATURE="$(curl -fsSL https://composer.github.io/installer.sig)"; \
    curl -fsSL -o composer-setup.php https://getcomposer.org/installer; \
    ACTUAL_SIGNATURE="$(php -r 'echo hash_file("sha384", "composer-setup.php");')"; \
    if [ "$EXPECTED_SIGNATURE" != "$ACTUAL_SIGNATURE" ]; then \
        echo "FATAL: composer installer signature mismatch"; \
        echo "  expected: $EXPECTED_SIGNATURE"; \
        echo "  actual  : $ACTUAL_SIGNATURE"; \
        exit 1; \
    fi; \
    php composer-setup.php --quiet --install-dir=/usr/bin --filename=composer; \
    rm -f composer-setup.php; \
    composer --version

# ---------------------------------------------------------------------------
# 5. php.ini + 覆盖项
#    php2shell 纵深防御：session.upload_progress.enabled=0
#    （官方推荐的缓解项；补丁已打，这层是额外兜底）
# ---------------------------------------------------------------------------
RUN set -eux; \
    mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"; \
    printf '%s\n' \
        'cgi.fix_pathinfo=0' \
        'expose_php=Off' \
        'opcache.enable=1' \
        'opcache.enable_cli=1' \
        'opcache.memory_consumption=512' \
        'opcache.max_accelerated_files=20000' \
        'opcache.validate_timestamps=0' \
        'opcache.jit=tracing' \
        'opcache.jit_buffer_size=64M' \
        'realpath_cache_size=4096K' \
        'realpath_cache_ttl=600' \
        'upload_max_filesize=100M' \
        'post_max_size=100M' \
        'variables_order=EGPCS' \
        'memory_limit=128M' \
        'date.timezone=Asia/Shanghai' \
        'session.upload_progress.enabled=0' \
        > "$php_vars"; \
    grep -qx 'session.upload_progress.enabled=0' "$php_vars"; \
    grep -qx 'expose_php=Off' "$php_vars"

# ---------------------------------------------------------------------------
# 6. php-fpm 调优
#    坑一：官方镜像的 www.conf 里 listen 是**注释状态**（;listen = 127.0.0.1:9000），
#          必须用 ^;*listen 才能匹配上，用 ^listen 会永远匹配不到。
#    坑二：Alpine 是 busybox sed，避免用 GNU 专有语法。
#    每条替换后都做 grep 断言：没生效就构建失败，不允许"静默产出错误配置"。
# ---------------------------------------------------------------------------
RUN set -eux; \
    sed -i \
        -e 's/^;catch_workers_output[[:space:]]*=[[:space:]]*yes/catch_workers_output = yes/' \
        -e 's/^pm = dynamic/pm = static/' \
        -e 's/^pm\.max_children = 5/pm.max_children = 100/' \
        -e 's/^pm\.start_servers = 2/pm.start_servers = 8/' \
        -e 's/^pm\.min_spare_servers = 1/pm.min_spare_servers = 4/' \
        -e 's/^pm\.max_spare_servers = 3/pm.max_spare_servers = 8/' \
        -e 's/^;pm\.max_requests = 500/pm.max_requests = 2000/' \
        -e 's/^user = www-data/user = www/' \
        -e 's/^group = www-data/group = www/' \
        -e 's/^;listen\.mode = 0660/listen.mode = 0666/' \
        -e 's/^;listen\.owner = www-data/listen.owner = www/' \
        -e 's/^;listen\.group = www-data/listen.group = www/' \
        -e 's#^;*listen = 127\.0\.0\.1:9000#listen = /dev/shm/php-fpm.sock#' \
        -e 's/^;clear_env = no$/clear_env = no/' \
        "$fpm_conf"; \
    grep -qx 'pm = static'                                     "$fpm_conf" || { echo "FATAL: pm 未设为 static";        grep -n '^pm' "$fpm_conf"; exit 1; }; \
    grep -qx 'pm.max_children = 100'                           "$fpm_conf" || { echo "FATAL: pm.max_children 未生效";   exit 1; }; \
    grep -qx 'user = www'                                      "$fpm_conf" || { echo "FATAL: user 未设为 www";          exit 1; }; \
    grep -qx 'group = www'                                     "$fpm_conf" || { echo "FATAL: group 未设为 www";         exit 1; }; \
    grep -qx 'listen = /dev/shm/php-fpm.sock'                  "$fpm_conf" || { echo "FATAL: listen 未设为 unix socket"; grep -n 'listen' "$fpm_conf"; exit 1; }; \
    grep -qx 'catch_workers_output = yes'                      "$fpm_conf" || { echo "FATAL: catch_workers_output 未开启"; exit 1; }; \
    grep -qx 'clear_env = no'                                  "$fpm_conf" || { echo "FATAL: clear_env 未关闭";         exit 1; }; \
    php-fpm -t

# ---------------------------------------------------------------------------
# 7. 配置文件（放最后，改配置不会触发前面的重编译）
# ---------------------------------------------------------------------------
COPY ./conf/supervisord/supervisord.conf /etc/supervisord.conf
COPY ./conf/supervisord/php-fpm.conf     /etc/supervisor/php-fpm.conf
COPY ./conf/supervisord/nginx.conf       /etc/supervisor/nginx.conf
COPY ./conf/nginx/nginx.conf             /usr/local/nginx/conf/nginx.conf
COPY ./conf/nginx/symfony.conf           /usr/local/nginx/conf/vhost/symfony.conf

# 配置语法自检：nginx 配置写错，构建期就炸，不要等到容器起不来
RUN set -eux; \
    /usr/local/nginx/sbin/nginx -t

# ---------------------------------------------------------------------------
# 8. 代码与启动脚本
# ---------------------------------------------------------------------------
COPY ./code/index.php /data/www/public/index.php
COPY ./scripts/start.sh /start.sh
RUN chmod 755 /start.sh

EXPOSE 80

WORKDIR /var

CMD ["/start.sh"]
