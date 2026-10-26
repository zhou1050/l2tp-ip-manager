# L2TP IP Manager

Ubuntu / Debian 纯 L2TP 服务及账号管理脚本。支持多个入口 IP、账号固定公网出口、单账号并发限制和批量管理。

## 开始使用

将 `sh.sh` 上传到服务器，以 root 运行：

```bash
bash sh.sh --version
bash sh.sh install
bash sh.sh menu
```

旧版安装保留账号升级使用 `bash sh.sh egress`，切换会断开现有拨号；`install` 会重建本脚本账号。

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

容器测试使用同一宿主机内核，不能代替不同云厂商网络、防护策略和独立内核版本的现场验证。需要 systemd、PPP 驱动及可用的本机公网 IPv4；多默认出口/上游 NAT 场景需要单独整合。纯 L2TP 不包含 IPsec 流量加密。

在专用测试机上重跑：

```bash
sudo modprobe ppp_async
# /dev/ppp 不存在时加载 ppp_generic 并按系统要求创建节点
python3 -m unittest discover -s . -p 'test_*.py' -v
docker build -f tests/Dockerfile --build-arg BASE=debian:12-slim -t codex-l2tp-test:debian12 .
python3 tests/docker_smoke.py debian12 --output reports/debian12.json
```

集成测试需要 Docker 和 PPP 设备。服务端测试容器使用 privileged 与私有 cgroup 命名空间以启动 systemd；不挂载宿主机目录，也不使用宿主机网络。测试结束清理自己创建的容器和网络。
