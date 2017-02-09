#!/bin/sh
################
# 启动服务
################
# 用supervisor管理 睡到背景里去
/usr/bin/supervisord -n -c /etc/supervisord.conf