FROM centos:7
# 舟哥的PHP7全功能技术栈 专为symfony准备
MAINTAINER nICKZHUO <sidewindermax@hotmail.com>

ENV NGINX_VERSION 1.11.9
ENV PHP_VERSION 7.1.1

# 安装基本编译模块
RUN set -x && \
    yum install -y gcc \
    gcc-c++ \
    autoconf \
    automake \
    libtool \
    wget \
    vim \
    make \
    cmake

# 安装周边
## libmcrypt-devel DIY
RUN rpm -ivh http://dl.fedoraproject.org/pub/epel/6/i386/epel-release-6-8.noarch.rpm && \
    yum install -y zlib \
    zlib-devel \
    openssl \
    openssl-devel \
    pcre-devel \
    libxml2 \
    libxml2-devel \
    libcurl \
    libcurl-devel \
    libpng-devel \
    libjpeg-devel \
    freetype-devel \
    libmcrypt-devel \
    openssh-server \
    python-setuptools \
    libicu-devel

# 增加用户 还是要给bash的，要跑composer的
RUN mkdir -p /data/phpext && \
    useradd -r -s /bin/bash -d /data/www -m -k no www

# 下载源代码
RUN mkdir -p /home/nginx-php && cd $_ && \
    curl -Lk http://nginx.org/download/nginx-$NGINX_VERSION.tar.gz | gunzip | tar x -C /home/nginx-php && \
    curl -Lk http://php.net/distributions/php-$PHP_VERSION.tar.gz | gunzip | tar x -C /home/nginx-php

# 安装nginx
RUN cd /home/nginx-php/nginx-$NGINX_VERSION && \
    ./configure --prefix=/usr/local/nginx \
    --user=www --group=www \
    --error-log-path=/var/log/nginx_error.log \
    --http-log-path=/var/log/nginx_access.log \
    --pid-path=/var/run/nginx.pid \
    --with-pcre \
    --with-http_ssl_module \
    --without-mail_pop3_module \
    --without-mail_imap_module \
    --with-http_gzip_static_module && \
    make && make install

# 安装php
RUN cd /home/nginx-php/php-$PHP_VERSION && \
    ./configure --prefix=/usr/local/php \
    --with-config-file-path=/usr/local/php/etc \
    --with-config-file-scan-dir=/usr/local/php/etc/php.d \
    --with-fpm-user=www \
    --with-fpm-group=www \
    --with-mcrypt=/usr/include \
    --with-mysqli \
    --with-pdo-mysql \
    --with-openssl \
    --with-gd \
    --with-iconv \
    --with-zlib \
    --with-gettext \
    --with-curl \
    --with-png-dir \
    --with-jpeg-dir \
    --with-freetype-dir \
    --with-xmlrpc \
    --with-mhash \
    --enable-fpm \
    --enable-xml \
    --enable-shmop \
    --enable-sysvsem \
    --enable-inline-optimization \
    --enable-mbregex \
    --enable-mbstring \
    --enable-ftp \
    --enable-gd-native-ttf \
    --enable-mysqlnd \
    --enable-pcntl \
    --enable-sockets \
    --enable-zip \
    --enable-soap \
    --enable-session \
    --enable-opcache \
    --enable-bcmath \
    --enable-exif \
    --enable-fileinfo \
    --disable-rpath \
    --enable-ipv6 \
    --disable-debug \
    --enable-intl \
    --without-pear && \
    make && make install

# 安装php-fpm
RUN cd /home/nginx-php/php-$PHP_VERSION && \
    cp php.ini-production /usr/local/php/etc/php.ini && \
    cp /usr/local/php/etc/php-fpm.conf.default /usr/local/php/etc/php-fpm.conf && \
    cp /usr/local/php/etc/php-fpm.d/www.conf.default /usr/local/php/etc/php-fpm.d/www.conf

# 安装re2c 0.16
RUN cd /home/nginx-php/ && \
    wget https://github.com/skvadrik/re2c/releases/download/0.16/re2c-0.16.tar.gz && \
    tar -zxvf re2c-0.16.tar.gz && \
    cd /home/nginx-php/re2c-0.16 && \
    ./configure && \
    make && make install

# 安装redis客户端3.0.0
RUN cd /home/nginx-php/ && \
    wget https://github.com/phpredis/phpredis/archive/3.0.0.tar.gz && \
    tar -zxvf 3.0.0.tar.gz && \
    cd /home/nginx-php/phpredis-3.0.0 && \
    /usr/local/php/bin/phpize && \
    ./configure --with-php-config=/usr/local/php/bin/php-config && \
    make && make install

# 安装swoole 2.05
RUN cd /home/nginx-php/ && \
    wget https://github.com/swoole/swoole-src/archive/v2.0.5.tar.gz && \
    tar -zxvf v2.0.5.tar.gz && \
    cd /home/nginx-php/swoole-src-2.0.5 && \
    /usr/local/php/bin/phpize && \
    ./configure --with-php-config=/usr/local/php/bin/php-config --enable-coroutine && \
    make && make install

# 调整php.ini
RUN sed -i'' 's/^;cgi.fix_pathinfo=1/cgi.fix_pathinfo=0/g' /usr/local/php/etc/php.ini && \
    sed -i'' 's/^;opcache.enable=0/opcache.enable=1/g' /usr/local/php/etc/php.ini && \
    sed -i'' 's/^;opcache.enable_cli=0/opcache.enable_cli=1/g' /usr/local/php/etc/php.ini && \
    sed -i'' 's@^;realpath_cache_size.*@realpath_cache_size = 5M@' /usr/local/php/etc/php.ini && \
    sed -i'' 's/^;opcache.file_cache=/opcache.file_cache=\/tmp/g' /usr/local/php/etc/php.ini && \
    sed -i'' 's/^;date.timezone =/date.timezone = PRC/g' /usr/local/php/etc/php.ini

# 开启扩展
RUN echo 'extension=redis.so' >> /usr/local/php/etc/php.ini
RUN echo 'extension=swoole.so' >> /usr/local/php/etc/php.ini

# 安装supervisor
RUN easy_install supervisor && \
    mkdir -p /var/{log/supervisor,run/{sshd,supervisord}}

# 清除垃圾文件
RUN yum remove -y gcc \
    gcc-c++ \
    autoconf \
    automake \
    libtool \
    make \
    cmake && \
    yum clean all && \
    rm -rf /tmp/* /var/cache/{yum,ldconfig} /etc/my.cnf{,.d} && \
    mkdir -p --mode=0755 /var/cache/{yum,ldconfig} && \
    find /var/log -type f -delete && \
    rm -rf /home/nginx-php

# 设置时区
RUN rm /etc/localtime
RUN ln -s /usr/share/zoneinfo/Asia/Shanghai /etc/localtime

# 复制php到bin下面 否则麻烦
RUN ln -s /usr/local/php/bin/php /usr/local/bin
RUN php --version

# 安装 Composer
RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
RUN composer --version

# 挂载代码文件到容器
COPY ./code/app.php /data/www/web/

# 代码复制之后设置权限
RUN chown -R www:www /data/www

# supervisor配置文件
COPY ./conf/supervisord/supervisord.conf /etc/
# 分解的supervisor配置
RUN mkdir -p /etc/supervisor/
COPY ./conf/supervisord/php-fpm.conf /etc/supervisor/
COPY ./conf/supervisord/nginx.conf /etc/supervisor/

# nginx配置文件 symfony放在site里 注意路径是 /usr/local/nginx/conf/
COPY ./conf/nginx/nginx.conf /usr/local/nginx/conf/
COPY ./conf/nginx/symfony.conf /usr/local/nginx/conf/vhost/

# 环境准备
COPY ./env/.vimrc /root/

# 入口文件准备
COPY ./scripts/docker-entrypoint.sh /
RUN chmod +x /docker-entrypoint.sh

# 启动命令准备
COPY ./scripts/docker-run-dev.sh /
RUN chmod +x /docker-run-dev.sh
COPY ./scripts/docker-run-prod.sh /
RUN chmod +x /docker-run-prod.sh

# 暴露端口 只留80 证书放在反向上面处理
EXPOSE 80

# 运行 该镜像包含的是测试页面 
CMD ["/bin/bash","/docker-entrypoint.sh"]