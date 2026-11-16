# L2TP IP Manager

Ubuntu / Debian 纯 L2TP 服务及账号管理脚本。支持多个入口 IP、账号固定公网出口、单账号并发限制和批量管理。

## 开始使用

在服务器上以 root 下载并运行 [当前发布版 v2026.11.16-nat1](https://github.com/zhou1050/l2tp-ip-manager/releases/tag/v2026.11.16-nat1)：

```bash
curl -fL https://github.com/zhou1050/l2tp-ip-manager/releases/download/v2026.11.16-nat1/sh.sh -o sh-nat1.sh &&
bash sh-nat1.sh install
```

在 Debian 12 的 `6.1.0-54-cloud-amd64`（Debian `6.1.190-1`）上，如果系统无法加载 PPP 模块，安装脚本会尝试从对应的 [GitHub Release](https://github.com/zhou1050/l2tp-ip-manager/releases) 下载并校验模块。下载或校验失败时，脚本用 Debian 软件源中同版本的内核头文件和源码在服务器上编译。模块安装后仍须通过 PPP 设备检查。

如果网卡只有私网 IPv4，且系统有唯一默认出口，脚本会使用该出口的首选私网源地址（或网卡上唯一的私网 IPv4）监听并执行 SNAT。使用云平台公网 IPv4 拨号时，公网地址需映射到该私网地址，云防火墙需允许配置的 UDP 拨号端口。此模式使用一个本机地址，上游平台决定客户端实际看到的公网出口。

旧版安装保留账号升级使用 `bash sh.sh egress`，切换会断开现有拨号；`install` 会重建本脚本账号。

安装和转发无需开启 BBR。

## 账号固定出口

允许拨入任意入口：例如 hka1 绑定 .60，拨入 .60 或 .61 都从 .60 出口。未绑定账号跟随拨入 IP。

```bash
# 给已存在的 hka1、hka2 依次绑定 .60、.61
bash sh.sh account batch-bind --prefix hka --start 1 --count 2 --ip-start 118.107.221.60

# 批量新建并按文件分配出口，文件每行一个已配置的本机公网 IP
bash sh.sh account batch-add --prefix line --start 1 --count 60 --ip-file /root/ips.txt

bash sh.sh account bind --username hka1 --ip 118.107.221.60
bash sh.sh account bind --username hka1 --clear-ip
bash sh.sh account list
```

从 `2026.10.26-admin3` 起，菜单 **19 批量绑定出口 IP → 3 多个 IP 循环分配** 可直接输入账号前缀、起始序号、数量和 IP 列表，不必逐个绑定或创建临时文件。例如 245 个已存在的账号：

```bash
bash sh.sh account batch-bind --prefix hka --start 1 --count 245 \
  --ip-cycle 118.107.221.61,118.107.221.67,118.107.221.73,118.107.221.74,118.107.221.60
```

按输入顺序循环：hka1/hka6/... 使用 .61，hka2/hka7/... 使用 .67；245 个账号对应每个 IP 49 个账号。循环从所选起始账号重新开始。所有账号和 IP 先校验，缺失则整批不写入；绑定保留原密码。数量应填写实际已创建的账号数，绑定操作不会自动新增账号。菜单 19 还支持同一 IP、连续 IP、逐行 IP 文件和取消绑定。

绑定在下一次拨号生效；可添加 `--disconnect` 断开当前受管连接。IP 必须存在于本机入口映射；批量校验失败不部分写入。每个入口使用独立地址池，会话上线前配置独立 SNAT，下线清理。

## 管理

```bash
bash sh.sh account add --username line1
bash sh.sh account mod --username line1
bash sh.sh account del --username line1
bash sh.sh account batch-mod --prefix line --count 60
bash sh.sh account batch-disable --prefix line --count 60
bash sh.sh account batch-enable --prefix line --count 60
bash sh.sh limit 2
bash sh.sh log
bash sh.sh check
bash sh.sh uninstall
```

密码交互输入不回显；自动化可用 `--password-file`。导出默认不含密码，显式 `--with-passwords` 才生成可恢复的密码文件。卸载先备份，仅清理受管服务和规则；可用 `--keep-accounts` 保留账号。

## 系统与测试

复测目标：Debian 12、Debian 13、Ubuntu 22.04 LTS、Ubuntu 24.04 LTS。自动化包含发行版软件包安装、systemd 实例启动、真实 PPP 拨号、跨入口固定出口、同账号并发拒绝、下线清理和卸载保留账号。详见 [测试报告](TEST_REPORT.md) 与 [完整使用说明](使用说明.md)。

容器测试覆盖公网 IPv4 和单默认出口的私网 IPv4 监听、拨号及 SNAT。云平台公网映射和防火墙仍需现场验证。运行需要 systemd 和 PPP 驱动。多默认出口或策略路由需要单独整合。纯 L2TP 不包含 IPsec 流量加密。

在专用测试机上重跑：

```bash
sudo modprobe ppp_async
# /dev/ppp 不存在时加载 ppp_generic 并按系统要求创建节点
python3 -m unittest discover -s . -p 'test_*.py' -v
docker build -f tests/Dockerfile --build-arg BASE=debian:12-slim -t codex-l2tp-test:debian12 .
python3 tests/docker_smoke.py debian12 --output reports/debian12.json
```

集成测试需要 Docker 和 PPP 设备。服务端测试容器使用 privileged 与私有 cgroup 命名空间以启动 systemd；不挂载宿主机目录，也不使用宿主机网络。测试结束清理自己创建的容器和网络。
