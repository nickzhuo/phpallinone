# 舟哥全功能PHP栈 nICKZHUO_PHP_FULL_STACK_ALL_IN_ONE
## 说明
基于Docker的PHP8容器，专为Symfony设计，开启opcache和JIT。基于alpine版本的基础镜像，减少容量，根据Symfony手册优化了性能。

## 直接最新已构建完成镜像
* 可以拉取腾讯云TKE镜像中心 ccr.ccs.tencentyun.com/zhouzhou/phpallinone
* Docker官方HUB [nickzhuo919/phpallinone](https://hub.docker.com/r/nickzhuo919/phpallinone)
* 源代码地址 https://github.com/nickzhuo/phpallinone

# 更新说明
* 21.4.15 修正了基础镜像升级到alphine 3.13之后python相关编译出的问题。
* 23.4.20 全面升级到了PHP8，开启JIT配置。
* 26.10.22 安全修复 php2shell（CVE-2026-109618 / CVE-2026-109619，CVSS 9.2）：
  PHP 8.2.5 → **8.2.35**、Nginx 1.24.0 → 1.30.6、Alpine 3.17 → 3.24。
  同时关掉 `session.upload_progress`（官方缓解项）、去掉失效的 LD_PRELOAD iconv hack、
  构建依赖改为用完即删、nginx 源码加 SHA256 校验。

> **注意**：PHP 8.2 的安全支持 **2026-12-31 到期**，之后请迁移到 8.4.x。

## 配置
* Nginx: 1.30.6
* PHP: 8.2.35
* ALPINE: 3.24

## 详细说明
* 专门为了跑Symfony做的容器，一个nginx，一个php8fpm，以及PHP的周边扩展。为了更好的兼容（docker中volume顺序会导致chown权限丢失等问题），去掉了volume的挂载，作为base镜像，建议在子镜像中开启挂载或者手工命令行挂载，避免问题。
* 请将自己的symfony项目放到/data/www目录，站点默认读取public目录(symfony默认web根目录，可以根据需要自己改成app目录兼容老symfony项目)，配合启动命令启动。
* 需要preload.php的可以在下挂的Symfony容器里往/usr/local/etc/php/conf.d/docker-vars.ini写配置，先写`opcache.preload=preload`路径，然后不要忘记加入`opcache.preload_user=www`。

## 目录结构说明
* code - 存放了一个phpinfo的查看演示文件，启动之后80端口显示。
* Dockerfile - 构建镜像文件，所有的部署命令
* scripts - start.sh启动脚本
* conf - 存放默认配置，包含nginx和supervisord。
* verify.sh - 构建与冒烟验证脚本。`./verify.sh --static` 只做静态检查（不依赖 docker），
  直接 `./verify.sh` 会构建镜像、起容器、校验 PHP 版本与扩展、清理测试容器。

## 使用说明
* 可以fork或者基于该镜像制作子镜像。
* 参考快速使用说明，直接使用本镜像。
* monolog最好自己控制一下自己的需求。
* `supervisorctl restart php-fpm`重启php服务

## 快速使用说明
* 可以使用`docker build`命令来构建属于自己的本地镜像，但是原则上不推荐，考虑到速度以及docker版本差异等。
* 推荐使用在公开仓库发布的最新镜像，如下操作步骤。
1. 启动`docker run -p 80:80 -v {项目在本地路径}:/data/www/ --name=myphp nickzhuo919/phpallinone:latest` 
2. `docker exec -it myphp bash`进入容器内
3. 修改项目相应的配置文件
4. 容器内修改权限`chown -R www:www /data/www`
5. 来到容器内/data/www目录下运行`composer install`更新依赖关系
6. 打开本地80口访问