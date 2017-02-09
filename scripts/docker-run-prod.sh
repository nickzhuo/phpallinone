#!/bin/sh
################
# 启动symfony 生产环境
echo 'PRODUCTION ENVIRONMENT'
# 打印时间
date
# 执行composer
su www -c 'cd /data/www && SYMFONY_ENV=prod composer update nothing --no-dev --no-ansi --no-interaction --no-progress --optimize-autoloader --prefer-dist'
# 用supervisor管理 睡到背景里去
/usr/bin/supervisord -n -c /etc/supervisord.conf