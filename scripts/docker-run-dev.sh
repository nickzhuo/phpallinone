#!/bin/sh
################
# 启动symfony 开发环境
echo 'DEVELOP ENVIROMENT'
# 打印时间
date
# 执行composer
su www -c 'cd /data/www && SYMFONY_ENV=dev composer update nothing --dev --no-ansi --no-interaction --no-progress --optimize-autoloader --prefer-dist'
# 用supervisor管理 睡到背景里去
/usr/bin/supervisord -n -c /etc/supervisord.conf