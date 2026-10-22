#!/bin/sh
set -e

# 前台启动 supervisord，由它拉起 nginx + php-fpm
exec /usr/bin/supervisord -n -c /etc/supervisord.conf
