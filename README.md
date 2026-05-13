# CheckTMDB for ImmortalWrt

这是一个面向 ImmortalWrt 的脚本版 TMDB hosts 更新工具，不需要 LuCI 插件，也不需要编译 `.ipk`。

运行流程：

```text
cron
  -> /root/checktmdb/checktmdb-update.sh
  -> python3 check_tmdb.py
  -> /tmp/checktmdb.hosts
  -> dnsmasq addn-hosts
  -> Jellyfin / MoviePilot / Emby / Plex 生效
```

## 文件结构

```text
root/checktmdb/
├── check_tmdb.py
├── checktmdb-update.sh
└── install.sh
```

部署到路由器后的路径：

```text
/root/checktmdb/
├── check_tmdb.py
├── checktmdb-update.sh
└── install.sh
```

## 安装

把 `root/checktmdb` 上传到 ImmortalWrt：

```sh
scp -O -r root/checktmdb root@192.168.2.1:/root/
```

在路由器上执行：

```sh
cd /root/checktmdb
sh install.sh
```

安装脚本会做这些事：

```sh
opkg update
opkg install python3 python3-requests curl ca-bundle
uci add_list dhcp.@dnsmasq[0].addnhosts='/tmp/checktmdb.hosts'
uci commit dhcp
/etc/init.d/dnsmasq restart
/etc/init.d/cron restart
```

默认每 6 小时更新一次，默认检测香港节点。

## 自定义安装参数

支持的国家节点：

```text
hk = 香港
sg = 新加坡
jp = 日本
us = 美国
```

支持的更新间隔：

```text
6 / 12 / 24 小时
```

示例：

```sh
CHECKTMDB_COUNTRY=sg CHECKTMDB_INTERVAL=12 CHECKTMDB_IPV6=1 CHECKTMDB_TIMEOUT=1.5 sh install.sh
```

`CHECKTMDB_TIMEOUT` 是 TCP 连接测试超时，单位秒。路由器上建议保持 `1.5` 到 `2`，太大会导致首次更新很慢。

## 手动更新

```sh
/root/checktmdb/checktmdb-update.sh run
```

## 更新脚本本身

默认从 GitHub raw 地址更新：

```sh
/root/checktmdb/checktmdb-update.sh self-update
```

如果你使用自己的仓库、分支或镜像，可以覆盖下载地址。地址需要指向包含 `check_tmdb.py`、`checktmdb-update.sh`、`install.sh` 的目录：

```sh
CHECKTMDB_UPDATE_BASE='https://raw.githubusercontent.com/sunguangxian/CheckTMDB/refs/heads/main/root/checktmdb' \
  /root/checktmdb/checktmdb-update.sh self-update
```

也可以通过安装脚本触发：

```sh
cd /root/checktmdb
sh install.sh self-update
```

自更新会先下载到 `/tmp`，检查三个文件非空，并分别执行 Python/shell 语法检查，通过后才替换 `/root/checktmdb` 下的脚本。

查看状态：

```sh
/root/checktmdb/checktmdb-update.sh status
```

查看生成的 hosts：

```sh
cat /tmp/checktmdb.hosts
```

查看脚本日志：

```sh
tail -n 200 /tmp/checktmdb.log
```

查看正在运行的 CheckTMDB 任务：

```sh
/root/checktmdb/checktmdb-update.sh ps
```

停止正在运行的任务：

```sh
/root/checktmdb/checktmdb-update.sh stop
```

如果普通停止后仍未退出，强制停止：

```sh
/root/checktmdb/checktmdb-update.sh kill
```

查看系统日志：

```sh
logread -e checktmdb
```

## cron

安装脚本会写入 `/etc/crontabs/root`。

默认配置：

```cron
0 */6 * * * CHECKTMDB_COUNTRY=hk CHECKTMDB_IPV6=0 CHECKTMDB_TIMEOUT=1.5 /root/checktmdb/checktmdb-update.sh run
```

修改后重启 cron：

```sh
/etc/init.d/cron restart
```

## dnsmasq

脚本生成：

```sh
/tmp/checktmdb.hosts
```

dnsmasq 引用：

```sh
uci add_list dhcp.@dnsmasq[0].addnhosts='/tmp/checktmdb.hosts'
uci commit dhcp
/etc/init.d/dnsmasq restart
```

更新完成后执行：

```sh
/etc/init.d/dnsmasq reload
```

如果 reload 失败，更新脚本会自动退回 restart。

## 检测策略

`check_tmdb.py` 使用 Python + requests 查询 DNS over HTTPS，并选择可连接的 IP。

优先级：

1. AliDNS DoH
2. DNSPod DoH
3. Cloudflare DoH
4. Google DoH
5. 系统解析

对候选 IP 会测试 TCP 443 和 80，优先选择可连接且延迟较低的 IP。若所有候选 IP 都无法 TCP 连接，则保留第一个解析结果，避免 hosts 为空。

## 常用命令

重新安装或更新 cron：

```sh
cd /root/checktmdb
CHECKTMDB_COUNTRY=hk CHECKTMDB_INTERVAL=6 CHECKTMDB_IPV6=0 sh install.sh
```

仅更新脚本：

```sh
/root/checktmdb/checktmdb-update.sh self-update
```

仅运行一次：

```sh
CHECKTMDB_COUNTRY=jp CHECKTMDB_IPV6=1 CHECKTMDB_TIMEOUT=1.5 /root/checktmdb/checktmdb-update.sh run
```

首次运行需要等待脚本完整结束才会写入 `/tmp/checktmdb.hosts`。如果中途按 `Ctrl+C`，更新脚本会丢弃临时文件，保留原 hosts；第一次安装时原 hosts 为空，所以 `cat /tmp/checktmdb.hosts` 也会是空的。

清理 cron：

```sh
sed -i '\#/root/checktmdb/checktmdb-update.sh#d' /etc/crontabs/root
/etc/init.d/cron restart
```
