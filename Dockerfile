FROM php:8.2.5-fpm-alpine3.17

LABEL maintainer="nICKZHUO <sidewindermax@hotmail.com>"

ENV php_conf /usr/local/etc/php-fpm.conf
ENV fpm_conf /usr/local/etc/php-fpm.d/www.conf
ENV php_vars /usr/local/etc/php/conf.d/docker-vars.ini

# Nginx版本
ENV NGINX_VERSION 1.24.0

ENV LD_PRELOAD /usr/lib/preloadable_libiconv.so php
RUN apk add --no-cache --repository http://dl-3.alpinelinux.org/alpine/edge/community gnu-libiconv

RUN addgroup -S www \
  && adduser -D -S -h /var/cache/www -s /sbin/nologin -G www www \ 
  && apk add --no-cache --virtual .build-deps \
    autoconf \
    gcc \
    vim \
    git \
    libc-dev \
    make \
    openssl-dev \
    pcre-dev \
    zlib-dev \
    linux-headers \
    curl \
    gnupg \
    libxslt-dev \
    gd-dev \
    geoip-dev \
    perl-dev
  
  RUN curl -fSL http://nginx.org/download/nginx-$NGINX_VERSION.tar.gz -o nginx.tar.gz \
    && mkdir -p /usr/src \
    && tar -zxC /usr/src -f nginx.tar.gz \
    && cd /usr/src/nginx-$NGINX_VERSION \
    && ./configure --prefix=/usr/local/nginx \
      --user=www --group=www \
      --error-log-path=/var/log/nginx/nginx_error.log \
      --http-log-path=/var/log/nginx/nginx_access.log \
      --pid-path=/var/run/nginx.pid \
      --with-pcre \
      --with-http_ssl_module \
      --without-mail_pop3_module \
      --without-mail_imap_module \
      --with-http_gzip_static_module && \
      make && make install

# alpine 3.13升级之后指定py3
RUN echo @testing http://nl.alpinelinux.org/alpine/edge/testing >> /etc/apk/repositories && \
#    sed -i -e "s/v3.4/edge/" /etc/apk/repositories && \
    echo /etc/apk/respositories && \
    apk update && \
    apk add --no-cache bash \
    openssh-client \
    wget \
    supervisor \
    curl \
    libcurl \
    python3 \
    python3-dev \
    rust \
    cargo \
    py3-pip \
    augeas-dev \
    openssl-dev \
    ca-certificates \
    dialog \
    autoconf \
    make \
    gcc \
    musl-dev \
    linux-headers \
    libmcrypt-dev \
    libpng-dev \
    icu-dev \
    libpq \
    libxslt-dev \
    libffi-dev \
    freetype-dev \
    sqlite-dev \
    libjpeg-turbo-dev

#PECL先update一下
RUN pecl update-channels

# 加入redis
RUN pecl install mcrypt && \
    pecl install redis

# 跑GD要配置下
RUN docker-php-ext-configure gd \
      --enable-gd \
      --with-freetype \
      --with-jpeg

RUN docker-php-ext-install pdo_mysql mysqli gd exif fileinfo intl opcache

RUN docker-php-ext-enable redis.so && \
  docker-php-ext-enable mcrypt.so && \
  docker-php-source delete

# 安装composer    
RUN EXPECTED_COMPOSER_SIGNATURE=$(wget -q -O - https://composer.github.io/installer.sig) && \
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" && \
    php -r "if (hash_file('SHA384', 'composer-setup.php') === '${EXPECTED_COMPOSER_SIGNATURE}') { echo 'Composer.phar Installer verified'; } else { echo 'Composer.phar Installer corrupt'; unlink('composer-setup.php'); } echo PHP_EOL;" && \
    php composer-setup.php --install-dir=/usr/bin --filename=composer && \
    php -r "unlink('composer-setup.php');"

# 安装pip相关    
RUN pip install -U pip
# 删除多余的
RUN apk del gcc musl-dev linux-headers libffi-dev augeas-dev make autoconf

# supervisor的配置文件复制过去
# supervisor配置文件
ADD ./conf/supervisord/supervisord.conf /etc/
# 分解的supervisor配置
RUN mkdir -p /etc/supervisor/
ADD ./conf/supervisord/php-fpm.conf /etc/supervisor/
ADD ./conf/supervisord/nginx.conf /etc/supervisor/

# nginx配置文件 symfony放在site里 注意路径是 /usr/local/nginx/conf/
COPY ./conf/nginx/nginx.conf /usr/local/nginx/conf/
COPY ./conf/nginx/symfony.conf /usr/local/nginx/conf/vhost/

# 修改 生产环境的 php.ini 基于默认的来吧
RUN mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"

# 把需要覆盖的配置都放到一起 加入php8的jit配置
RUN echo "cgi.fix_pathinfo=0" > ${php_vars} &&\
    echo "opcache.enable=1" >> ${php_vars} &&\
    echo "opcache.enable_cli=1" >> ${php_vars} &&\
    echo "opcache.memory_consumption=512" >> ${php_vars} &&\
    echo "opcache.max_accelerated_files=20000" >> ${php_vars} &&\
    echo "opcache.validate_timestamps=0" >> ${php_vars} &&\
    echo "opcache.jit=1205" >> ${php_vars} &&\
    echo "opcache.jit_buffer_size=64M" >> ${php_vars} &&\
    echo "realpath_cache_size=4096K" >> ${php_vars} &&\
    echo "realpath_cache_ttl=600" >> ${php_vars} &&\
    echo "upload_max_filesize=100M"  >> ${php_vars} &&\
    echo "post_max_size=100M"  >> ${php_vars} &&\
    echo "variables_order=\"EGPCS\""  >> ${php_vars} && \
    echo "memory_limit=128M"  >> ${php_vars} && \
    echo "date.timezone=Asia/Shanghai"  >> ${php_vars}

# 优化 php-fpm 配置 开发环境
#-e "s/;php_admin_value\[error_log\] = \/var\/log\/fpm-php.www.log/php_admin_value\[error_log\] = \/proc\/1\/fd\/2/g" \

RUN sed -i \
    -e "s/;catch_workers_output\s*=\s*yes/catch_workers_output = yes/g" \
    -e "s/pm = dynamic/pm = static/g" \
    -e "s/pm.max_children = 5/pm.max_children = 100/g" \
    -e "s/pm.start_servers = 2/pm.start_servers = 8/g" \
    -e "s/pm.min_spare_servers = 1/pm.min_spare_servers = 4/g" \
    -e "s/pm.max_spare_servers = 3/pm.max_spare_servers = 8/g" \
    -e "s/;pm.max_requests = 500/pm.max_requests = 2000/g" \
    -e "s/user = www-data/user = www/g" \
    -e "s/group = www-data/group = www/g" \
    -e "s/;listen.mode = 0660/listen.mode = 0666/g" \
    -e "s/;listen.owner = www-data/listen.owner = www/g" \
    -e "s/;listen.group = www-data/listen.group = www/g" \
    -e "s/listen = 127.0.0.1:9000/listen = \/dev\/shm\/php-fpm.sock/g" \
    -e "s/^;clear_env = no$/clear_env = no/" \
    ${fpm_conf}

# 挂载代码文件到容器
COPY ./code/index.php /data/www/public/

# 添加启动脚本
ADD scripts/start.sh /start.sh
RUN chmod 755 /start.sh

EXPOSE 80

# 工作目录还是显示定义下
WORKDIR "/var"
# 用CMD启动 方便run时候覆盖掉
CMD ["/start.sh"]