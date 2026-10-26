#!/usr/bin/env bash
# Pure L2TP installer. No IPsec/PSK. Requires Linux with systemd.
set -Eeuo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 077
SCRIPT_VERSION='2026.10.26-admin2'
fail() {
    printf '[停止] %s\n' "$*" >&2
    if [[ -n ${BACKUP:-} ]]; then echo "备份目录：$BACKUP" >&2; fi
    if [[ ${CONFIG_STARTED:-0} == 1 ]]; then echo '配置可能已部分更新；修复后重新运行 install 或依据备份恢复。' >&2; fi
    exit 1
}
#!/usr/bin/env bash
# Diagnostic helpers for l2tp2.sh; inserted into the final standalone script.
STEP='初始化'
BACKUP=''
CONFIG_STARTED=0
on_error() {
    local rc=$1 line=$2
    trap - ERR
    printf '\n[失败] 步骤：%s；脚本行：%s；退出码：%s\n' "$STEP" "$line" "$rc" >&2
    if [[ -n $BACKUP ]]; then echo "备份目录：$BACKUP" >&2; fi
    if ((CONFIG_STARTED)); then
        echo '配置可能已部分更新。修复后可重新运行；不要把服务启动误当成拨号验证通过。' >&2
        echo '诊断：bash 本脚本 check；journalctl -u xl2tpd -n 80 --no-pager' >&2
    fi
    exit "$rc"
}
trap 'on_error "$?" "$LINENO"' ERR
warn() { printf '[提示] %s\n' "$*" >&2; }
require_linux() {
    [[ $(uname -s) == Linux ]] || fail '仅支持 Linux；不要在 Windows/macOS 上运行安装。'
    command -v systemctl >/dev/null && [[ -d /run/systemd/system ]] || fail '需要以 systemd 启动的 Linux。容器/chroot/非 systemd 系统请手工部署。'
}
make_backup() {
    BACKUP=/etc/l2tp-backup/$(date +%Y%m%d-%H%M%S)-$$
    mkdir -p "$BACKUP"
    echo "备份目录：$BACKUP"
}
repair_debian_sources() {
    [[ -r /etc/os-release ]] || return 0
    local ID='' VERSION_CODENAME=''
    source /etc/os-release
    [[ $ID == debian && $VERSION_CODENAME == bullseye ]] || return 0
    STEP='检查并修复 Debian 11 官方源'
    local f tmp changed=0
    [[ -d $BACKUP/apt ]] || cp -a /etc/apt "$BACKUP/apt"
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
        [[ -f $f ]] || continue
        tmp=$(mktemp)
        awk '
        /^[[:space:]]*deb(-src)?[[:space:]]/ {
            if ($0 ~ /https?:\/\/(security\.debian\.org|deb\.debian\.org)\// || $0 ~ /https?:\/\/security\.debian\.org[[:space:]]/) {
                if ($0 ~ /bullseye-backports/) {print "# disabled by l2tp2: " $0; next}
                if ($0 ~ /security\.debian\.org/ && $0 ~ /bullseye(\/updates|-security)/) {
                    gsub(/bullseye\/updates/, "bullseye-security")
                    sub(/https?:\/\/security\.debian\.org(\/debian-security)?\/?/, "https://security.debian.org/debian-security")
                }
            }
        }
        {print}' "$f" > "$tmp"
        if ! cmp -s "$f" "$tmp"; then cat "$tmp" > "$f"; changed=1; fi
        rm -f "$tmp"
    done
    # deb822 .sources format: preserve other repositories and fields.
    for f in /etc/apt/sources.list.d/*.sources; do
        [[ -f $f ]] || continue
        tmp=$(mktemp)
        awk 'BEGIN {RS=""; ORS="\n\n"}
        {
            n=split($0,lines,"\n"); security=0; official=0; bullseye=0
            for(i=1;i<=n;i++) {
                if(lines[i] ~ /^URIs:.*https?:\/\/security\.debian\.org/) security=1
                if(lines[i] ~ /^URIs:.*https?:\/\/(security\.debian\.org|deb\.debian\.org)(\/|[[:space:]]|$)/) official=1
                if(lines[i] ~ /^Suites:.*bullseye/) bullseye=1
            }
            if(!official || !bullseye) {print; next}
            disabled=0; has_enabled=0
            for(i=1;i<=n;i++) {
                if(security && lines[i] ~ /^URIs:/)
                    gsub(/https?:\/\/security\.debian\.org(\/debian-security)?\/?/,"https://security.debian.org/debian-security",lines[i])
                if(lines[i] ~ /^Suites:/) {
                    if(security) gsub(/bullseye\/updates/,"bullseye-security",lines[i])
                    gsub(/bullseye-backports(-sloppy)?/,"",lines[i])
                    if(lines[i] ~ /^Suites:[[:space:]]*$/) disabled=1
                }
            }
            out=""
            for(i=1;i<=n;i++) {
                if(lines[i] ~ /^Enabled:/) {has_enabled=1; if(disabled) lines[i]="Enabled: no"}
                out=out (out==""?"":"\n") lines[i]
            }
            if(disabled && !has_enabled) out=out "\nEnabled: no"
            print out
        }' "$f" > "$tmp"
        if ! cmp -s "$f" "$tmp"; then cat "$tmp" > "$f"; changed=1; fi
        rm -f "$tmp"
    done
    if ((changed)); then warn '已修正 Debian 11 官方安全源路径/名称，禁用过期 backports；原配置已备份。'; fi
}
apt_refresh() {
    STEP='刷新 APT 索引'
    # Treat any repository fetch failure as an error rather than using stale lists.
    if ! apt-get -o APT::Update::Error-Mode=any -o Acquire::http::No-Cache=true -o Acquire::https::No-Cache=true update; then
        fail 'APT 更新失败：检查上方失败的源、网络、签名、时间。未绕过签名或 Release 校验。修复后重试。'
    fi
}
install_packages() {
    STEP='安装 L2TP 依赖'
    if command -v apt-get >/dev/null; then
        repair_debian_sources
        apt_refresh
        STEP='下载并安装 L2TP 依赖'
        if ! apt-get install -y xl2tpd ppp iptables iproute2 util-linux kmod python3 conntrack; then
            fail '依赖安装失败。若报 404，可能是索引与仓库文件不一致；不要用 --fix-missing 代替成功安装。运行 apt-cache policy xl2tpd ppp 查看候选版本。'
        fi
    elif command -v dnf >/dev/null; then
        dnf install -y epel-release || fail 'EPEL 安装失败，请检查系统版本和仓库。'
        dnf install -y xl2tpd ppp iptables iproute util-linux kmod python3 conntrack || fail '依赖安装失败，请检查上方包管理器错误。'
    elif command -v yum >/dev/null; then
        yum install -y epel-release || fail 'EPEL 安装失败，请检查系统版本和仓库。'
        yum install -y xl2tpd ppp iptables iproute util-linux kmod python3 conntrack || fail '依赖安装失败，请检查上方包管理器错误。'
    else fail '未找到 apt-get/dnf/yum，需要手工安装 xl2tpd、ppp、iptables、iproute、util-linux、kmod。'; fi
}
ppp_guidance() {
    local kernel virt='unknown'
    kernel=$(uname -r)
    if command -v systemd-detect-virt >/dev/null; then virt=$(systemd-detect-virt 2>/dev/null) || virt=none; fi
    warn "当前内核：$kernel；虚拟化检测：$virt（仅供诊断）。"
    if systemd-detect-virt --container >/dev/null 2>&1; then
        warn '容器需要宿主机加载 PPP 驱动并开放 /dev/ppp 权限；在容器内装内核通常无效。联系管理员。'
    elif command -v apt-get >/dev/null; then
        warn '请运行：bash 本脚本 kernel。它会安装 Debian/Ubuntu 通用内核，不会自动重启。'
        warn '安装成功后检查引导配置，重启进入新内核，再重新运行 install。不要跨内核复制 .ko 文件。'
    else
        warn '安装与运行内核匹配、包含 CONFIG_PPP 和 CONFIG_PPP_ASYNC 的内核/模块包；必要时重启或联系系统管理员。'
    fi
}
ensure_ppp_device() {
    STEP='检查 PPP 内核与设备'
    local generic_error='' async_error=''
    if command -v modprobe >/dev/null; then
        generic_error=$(modprobe ppp_generic 2>&1) || warn "$generic_error"
        async_error=$(modprobe ppp_async 2>&1) || warn "$async_error"
    else warn '未找到 modprobe；将检查内置 PPP 驱动。'; fi
    if [[ ! -e /dev/ppp ]]; then
        if ! mknod /dev/ppp c 108 0; then ppp_guidance; fail '无法创建 /dev/ppp；检查设备权限。'; fi
    fi
    [[ -c /dev/ppp ]] || fail '/dev/ppp 已存在，但不是字符设备。请检查，不会自动删除该路径。'
    [[ $(stat -c '%t:%T' /dev/ppp) == 6c:0 ]] || fail '/dev/ppp 设备号错误；应为字符设备 108:0。请手工检查。'
    chmod 600 /dev/ppp
    if ! (exec 9</dev/ppp); then
        ppp_guidance
        fail 'PPP 设备无法打开，已停止，尚未覆盖 L2TP 配置。创建节点不能替代内核驱动。'
    fi
    if [[ -n $async_error ]] && ! grep -qw ppp_async /proc/modules && ! grep -qs '^CONFIG_PPP_ASYNC=y' "/boot/config-$(uname -r)"; then
        ppp_guidance
        fail 'PPP 基础设备可用，但无法确认 ppp_async 支持。xl2tpd 需要该驱动；请提供匹配内核模块后重试。'
    fi
}
check_firewall_support() {
    STEP='检查防火墙兼容性'
    if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
        fail '检测到运行中的 firewalld。当前版本只自动管理 iptables；请先规划防火墙迁移或手工部署，避免规则重载后失效。未关闭 firewalld。'
    fi
    if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
        fail '检测到运行中的 UFW。请先配置兼容的 UDP/PPP 转发/NAT 规则并改用手工部署；当前版本不会关闭 UFW 或宣称规则已兼容。'
    fi
    if command -v nft >/dev/null && nft list ruleset 2>/dev/null | grep -Eq 'table (inet|netdev|bridge) '; then
        fail '检测到独立 nftables 规则集，iptables ACCEPT 可能仍被其他链阻断。请手工整合防火墙后部署。'
    fi
    iptables -w -L -n >/dev/null || fail '无法读取 iptables；检查权限、内核 netfilter 支持及 iptables 后端。'
}
check_port() {
    local chosen=$1 sockets
    sockets=$(ss -H -ulnp | awk -v p="$chosen" '$4 ~ (":" p "$") {print}')
    if [[ -n $sockets ]] && printf '%s\n' "$sockets" | grep -v '"xl2tpd"' >/dev/null; then
        printf '%s\n' "$sockets" >&2
        fail "UDP $chosen 已被其他进程占用。请选择其他端口。"
    fi
}
kernel_install() {
    require_linux
    command -v apt-get >/dev/null || fail 'kernel 命令仅支持 Debian/Ubuntu；其他系统请安装通用内核。'
    systemd-detect-virt --container >/dev/null 2>&1 && fail '容器不能通过安装自身内核解决 PPP；请联系宿主机管理员。'
    make_backup
    repair_debian_sources
    apt_refresh
    STEP='安装通用内核'
    local ID='' VERSION_CODENAME='' pkg
    source /etc/os-release
    case $ID in
        debian) [[ $(dpkg --print-architecture) == amd64 ]] || fail '自动安装仅支持 Debian amd64。'; pkg=linux-image-amd64 ;;
        ubuntu) pkg=linux-generic ;;
        *) fail '当前发行版不支持自动安装通用内核。' ;;
    esac
    if ! apt-get install -y "$pkg"; then
        warn '默认候选安装失败；将刷新索引并重试一次。'
        apt_refresh
        if ! apt-get install -y "$pkg"; then
            if [[ $ID == debian && -n $VERSION_CODENAME ]]; then
                warn "尝试当前发行版主仓库（$VERSION_CODENAME）的内核，版本可能低于安全仓库。"
                apt-get install -y -t "$VERSION_CODENAME" "$pkg" || fail '主仓库也无法安装。请检查上方错误或换有效的官方镜像；没有安装成功，不要重启。'
                warn '已使用主仓库回退版本；安全源恢复后请更新通用内核。'
            else fail '内核安装失败；检查镜像/网络/签名。不要重启。'; fi
        fi
    fi
    local config version target=''
    for config in /boot/config-*-amd64 /boot/config-*-generic; do
        [[ -f $config ]] || continue
        [[ $config != *-cloud-* ]] || continue
        if grep -Eq '^CONFIG_PPP=(m|y)$' "$config" && grep -Eq '^CONFIG_PPP_ASYNC=(m|y)$' "$config"; then
            version=${config##*/config-}
            [[ -s /boot/vmlinuz-$version && -s /boot/initrd.img-$version ]] || continue
            if [[ -z $target ]] || [[ $(printf '%s\n%s\n' "$target" "$version" | sort -V | tail -n 1) == "$version" ]]; then target=$version; fi
        fi
    done
    [[ -n $target ]] || fail '包管理器已运行，但未找到同时具备 PPP 支持的通用内核、vmlinuz 和 initrd。不要重启。'
    command -v update-grub >/dev/null || fail '未找到 update-grub；请按实际引导程序手工配置新内核，暂不重启。'
    update-grub || fail '更新引导配置失败，暂不重启。'
    grep -Fq "vmlinuz-$target" /boot/grub/grub.cfg || fail 'GRUB 配置中未找到目标内核；请手工检查，暂不重启。'
    echo "内核安装与引导文件检查完成：$target。未自动重启。"
    echo '保留旧内核。确认控制台可用及 GRUB 默认项后，选择维护时间运行 reboot。'
    echo "重连后运行 uname -r；确认进入 $target，再执行本脚本 install。"
}
diagnose() {
    require_linux
    local problems=0 port=1701
    echo "内核：$(uname -r)"
    systemd-detect-virt || true
    if [[ -r /etc/l2tp-pure.conf ]]; then source /etc/l2tp-pure.conf; port=$PORT; fi
    if [[ -c /dev/ppp ]] && (exec 9</dev/ppp); then echo '[通过] PPP 设备可打开'; else
        warn '[失败] PPP 设备不可用'; ppp_guidance; problems=$((problems+1))
    fi
    if command -v ss >/dev/null && ss -H -ulnp | awk -v p="$port" '$4 ~ (":" p "$") && /xl2tpd/ {found=1} END {exit !found}'; then
        echo "[通过] xl2tpd 监听 UDP $port"
    else warn "[失败] 未发现 xl2tpd 监听 UDP $port"; problems=$((problems+1)); fi
    if [[ ${ENDPOINT_MODE:-0} == 1 ]]; then
        systemctl --no-pager --full status l2tp-endpoints.target l2tp-firewall.service || problems=$((problems+1))
        local ingress subnet local_ip pool sockets
        sockets=$(ss -H -ulnp)
        while read -r ingress subnet local_ip pool; do
            if ! systemctl is-active --quiet "l2tp-endpoint@$ingress.service" ||
               ! awk -v addr="$ingress:$port" '$4==addr && /xl2tpd/ {ok=1} END {exit !ok}' <<< "$sockets"; then
                warn "[失败] 入口 $ingress:$port 未正常监听"; problems=$((problems+1))
            fi
        done < /etc/l2tp-endpoints.tsv
        cat /etc/l2tp-endpoints.tsv
        iptables -t nat -nvL L2TP_PURE_NAT || problems=$((problems+1))
        journalctl -t l2tp-egress -n 30 --no-pager || true
    else
        systemctl --no-pager --full status xl2tpd l2tp-firewall.service || problems=$((problems+1))
    fi
    ip -brief addr || true
    iptables -nvL L2TP_PURE_IN || problems=$((problems+1))
    journalctl -u xl2tpd -n 50 --no-pager || true
    journalctl -t l2tp-limit -n 20 --no-pager || true
    if [[ $(cat /proc/sys/net/ipv4/ip_forward) != 1 ]]; then
        warn '[失败] IPv4 转发未开启'; problems=$((problems+1))
    fi
    if ! grep -qw ppp_async /proc/modules && ! grep -qs '^CONFIG_PPP_ASYNC=y' "/boot/config-$(uname -r)"; then
        warn '[失败] 未确认 ppp_async 支持；检查 modprobe ppp_async'; problems=$((problems+1))
    fi
    if [[ -r /etc/ppp/chap-secrets ]]; then
        awk '$2=="l2tpd" {n++} END {printf "L2TP账号数量：%d\n", n}' /etc/ppp/chap-secrets
    fi
    echo '服务检查不能替代真实拨号。客户端关闭 IPsec；RouterOS 若不能指定目标端口，需要正确的端口转换。'
    echo "检查发现问题数：$problems"
    ((problems == 0))
}

usage() {
    cat <<'HELP'
Usage:
  bash l2tp2.sh install [--port 1701] [--username user] [--password 'secret']
                       [--count 10] [--max-connections 3] [--ip-range 192.168.18]
  bash l2tp2.sh egress             # migrate installed service; preserve accounts
  bash l2tp2.sh log [--no-follow] [--lines 100]
  bash l2tp2.sh check              # diagnose only; no configuration changes
  bash l2tp2.sh kernel             # install generic kernel; never auto-reboot
  bash l2tp2.sh menu              # interactive management
  bash l2tp2.sh account list
  bash l2tp2.sh account add|mod|del|enable|disable --username NAME
  bash l2tp2.sh account batch-add|batch-mod|batch-del|batch-enable|batch-disable
                       --prefix hka --start 1 --count 60
  bash l2tp2.sh account import|export --file PATH [--with-passwords]
  bash l2tp2.sh account bind --username hka1 --ip 118.107.221.60
  bash l2tp2.sh account batch-bind --prefix hka --count 60 --ip-start PUBLIC_IP
  bash l2tp2.sh account batch-add --prefix hka --count 60 --ip-file /root/ips.txt
  bash l2tp2.sh account kick --username NAME
  bash l2tp2.sh limit 2             # per-account concurrent limit; future logins
  bash l2tp2.sh uninstall [--yes] [--keep-accounts]
  bash l2tp2.sh --list
  bash l2tp2.sh --add
  bash l2tp2.sh --del
  bash l2tp2.sh --mod
No arguments: management menu if installed; otherwise interactive installation.
Account passwords are prompted without echo; --password-file is supported.
Delete/disable/password changes keep existing sessions unless --disconnect is given.
Count=1: exact username. Count>1: username1 ... usernameN, shared password.
Max-connections: simultaneous connections PER account (1-253).
Each local public ingress IP gets a separate /24 pool and matching SNAT.
IP pools rotate the third octet within the private /16 containing ip-range.
Only directly assigned public IPv4 addresses on one default uplink are supported.
Client must support pure L2TP and the chosen UDP destination port.
HELP
}
prompt_default() {
    local target=$1 fallback=$2 label=$3 answer=''
    if [[ -t 0 ]]; then
        read -r -p "$label [$fallback]: " answer || fail '输入中断。'
    else warn "$label 未指定，使用默认值 $fallback。可用命令行参数修改。"; fi
    printf -v "$target" '%s' "${answer:-$fallback}"
}
valid_user() { [[ $1 =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.@-]{0,63}$ ]]; }
valid_password() { [[ -n $1 && $1 != *$'\n'* && $1 != *$'\r'* && $1 != *$'\t'* ]]; }
quote_ppp() { local s=$1; s=${s//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "$s"; }
write_account() { quote_ppp "$1"; printf ' l2tpd '; quote_ppp "$2"; printf ' *\n'; }
account_exists() { awk -v u="\"$1\"" '$1==u && $2=="l2tpd" {found=1} END {exit !found}' /etc/ppp/chap-secrets; }
manage() {
    case $1 in
        -l|--list) accounts list;;
        -a|--add) accounts add;;
        -d|--del) accounts del;;
        -m|--mod) accounts mod;;
    esac
}
install_l2tp() {
    local port='' username='' password='' count='' max_connections='' iprange=''
    while (($#)); do
        case $1 in
            --port|--username|--password|--count|--max-connections|--ip-range)
                (($# >= 2)) || fail "Missing value for $1"
                case $1 in
                    --port) port=$2;; --username) username=$2;; --password) password=$2;;
                    --count) count=$2;; --max-connections) max_connections=$2;; --ip-range) iprange=$2;;
                esac
                shift 2 ;;
            *) fail "Unknown option: $1" ;;
        esac
    done
    [[ -n $port ]] || prompt_default port 1701 'UDP 拨号端口'
    [[ -n $username ]] || prompt_default username user '账号或账号前缀'
    [[ -n $password ]] || { [[ -t 0 ]] || fail '非交互运行必须提供 --password；未配置空密码。'; read -r -s -p 'Password: ' password || fail '输入中断。'; echo; }
    [[ -n $count ]] || prompt_default count 1 '批量账号数量'
    [[ -n $max_connections ]] || prompt_default max_connections 1 '单账号最大同时连接数'
    [[ -n $iprange ]] || prompt_default iprange 192.168.18 '内网地址池前缀'
    [[ $port =~ ^[0-9]{1,5}$ ]] && ((10#$port >= 1 && 10#$port <= 65535)) || fail 'Port must be 1-65535.'
    [[ $count =~ ^[0-9]{1,3}$ ]] && ((10#$count >= 1 && 10#$count <= 253)) || fail 'Account count must be 1-253.'
    [[ $max_connections =~ ^[0-9]{1,3}$ ]] && ((10#$max_connections >= 1 && 10#$max_connections <= 253)) || fail 'Connection limit must be 1-253.'
    port=$((10#$port)); count=$((10#$count)); max_connections=$((10#$max_connections))
    valid_user "$username" || fail 'Username: 1-64 letters, digits, _, ., @, -; cannot start with punctuation.'
    valid_password "$password" || fail 'Password cannot be empty or contain newline/tab.'
    local i account a b c
    for ((i=1;i<=count;i++)); do
        account=$username; ((count == 1)) || account=${username}${i}
        valid_user "$account" || fail 'Generated username is too long.'
    done
    [[ $iprange =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || fail 'Invalid IP range prefix.'
    a=$((10#${BASH_REMATCH[1]})); b=$((10#${BASH_REMATCH[2]})); c=$((10#${BASH_REMATCH[3]}))
    ((a<=255 && b<=255 && c<=255)) || fail 'Invalid IP range prefix.'
    ((a==10 || (a==172 && b>=16 && b<=31) || (a==192 && b==168))) || fail 'Use a private IPv4 range.'
    iprange=$a.$b.$c
    require_linux
    make_backup
    install_packages
    ensure_ppp_device
    check_firewall_support
    check_port "$port"
    if ((count * max_connections > 253)); then warn '账号数乘以并发上限超过 253；单个入口 IP 的地址池最多支持 253 条同时在线连接。'; fi
    local backup=$BACKUP f first_line
    STEP='备份并检查现有配置'
    mkdir -p /etc/xl2tpd /etc/ppp /usr/local/libexec
    for f in /etc/xl2tpd/xl2tpd.conf /etc/ppp/options.xl2tpd /etc/ppp/chap-secrets /etc/ppp/auth-up /etc/ppp/auth-down /etc/ppp/ip-pre-up /etc/ppp/ip-up /etc/ppp/ip-down /etc/ppp/l2tp-endpoints /etc/xl2tpd/endpoints /etc/l2tp-endpoints.tsv /usr/local/libexec/l2tp-egress /etc/systemd/system/l2tp-endpoint@.service /etc/systemd/system/l2tp-endpoints.target /etc/l2tp-pure.conf /usr/local/libexec/l2tp-limit /usr/local/libexec/l2tp-firewall /etc/systemd/system/l2tp-firewall.service /etc/sysctl.d/90-l2tp-pure.conf /etc/tmpfiles.d/l2tp-ppp.conf; do
        if [[ -e $f || -L $f ]]; then
            mkdir -p -- "$backup$(dirname -- "$f")"
            cp -a -- "$f" "$backup$f"
        fi
    done
    for f in /etc/ppp/auth-up /etc/ppp/auth-down /etc/ppp/ip-pre-up /etc/ppp/ip-up /etc/ppp/ip-down; do
        [[ -s $f ]] || continue
        IFS= read -r first_line < "$f" || true
        case $first_line in
            '#!/bin/sh'|'#!/bin/bash'|'#!/bin/dash'|'#!/usr/bin/bash'|'#!/usr/bin/env bash') ;;
            *) fail "已有认证钩子 $f 不是可识别的 shell 脚本，未覆盖；请手工整合并发限制。" ;;
        esac
    done
    plan_endpoints "$iprange" > "$backup/endpoints.plan"
    STEP='写入 L2TP、账号及认证配置' 
    CONFIG_STARTED=1
    mkdir -p /etc/tmpfiles.d
    printf 'c /dev/ppp 0600 root root - 108:0\n' > /etc/tmpfiles.d/l2tp-ppp.conf
    cat > /etc/xl2tpd/xl2tpd.conf <<EOF
[global]
port = ${port}

[lns default]
ip range = ${iprange}.2-${iprange}.254
local ip = ${iprange}.1
require chap = yes
refuse pap = yes
require authentication = yes
name = l2tpd
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
EOF
    cat > /etc/ppp/options.xl2tpd <<'EOF'
ipcp-accept-local
ipcp-accept-remote
require-mschap-v2
ms-dns 8.8.8.8
ms-dns 8.8.4.4
noccp
auth
hide-password
mtu 1410
mru 1410
nodefaultroute
lcp-echo-interval 30
lcp-echo-failure 4
connect-delay 5000
ipparam l2tp-pure
EOF
    # Preserve unrelated PPP accounts; replace accounts owned by this installer.
    local tmp
    tmp=$(mktemp /etc/ppp/chap-secrets.XXXXXX)
    if [[ -f /etc/ppp/chap-secrets ]]; then awk '$2!="l2tpd" && $2!="l2tpd-disabled"' /etc/ppp/chap-secrets > "$tmp"; fi
    for ((i=1;i<=count;i++)); do
        account=$username; ((count == 1)) || account=${username}${i}
        write_account "$account" "$password" >> "$tmp"
    done
    chmod 600 "$tmp"; mv "$tmp" /etc/ppp/chap-secrets
    printf 'PORT=%s\nSUBNET=%s.0/24\nMAX_CONNECTIONS=%s\n' "$port" "$iprange" "$max_connections" > /etc/l2tp-pure.conf
    install_hooks
    install_egress_logger
    configure_endpoints "$backup/endpoints.plan" "$port"
    install_firewall
    STEP='验证生成的 PPP 配置'
    pppd file /etc/ppp/options.xl2tpd name l2tpd notty dryrun >/dev/null 2>&1 || fail 'PPP 配置解析失败。执行 pppd file /etc/ppp/options.xl2tpd name l2tpd notty dryrun 查看原因；可能是全局 options 冲突。'
    STEP='启用转发与启动服务' 
    printf 'net.ipv4.ip_forward=1\n' > /etc/sysctl.d/90-l2tp-pure.conf
    sysctl -p /etc/sysctl.d/90-l2tp-pure.conf
    start_endpoints "$port"
    CONFIG_STARTED=0
    echo "Complete: UDP port=$port; accounts=$count; connections per account=$max_connections"
    if ((count == 1)); then echo "Username: $username"; else echo "Usernames: ${username}1 ... ${username}${count}"; fi
    echo "Password: supplied password. Backups: $backup"
    echo 'Each ingress IP has its own 253-address pool. Allow the chosen UDP port in any cloud firewall.'
    echo '客户端关闭 IPsec；不支持指定目标端口的 RouterOS 需要正确配置端口转换。'
    echo '这里只验证了安装、PPP 设备与 UDP 监听，尚未验证真实拨号。用一个账号实测拨号、上网及第三条连接限制。'
    echo '已启用拨入 IP = SNAT 出口 IP；每个入口使用独立地址池，同账号多连接分别绑定。'
    echo '日志：bash 本脚本 log；诊断：bash 本脚本 check。实际公网出口请通过客户端拨号后验证。' 
}
install_hooks() {
    cat > /usr/local/libexec/l2tp-limit <<'HOOK'
#!/bin/bash
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
[[ ${PPPD_PID:-} =~ ^[0-9]+$ ]] || exit 1
# ppp 2.4.x auth hooks do not receive ipparam; scope by xl2tpd options file.
tr '\0' '\n' < /proc/$PPPD_PID/cmdline | grep -Eq '^/etc/ppp/(options[.]xl2tpd|l2tp-endpoints/[0-9.]+[.]options)$' || exit 0
[[ ${PPPD_PID:-} =~ ^[0-9]+$ && ${PEERNAME:-} =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.@-]{0,63}$ ]] || exit 1
# Failures in the hook must not silently bypass the connection limit.
reject_on_error() {
    trap - ERR
    logger -t l2tp-limit 'Connection accounting failed; rejecting new session' || true
    if [[ ${1:-} == up ]]; then kill -TERM "$PPPD_PID" 2>/dev/null || true; fi
    exit 1
}
trap 'reject_on_error "$1"' ERR
[[ -r /etc/l2tp-pure.conf ]] || reject_on_error "$1"
source /etc/l2tp-pure.conf || reject_on_error "$1"
[[ ${MAX_CONNECTIONS:-} =~ ^[0-9]+$ ]] && ((MAX_CONNECTIONS >= 1 && MAX_CONNECTIONS <= 253)) || reject_on_error "$1"
mkdir -p /run/l2tp-pure
chmod 700 /run/l2tp-pure
exec 9>/run/l2tp-pure/lock
flock -x 9
record=/run/l2tp-pure/$PPPD_PID
if [[ $1 == down ]]; then rm -f "$record"; exit 0; fi
# PID plus process start time prevents stale records after PID reuse.
start=$(awk '{print $22}' /proc/$PPPD_PID/stat)
count=0
for f in /run/l2tp-pure/[0-9]*; do
    [[ -f $f ]] || continue
    read -r peer saved_start < "$f"
    pid=${f##*/}
    current=$(awk '{print $22}' /proc/$pid/stat 2>/dev/null) || current=''
    if [[ -z $current || $current != "$saved_start" ]]; then rm -f "$f"; continue; fi
    if [[ $peer == "$PEERNAME" && $pid != "$PPPD_PID" ]]; then count=$((count+1)); fi
 done
if ((count >= MAX_CONNECTIONS)); then
    logger -t l2tp-limit "event=reject user=$PEERNAME reason=connection_limit limit=$MAX_CONNECTIONS pid=$PPPD_PID"
    kill -TERM "$PPPD_PID"
    exit 0
fi
printf '%s %s\n' "$PEERNAME" "$start" > "$record"
HOOK
    chmod 700 /usr/local/libexec/l2tp-limit
    local hook mode
    for mode in up down; do
        hook=/etc/ppp/auth-$mode
        if [[ ! -s $hook ]]; then printf '#!/bin/sh\n' > "$hook"; fi
        # Insert before existing code/exit, preserving any previous auth hook.
        if ! grep -q '/usr/local/libexec/l2tp-limit' "$hook"; then
            sed -i "1a /usr/local/libexec/l2tp-limit $mode" "$hook"
        fi
        chmod 700 "$hook"
    done
}
install_firewall() {
    cat > /usr/local/libexec/l2tp-firewall <<'FW'
#!/bin/bash
set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
source /etc/l2tp-pure.conf
# Dedicated chains avoid replacing unrelated firewall rules.
iptables -w -N L2TP_PURE_IN 2>/dev/null || true
iptables -w -F L2TP_PURE_IN
iptables -w -A L2TP_PURE_IN -p udp --dport "$PORT" -j ACCEPT
iptables -w -C INPUT -j L2TP_PURE_IN 2>/dev/null || iptables -w -I INPUT 1 -j L2TP_PURE_IN
mkdir -p /run/l2tp-pure
exec 9>/run/l2tp-pure/egress.lock
flock -x 9
iptables -w -N L2TP_PURE_SESSION 2>/dev/null || true
iptables -w -t nat -N L2TP_PURE_SNAT 2>/dev/null || true
iptables -w -N L2TP_PURE_FWD 2>/dev/null || true
iptables -w -F L2TP_PURE_FWD
while read -r ingress subnet local_ip pool; do
    iptables -w -A L2TP_PURE_FWD -i ppp+ -s "$subnet" -j L2TP_PURE_SESSION
    iptables -w -A L2TP_PURE_FWD -i ppp+ -s "$subnet" -j DROP
    iptables -w -A L2TP_PURE_FWD -o ppp+ -d "$subnet" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
done < /etc/l2tp-endpoints.tsv
iptables -w -C FORWARD -j L2TP_PURE_FWD 2>/dev/null || iptables -w -I FORWARD 1 -j L2TP_PURE_FWD
iptables -w -t nat -N L2TP_PURE_NAT 2>/dev/null || true
iptables -w -t nat -F L2TP_PURE_NAT
iptables -w -t nat -A L2TP_PURE_NAT -j L2TP_PURE_SNAT
# Keep managed SNAT ahead of any pre-existing broad MASQUERADE rule.
while iptables -w -t nat -C POSTROUTING -j L2TP_PURE_NAT 2>/dev/null; do
    iptables -w -t nat -D POSTROUTING -j L2TP_PURE_NAT
done
iptables -w -t nat -I POSTROUTING 1 -j L2TP_PURE_NAT

FW
    chmod 700 /usr/local/libexec/l2tp-firewall
    cat > /etc/systemd/system/l2tp-firewall.service <<'UNIT'
[Unit]
Description=Pure L2TP firewall rules
After=network-online.target firewalld.service ufw.service netfilter-persistent.service
Wants=network-online.target
Before=xl2tpd.service

[Service]
Type=oneshot
ExecStart=/usr/local/libexec/l2tp-firewall
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
}
plan_endpoints() {
    STEP='检查入口公网 IP 与独立地址池'
    python3 - "$1" <<'PYPLAN'
import ipaddress, json, subprocess, sys
def read_ip(*args):
    return json.loads(subprocess.check_output(['ip', '-j', '-4', *args], text=True))
try:
    base = ipaddress.IPv4Network(sys.argv[1] + '.0/24')
    if not base.is_private or not any(base.subnet_of(ipaddress.ip_network(n)) for n in
                                    ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16']):
        raise ValueError('地址池必须位于 RFC1918 私网')
    addresses = read_ip('addr', 'show')
    endpoints, occupied = {}, []
    for interface in addresses:
        name = interface['ifname']
        for a in interface.get('addr_info', []):
            ip = ipaddress.IPv4Address(a['local'])
            if ip.is_global and a.get('scope') == 'global':
                endpoints[str(ip)] = name
            if name != 'lo' and not name.startswith('ppp'):
                occupied.append(ipaddress.IPv4Network(f"{ip}/{a['prefixlen']}", strict=False))
    if not endpoints:
        raise ValueError('未找到直接配置在本机的公网 IPv4；上游 NAT 的公网 IP 不能自动作为监听地址')
    if len(endpoints) > 256:
        raise ValueError('本模式最多支持 256 个入口 IP')
    defaults = read_ip('route', 'show', 'default')
    if len(defaults) != 1 or not defaults[0].get('dev') or set(endpoints.values()) != {defaults[0]['dev']}:
        raise ValueError('仅支持同一默认出口网卡上的公网 IP；多出口/策略路由需要单独整合')
    for route in read_ip('route', 'show', 'table', 'main'):
        if route.get('dst', 'default') == 'default' or route.get('dev', '').startswith('ppp'):
            continue
        occupied.append(ipaddress.IPv4Network(route['dst'], strict=False))
    octets = str(base.network_address).split('.')
    planned = []
    for i, ip in enumerate(sorted(endpoints, key=ipaddress.IPv4Address)):
        prefix = '.'.join(octets[:2] + [str((int(octets[2]) + i) % 256)])
        subnet = ipaddress.IPv4Network(prefix + '.0/24')
        if not subnet.is_private or not any(subnet.subnet_of(ipaddress.ip_network(n)) for n in
                                          ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16']):
            raise ValueError('生成的地址池越出 RFC1918 私网')
        if any(subnet.overlaps(existing) for existing in occupied):
            raise ValueError(f'地址池 {subnet} 与服务器已有地址或路由冲突，请更换 --ip-range')
        planned.append(f'{ip}\t{subnet}\t{prefix}.1\t{prefix}.2-{prefix}.254')
    print('\n'.join(planned))
except (ValueError, KeyError, subprocess.CalledProcessError) as e:
    print(f'[停止] 入口/出口规划失败：{e}', file=sys.stderr)
    sys.exit(1)
PYPLAN
}
configure_endpoints() {
    local plan=$1 port=$2 ingress subnet local_ip pool
    [[ -s $plan ]] || fail '入口 IP 规划为空，未配置服务。'
    mkdir -p /etc/xl2tpd/endpoints /etc/ppp/l2tp-endpoints
    cp -- "$plan" /etc/l2tp-endpoints.tsv
    chmod 600 /etc/l2tp-endpoints.tsv
    while read -r ingress subnet local_ip pool; do
        # pass peer=no prevents xl2tpd from replacing our trusted ipparam.
        cat > "/etc/xl2tpd/endpoints/$ingress.conf" <<EOF
[global]
listen-addr = $ingress
port = $port
force userspace = yes

[lns default]
ip range = $pool
local ip = $local_ip
require chap = yes
refuse pap = yes
require authentication = yes
name = l2tpd
pass peer = no
pppoptfile = /etc/ppp/l2tp-endpoints/$ingress.options
length bit = yes
EOF
        # Reuse the validated common PPP options, with an explicit ingress identity.
        sed -e '/^[[:space:]]*ipparam[[:space:]]/d' -e '/^[[:space:]]*ipcp-accept-remote[[:space:]]*$/d' -e '/^[[:space:]]*ipcp-accept-local[[:space:]]*$/d' /etc/ppp/options.xl2tpd > "/etc/ppp/l2tp-endpoints/$ingress.options"
        printf 'ipparam l2tp-egress:%s\n' "$ingress" >> "/etc/ppp/l2tp-endpoints/$ingress.options"
    done < /etc/l2tp-endpoints.tsv
    cat > /etc/systemd/system/l2tp-endpoint@.service <<'UNIT'
[Unit]
Description=L2TP ingress and egress %i
Wants=network-online.target
Requires=l2tp-firewall.service
After=network-online.target l2tp-firewall.service
PartOf=l2tp-endpoints.target

[Service]
Type=simple
RuntimeDirectory=l2tp-endpoint-%i
RuntimeDirectoryMode=0700
ExecStart=/usr/sbin/xl2tpd -D -l -c /etc/xl2tpd/endpoints/%i.conf -p /run/l2tp-endpoint-%i/pid -C /run/l2tp-endpoint-%i/control
Restart=on-failure
RestartSec=3
KillMode=control-group

UNIT
    {
        printf '[Unit]\nDescription=L2TP ingress IP matching egress IP\n'
        while read -r ingress subnet local_ip pool; do
            printf 'Wants=l2tp-endpoint@%s.service\nAfter=l2tp-endpoint@%s.service\n' "$ingress" "$ingress"
        done < /etc/l2tp-endpoints.tsv
        printf '\n[Install]\nWantedBy=multi-user.target\n'
    } > /etc/systemd/system/l2tp-endpoints.target
    if ! grep -q '^ENDPOINT_MODE=' /etc/l2tp-pure.conf; then
        printf 'ENDPOINT_MODE=1\n' >> /etc/l2tp-pure.conf
    else sed -i 's/^ENDPOINT_MODE=.*/ENDPOINT_MODE=1/' /etc/l2tp-pure.conf; fi
}
install_egress_logger() {
    cat > /usr/local/libexec/l2tp-egress <<'EGRESS'
#!/bin/bash
set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
event=${1:-}; shift || exit 1
# pppd supplies interface, tty, speed, local IP, remote IP, ipparam.
python3 - "$event" "$@" <<'PYSESSION'
import fcntl, ipaddress, json, os, pathlib, re, shlex, signal, subprocess, sys, syslog, tempfile
ROOT = pathlib.Path('/run/l2tp-pure')
PROC = pathlib.Path('/proc')
MAP = pathlib.Path('/etc/l2tp-endpoints.tsv')
SECRETS = pathlib.Path('/etc/ppp/chap-secrets')

def log(message):
    syslog.openlog('l2tp-egress'); syslog.syslog(syslog.LOG_INFO, message)

def process_start(pid):
    return (PROC / str(pid) / 'stat').read_text().rsplit(')', 1)[1].split()[19]

def managed_process(pid):
    try:
        argv = (PROC / str(pid) / 'cmdline').read_bytes().split(b'\0')
        return any(re.fullmatch(rb'/etc/ppp/l2tp-endpoints/[0-9.]+\.options', a) for a in argv)
    except OSError: return False

def rule(record, forward=False):
    common = ['-s', record['remote'] + '/32', '-m', 'comment', '--comment', record['comment']]
    return (['-i', record['interface']] + common + ['-j', 'ACCEPT'] if forward else
            common + ['-j', 'SNAT', '--to-source', record['egress']])

def ipt(action, record, forward=False):
    table, chain = ('filter', 'L2TP_PURE_SESSION') if forward else ('nat', 'L2TP_PURE_SNAT')
    return subprocess.run(['iptables', '-w', '-t', table, action, chain, *rule(record, forward)],
                          stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)

def cleanup(record):
    for forward in [True, False]:
        if ipt('-C', record, forward).returncode == 0:
            result = ipt('-D', record, forward)
            if result.returncode: raise RuntimeError('无法移除旧会话防火墙规则')
    result = subprocess.run(['conntrack', '-D', '-f', 'ipv4', '-s', record['remote']],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if result.returncode not in (0, 1): raise RuntimeError('无法清理旧会话连接跟踪')

def resolve(user, ingress):
    for line in SECRETS.read_text().splitlines():
        fields = shlex.split(line, comments=True)
        if len(fields) >= 4 and fields[0] == user and fields[1] == 'l2tpd':
            match = re.search(r'\s+# l2tp-egress=([0-9.]+)\s*$', line)
            return str(ipaddress.IPv4Address(match.group(1))) if match else ingress
    raise ValueError('账号不存在或已禁用')

def main(argv):
    if len(argv) != 7: raise ValueError('PPP 钩子参数不完整')
    event, interface, tty, speed, local, remote, param = argv
    if not param.startswith('l2tp-egress:'): return
    if event not in ('pre-up', 'up', 'down') or not re.fullmatch(r'ppp[0-9]+', interface):
        raise ValueError('无效 PPP 事件或接口')
    ingress = str(ipaddress.IPv4Address(param.split(':', 1)[1]))
    remote = str(ipaddress.IPv4Address(remote))
    pid = int(os.environ['PPPD_PID'])
    if pid <= 1: raise ValueError('无效 PPP PID')
    ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
    directory = ROOT / 'egress'; directory.mkdir(mode=0o700, exist_ok=True)
    state = directory / (interface + '.json')
    with open(ROOT / 'egress.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        record = json.loads(state.read_text()) if state.exists() else None
        if event in ('up', 'down'):
            if not record or record['pid'] != pid:
                if event == 'up': raise ValueError('会话未在 pre-up 阶段配置出口')
                return
            if event == 'down': cleanup(record); state.unlink()
            log(f"event={event} user={record['user']} interface={interface} tunnel_ip={remote} ingress_ip={record['ingress']} egress_ip={record['egress']} pid={pid}")
            return
        if not managed_process(pid): raise ValueError('PPP 进程不属于本脚本')
        start = process_start(pid)
        user = os.environ.get('PEERNAME', '')
        if not re.fullmatch(r'[a-zA-Z0-9_][a-zA-Z0-9_.@-]{0,63}', user): raise ValueError('无效账号')
        mapping = {r[0]: r for line in MAP.read_text().splitlines() if (r := line.split())}
        if ingress not in mapping or local != mapping[ingress][2] or ipaddress.IPv4Address(remote) not in ipaddress.IPv4Network(mapping[ingress][1]):
            raise ValueError('隧道地址不属于入口地址池')
        egress = resolve(user, ingress)
        if egress not in mapping: raise ValueError('固定出口 IP 已不在当前入口映射中')
        addresses = json.loads(subprocess.check_output(['ip', '-j', '-4', 'addr', 'show'], text=True))
        if egress not in {a['local'] for d in addresses for a in d.get('addr_info', [])}:
            raise ValueError('固定出口 IP 不在本机网卡上')
        # Interface reuse or interrupted hooks must not retain an old source mapping.
        if record:
            if record['pid'] != pid:
                try: active = process_start(record['pid']) == record['start']
                except OSError: active = False
                if active: raise ValueError('接口仍属于另一个有效会话')
            cleanup(record); state.unlink()
        record = dict(pid=pid, start=start, user=user, interface=interface, remote=remote,
                      ingress=ingress, egress=egress, comment=f'l2tp:{pid}:{start}')
        # Install SNAT first, then admit forwarding. A failure leaves forwarding denied.
        cleanup(record)
        result = ipt('-A', record)
        if result.returncode: raise RuntimeError('会话 SNAT 安装失败')
        try:
            fd, name = tempfile.mkstemp(prefix='.session-', dir=directory)
            with os.fdopen(fd, 'w') as out: json.dump(record, out)
            os.replace(name, state)
            if ipt('-A', record, True).returncode: raise RuntimeError('会话转发放行失败')
        except BaseException:
            cleanup(record)
            if state.exists(): state.unlink()
            raise
        log(f'event=egress_ready user={user} interface={interface} tunnel_ip={remote} ingress_ip={ingress} egress_ip={egress} pid={pid}')

if __name__ == '__main__':
    try: main(sys.argv[1:])
    except Exception as error:
        log(f'event=error reason={str(error)} user={os.environ.get("PEERNAME", "unknown")}')
        if sys.argv[1:2] in (['pre-up'], ['up']):
            try:
                pid = int(os.environ.get('PPPD_PID', '0'))
                if pid > 1 and managed_process(pid): os.kill(pid, signal.SIGTERM)
            except (OSError, ValueError): pass
        sys.exit(1)
PYSESSION
EGRESS
    chmod 700 /usr/local/libexec/l2tp-egress
    local mode hook first_line
    for mode in pre-up up down; do
        hook=/etc/ppp/ip-$mode
        if [[ -s $hook ]]; then
            IFS= read -r first_line < "$hook" || true
            case $first_line in
                '#!/bin/sh'|'#!/bin/bash'|'#!/bin/dash'|'#!/usr/bin/bash'|'#!/usr/bin/env bash') ;;
                *) fail "已有钩子 $hook 不是可识别 shell 脚本，未覆盖。";;
            esac
        else printf '#!/bin/sh\n' > "$hook"; fi
        if ! grep -q '/usr/local/libexec/l2tp-egress' "$hook"; then
            sed -i "1a /usr/local/libexec/l2tp-egress $mode \"\$@\"" "$hook"
        fi
        chmod 700 "$hook"
    done
}
start_endpoints() {
    local port=$1 ingress subnet local_ip pool attempt missing sockets
    STEP='启动入口 IP 对应的独立监听与出口'
    systemctl daemon-reload
    # The old wildcard listener must release the UDP port before per-IP listeners start.
    systemctl disable --now xl2tpd.service
    systemctl stop l2tp-endpoints.target || true
    systemctl enable l2tp-firewall.service l2tp-endpoints.target
    systemctl restart l2tp-firewall.service
    systemctl start l2tp-endpoints.target
    for attempt in 1 2 3 4 5; do
        missing=0
        sockets=$(ss -H -ulnp)
        while read -r ingress subnet local_ip pool; do
            if ! systemctl is-active --quiet "l2tp-endpoint@$ingress.service" ||
               ! awk -v addr="$ingress:$port" '$4==addr && /xl2tpd/ {ok=1} END {exit !ok}' <<< "$sockets"; then
                missing=$((missing+1))
            fi
        done < /etc/l2tp-endpoints.tsv
        ((missing == 0)) && break
        sleep 1
    done
    ((missing == 0)) || fail "有 $missing 个入口未正常监听。运行本脚本 log --no-follow 查看错误。"
    logger -t l2tp-egress -- 'event=configuration_ready mode=ingress_ip_equals_egress_ip'
}
show_logs() {
    require_linux
    local lines=100 follow=1
    while (($#)); do
        case $1 in
            --no-follow) follow=0; shift;;
            --lines) (($# >= 2)) || fail '--lines 缺少数量'; lines=$2; shift 2;;
            *) fail "未知日志参数：$1";;
        esac
    done
    [[ $lines =~ ^[0-9]{1,5}$ ]] || fail '日志数量必须为 0–99999。'
    echo '事件：up=上线，down=下线，reject=并发超限；ingress_ip=拨入地址，egress_ip=配置的 SNAT 出口。'
    local args=(--no-pager -n "$lines" -o short-iso -t l2tp-egress -t l2tp-limit -t l2tp-admin -t xl2tpd -t pppd)
    ((follow == 0)) || args+=(-f)
    journalctl "${args[@]}"
}
migrate_egress() {
    require_linux
    [[ -s /etc/l2tp-pure.conf && -s /etc/ppp/options.xl2tpd ]] || fail '请先运行 install。'
    source /etc/l2tp-pure.conf
    command -v python3 >/dev/null || fail '请先安装 python3：apt-get install -y python3'
    make_backup
    if ! command -v conntrack >/dev/null; then install_packages; fi
    local f first_line
    for f in /etc/l2tp-pure.conf /etc/l2tp-endpoints.tsv /etc/xl2tpd /etc/ppp/options.xl2tpd /etc/ppp/l2tp-endpoints /etc/ppp/auth-up /etc/ppp/auth-down /etc/ppp/ip-pre-up /etc/ppp/ip-up /etc/ppp/ip-down /usr/local/libexec/l2tp-limit /usr/local/libexec/l2tp-egress /usr/local/libexec/l2tp-firewall /etc/systemd/system/l2tp-endpoint@.service /etc/systemd/system/l2tp-endpoints.target /etc/systemd/system/l2tp-firewall.service; do
        if [[ -e $f || -L $f ]]; then
            mkdir -p -- "$BACKUP$(dirname -- "$f")"
            cp -a -- "$f" "$BACKUP$f"
        fi
    done
    plan_endpoints "${SUBNET%.0/24}" > "$BACKUP/endpoints.plan"
    for f in /etc/ppp/auth-up /etc/ppp/auth-down /etc/ppp/ip-pre-up /etc/ppp/ip-up /etc/ppp/ip-down; do
        [[ -s $f ]] || continue
        IFS= read -r first_line < "$f" || true
        case $first_line in
            '#!/bin/sh'|'#!/bin/bash'|'#!/bin/dash'|'#!/usr/bin/bash'|'#!/usr/bin/env bash') ;;
            *) fail "已有钩子 $f 无法安全整合。";;
        esac
    done
    check_firewall_support
    check_port "$PORT"
    CONFIG_STARTED=1
    install_hooks
    install_egress_logger
    configure_endpoints "$BACKUP/endpoints.plan" "$PORT"
    install_firewall
    start_endpoints "$PORT"
    CONFIG_STARTED=0
    echo '已启用拨入 IP = SNAT 出口 IP；账号和密码保留，已有拨号需重连。'
    echo '查看日志：bash 本脚本 log；客户端通过隧道查询实际公网出口进行验证。'
}
accounts() {
    command -v python3 >/dev/null || fail '账号管理需要 python3：apt-get install -y python3'
    python3 - "$@" <<'PYACCOUNTS'
import argparse, datetime, fcntl, getpass, ipaddress, os, pathlib, re, shlex, signal, sys, syslog, tempfile

SECRETS = pathlib.Path('/etc/ppp/chap-secrets')
BACKUPS = pathlib.Path('/etc/l2tp-backup')
STATE = pathlib.Path('/run/l2tp-pure')
PROC = pathlib.Path('/proc')
ENDPOINTS = pathlib.Path('/etc/l2tp-endpoints.tsv')
OWNED = {'l2tpd', 'l2tpd-disabled'}
USER = re.compile(r'[a-zA-Z0-9_][a-zA-Z0-9_.@-]{0,63}\Z')

def log(message):
    syslog.openlog('l2tp-admin')
    syslog.syslog(syslog.LOG_INFO, message)

def quote(value):
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'

def valid_password(value):
    if not value or any(c in value for c in '\r\n\t\0'):
        raise ValueError('密码不能为空，也不能包含换行、制表符或 NUL')
    return value

def prompt(label, secret=False):
    try:
        with open('/dev/tty', 'r+') as tty:
            if secret:
                return getpass.getpass(label, stream=tty)
            tty.write(label); tty.flush()
            answer = tty.readline()
            if not answer: raise ValueError('输入中断')
            return answer.rstrip('\r\n')
    except OSError:
        raise ValueError('非交互运行需要提供参数；密码可使用 --password-file')

def password(args):
    if args.password_file:
        value = pathlib.Path(args.password_file).read_text(encoding='utf-8').removesuffix('\n').removesuffix('\r')
    else:
        value = args.password if args.password is not None else prompt('密码（不回显）: ', True)
    return valid_password(value)

def read_accounts(text):
    result = {}
    for index, line in enumerate(text.splitlines(keepends=True)):
        try: fields = shlex.split(line, comments=True, posix=True)
        except ValueError as e: raise ValueError(f'账号文件第 {index + 1} 行无法安全解析：{e}')
        if len(fields) >= 2 and fields[1] in OWNED:
            if len(fields) < 4 or not USER.fullmatch(fields[0]):
                raise ValueError(f'账号文件第 {index + 1} 行格式不受支持，未修改')
            if fields[0] in result: raise ValueError(f'重复账号：{fields[0]}，请先检查原配置')
            result[fields[0]] = (index, fields)
    return result

def commit(original, content):
    if content == original: return None
    BACKUPS.mkdir(parents=True, exist_ok=True, mode=0o700)
    directory = pathlib.Path(tempfile.mkdtemp(prefix=datetime.datetime.now().strftime('%Y%m%d-%H%M%S-accounts-'), dir=BACKUPS))
    backup = directory / 'chap-secrets'
    with open(backup, 'x', encoding='utf-8', newline='\n') as out:
        os.chmod(backup, 0o600); out.write(original)
    fd, name = tempfile.mkstemp(prefix='.chap-secrets.', dir=SECRETS.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8', newline='\n') as out:
            os.fchmod(out.fileno(), 0o600)
            out.write(content); out.flush(); os.fsync(out.fileno())
        os.replace(name, SECRETS)
    finally:
        if os.path.exists(name): os.unlink(name)
    return str(directory)

def disconnect(names):
    count = 0
    for record in STATE.glob('[0-9]*'):
        if not record.is_file() or not record.name.isdecimal(): continue
        try:
            user, saved = record.read_text().split()
            if user not in names: continue
            process = PROC / record.name
            # stat comm may contain spaces; fields after the last ')' begin at field 3.
            current = process.joinpath('stat').read_text().rsplit(')', 1)[1].split()[19]
            argv = process.joinpath('cmdline').read_bytes().split(b'\0')
            owned = any(v == b'/etc/ppp/options.xl2tpd' or
                        re.fullmatch(rb'/etc/ppp/l2tp-endpoints/[0-9.]+\.options', v) for v in argv)
            if current != saved or not owned: continue
            os.kill(int(record.name), signal.SIGTERM)
            count += 1
            log(f'event=disconnect_requested user={user} pid={record.name}')
        except (OSError, ValueError, IndexError): continue
    return count

def main(argv):
    parser = argparse.ArgumentParser(description='L2TP 账号管理（仅操作本脚本的账号）')
    parser.add_argument('action', choices=['list', 'add', 'mod', 'del', 'enable', 'disable', 'batch-add',
        'batch-mod', 'batch-del', 'batch-enable', 'batch-disable', 'bind', 'batch-bind', 'import', 'export', 'kick', 'delete-all'])
    parser.add_argument('--username'); parser.add_argument('--new-name'); parser.add_argument('--prefix')
    parser.add_argument('--start', type=int, default=1); parser.add_argument('--count', type=int)
    group = parser.add_mutually_exclusive_group()
    group.add_argument('--password'); group.add_argument('--password-file')
    parser.add_argument('--file'); parser.add_argument('--with-passwords', action='store_true')
    parser.add_argument('--disconnect', action='store_true')
    binding = parser.add_mutually_exclusive_group()
    binding.add_argument('--ip'); binding.add_argument('--ip-start'); binding.add_argument('--ip-file')
    binding.add_argument('--clear-ip', action='store_true')
    args = parser.parse_args(argv)
    if not SECRETS.is_file(): raise ValueError('未找到账号配置，请先安装 L2TP')
    if SECRETS.is_symlink(): raise ValueError('账号文件是符号链接，请先手工确认实际配置路径')
    with open(SECRETS.parent / '.l2tp-accounts.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        original = SECRETS.read_text(encoding='utf-8')
        records = read_accounts(original)
        raw_lines = original.splitlines(keepends=True)
        bindings = {}
        for user, (index, _) in records.items():
            found = re.search(r'\s+# l2tp-egress=([0-9.]+)\s*$', raw_lines[index])
            bindings[user] = found.group(1) if found else None
        def check_ip(value):
            try: address = str(ipaddress.IPv4Address(value))
            except ipaddress.AddressValueError: raise ValueError(f'无效出口 IPv4：{value}')
            if not ENDPOINTS.is_file(): raise ValueError('请先执行 egress 启用入口/出口服务')
            known = {line.split()[0] for line in ENDPOINTS.read_text().splitlines() if line.strip()}
            if address not in known: raise ValueError(f'出口 IP 未在本机入口映射中：{address}')
            return address
        def tag(ip): return ' # l2tp-egress=' + ip if ip else ''
        if args.action == 'list':
            print('账号\t状态\t固定出口 IP')
            for user, (_, fields) in sorted(records.items()):
                print(user + '\t' + ('启用' if fields[1] == 'l2tpd' else '禁用') + '\t' + (bindings[user] or '跟随拨入 IP'))
            print(f'共 {len(records)} 个账号')
            return
        if args.action == 'export':
            if not args.file: raise ValueError('导出需要 --file PATH；不会覆盖已有文件')
            # Exclusive creation prevents accidentally overwriting a user file.
            fd = os.open(args.file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, 'w', encoding='utf-8', newline='\n') as out:
                out.write('# l2tp-accounts-v1 ' + ('secrets' if args.with_passwords else 'public') + '\n')
                for user, (_, fields) in sorted(records.items()):
                    status = 'enabled' if fields[1] == 'l2tpd' else 'disabled'
                    if args.with_passwords:
                        valid_password(fields[2])
                        out.write(f'{user}\t{fields[2]}\t{status}\t{bindings[user] or ""}\n')
                    else: out.write(f'{user}\t{status}\t{bindings[user] or ""}\n')
            print(f'已导出 {len(records)} 个账号' + ('（包含密码，请妥善保管）' if args.with_passwords else '（不含密码）'))
            return
        replacements, additions, targets = {}, [], []
        action = args.action.removeprefix('batch-')
        if action == 'import':
            if not args.file: raise ValueError('导入需要 --file PATH')
            imported = {}
            for number, row in enumerate(pathlib.Path(args.file).read_text(encoding='utf-8-sig').splitlines(), 1):
                if row == '# l2tp-accounts-v1 public': raise ValueError('这是不含密码的导出文件，不能用于导入')
                if not row or row.startswith('#'): continue
                fields = row.split('\t')
                if len(fields) not in (2, 3, 4): raise ValueError(f'导入第 {number} 行必须为：账号 TAB 密码 [TAB enabled/disabled]')
                user, secret = fields[:2]
                status = fields[2] if len(fields) >= 3 else 'enabled'
                bound = check_ip(fields[3]) if len(fields) == 4 and fields[3] else None
                if not USER.fullmatch(user) or status not in ('enabled', 'disabled'):
                    raise ValueError(f'导入第 {number} 行账号或状态无效')
                valid_password(secret)
                if user in records or user in imported: raise ValueError(f'账号已存在或导入重复：{user}；整批未写入')
                imported[user] = (secret, status, bound)
            if not imported: raise ValueError('导入文件没有账号')
            for user, (secret, status, bound) in imported.items():
                server = 'l2tpd' if status == 'enabled' else 'l2tpd-disabled'
                additions.append(f'{quote(user)} {server} {quote(secret)} *{tag(bound)}\n')
            targets = list(imported)
        else:
            if args.action.startswith('batch-'):
                prefix = args.prefix if args.prefix is not None else prompt('账号前缀: ')
                count = args.count if args.count is not None else int(prompt('数量: '))
                if not 1 <= count <= 10000 or not 0 <= args.start <= 1000000:
                    raise ValueError('批量数量须为 1–10000，起始序号须为 0–1000000')
                targets = [prefix + str(i) for i in range(args.start, args.start + count)]
            elif action == 'delete-all': targets = list(records)
            else: targets = [args.username or prompt('账号: ')]
            if not all(USER.fullmatch(u) for u in targets): raise ValueError('账号格式无效或超过 64 字符')
            for user in targets:
                if action == 'add' and user in records: raise ValueError(f'账号已存在：{user}；整批未写入')
                if action != 'add' and user not in records: raise ValueError(f'账号不存在：{user}；整批未写入')
            changed_bindings = {}
            if args.ip or args.ip_start or args.ip_file or args.clear_ip:
                if action not in ('add', 'mod', 'bind'): raise ValueError('IP 参数只用于增加、修改或绑定账号')
                if args.clear_ip: selected = [None] * len(targets)
                elif args.ip: selected = [check_ip(args.ip)] * len(targets)
                elif args.ip_start:
                    first = int(ipaddress.IPv4Address(args.ip_start))
                    selected = [check_ip(str(ipaddress.IPv4Address(first + i))) for i in range(len(targets))]
                else:
                    selected = [check_ip(row.strip()) for row in pathlib.Path(args.ip_file).read_text().splitlines() if row.strip()]
                    if len(selected) != len(targets): raise ValueError('IP 文件行数必须与账号数量一致')
                changed_bindings = dict(zip(targets, selected))
            elif action == 'bind': raise ValueError('绑定需要 --ip、--ip-start、--ip-file 或 --clear-ip')
            if args.new_name and (action != 'mod' or len(targets) != 1 or args.action.startswith('batch-')):
                raise ValueError('--new-name 只支持单账号 mod')
            if args.new_name and (not USER.fullmatch(args.new_name) or (args.new_name in records and args.new_name != targets[0])):
                raise ValueError('新账号名无效或已存在')
            if action == 'kick':
                print(f'已请求断开 {disconnect(set(targets))} 条本脚本跟踪的有效连接')
                return
            secret = None
            if action == 'add' or (action == 'mod' and (not args.new_name or args.password is not None or args.password_file)):
                secret = password(args)
            for user in targets:
                if action == 'add': additions.append(f'{quote(user)} l2tpd {quote(secret)} *{tag(changed_bindings.get(user))}\n'); continue
                index, fields = records[user]
                if action in ('del', 'delete-all'): replacements[index] = ''; continue
                fields = list(fields)
                if action == 'mod':
                    if secret is not None: fields[2] = secret
                    if args.new_name: fields[0] = args.new_name
                elif action in ('enable', 'disable'):
                    fields[1] = 'l2tpd' if action == 'enable' else 'l2tpd-disabled'
                replacements[index] = quote(fields[0]) + ' ' + fields[1] + ' ' + ' '.join(quote(v) for v in fields[2:]) + tag(changed_bindings.get(user, bindings[user])) + '\n'
        lines = original.splitlines(keepends=True)
        updated = ''.join(replacements.get(i, row) for i, row in enumerate(lines))
        if additions:
            if updated and not updated.endswith('\n'): updated += '\n'
            updated += ''.join(additions)
        backup = commit(original, updated)
        log(f'event=accounts_updated action={args.action} count={len(targets)} users={",".join(targets[:20])}')
        print(f'已处理 {len(targets)} 个账号；操作：{args.action}')
        if backup: print(f'备份目录：{backup}')
        if args.disconnect: print(f'已请求断开 {disconnect(set(targets))} 条连接')
        else: print('已有连接不主动断开；新配置在下次认证时生效。')

if __name__ == '__main__':
    try: main(sys.argv[1:])
    except (ValueError, OSError, UnicodeError) as error:
        print(f'[停止] {error}', file=sys.stderr); sys.exit(1)
PYACCOUNTS
}
set_connection_limit() {
    [[ $# == 1 && $1 =~ ^[0-9]{1,3}$ ]] && ((10#$1 >= 1 && 10#$1 <= 253)) || fail '用法：limit 1–253'
    [[ -f /etc/l2tp-pure.conf ]] || fail '请先安装。'
    make_backup
    cp -a /etc/l2tp-pure.conf "$BACKUP/l2tp-pure.conf"
    local tmp
    tmp=$(mktemp /etc/l2tp-pure.conf.XXXXXX)
    awk -v n="$((10#$1))" '!/^MAX_CONNECTIONS=/ {print} END {print "MAX_CONNECTIONS=" n}' /etc/l2tp-pure.conf > "$tmp"
    chmod 600 "$tmp"; mv "$tmp" /etc/l2tp-pure.conf
    logger -t l2tp-admin -- "event=limit_updated limit=$((10#$1))"
    echo "单账号并发上限已改为 $((10#$1))，下次认证生效；不主动断开现有连接。"
}
uninstall_l2tp() {
    require_linux
    local yes=0 keep=0 answer='' f directory ingress subnet local_ip pool
    while (($#)); do
        case $1 in --yes) yes=1;; --keep-accounts) keep=1;; *) fail "未知卸载参数：$1";; esac
        shift
    done
    [[ -f /etc/l2tp-pure.conf ]] || fail '未找到本脚本的安装标记，未修改服务。'
    if ((yes == 0)); then
        [[ -t 0 ]] || fail '非交互卸载请明确使用 uninstall --yes。'
        read -r -p '卸载会断开本脚本的全部拨号。输入 UNINSTALL 继续：' answer
        [[ $answer == UNINSTALL ]] || { echo '已取消卸载。'; return; }
    fi
    make_backup
    STEP='备份并卸载本脚本服务'
    for f in /etc/l2tp-pure.conf /etc/l2tp-endpoints.tsv /etc/xl2tpd/endpoints /etc/xl2tpd/xl2tpd.conf /etc/ppp/l2tp-endpoints /etc/ppp/options.xl2tpd /etc/ppp/chap-secrets /etc/ppp/auth-up /etc/ppp/auth-down /etc/ppp/ip-pre-up /etc/ppp/ip-up /etc/ppp/ip-down /usr/local/libexec/l2tp-limit /usr/local/libexec/l2tp-egress /usr/local/libexec/l2tp-firewall /etc/systemd/system/l2tp-endpoint@.service /etc/systemd/system/l2tp-endpoints.target /etc/systemd/system/l2tp-firewall.service /etc/sysctl.d/90-l2tp-pure.conf /etc/tmpfiles.d/l2tp-ppp.conf; do
        if [[ -e $f || -L $f ]]; then
            mkdir -p -- "$BACKUP$(dirname -- "$f")"
            cp -a -- "$f" "$BACKUP$f"
        fi
    done
    iptables -w -L -n >/dev/null || fail '无法访问防火墙，未开始卸载。'
    CONFIG_STARTED=1
    if ((keep == 0)); then accounts delete-all --disconnect; fi
    for f in l2tp-endpoints.target l2tp-firewall.service xl2tpd.service; do
        if systemctl cat "$f" >/dev/null 2>&1; then systemctl disable --now "$f"; fi
    done
    if [[ -r /etc/l2tp-endpoints.tsv ]]; then
        while read -r ingress subnet local_ip pool; do
            [[ $ingress =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail '入口映射异常，已停止清理。'
            if systemctl cat "l2tp-endpoint@$ingress.service" >/dev/null 2>&1; then systemctl stop "l2tp-endpoint@$ingress.service"; fi
        done < /etc/l2tp-endpoints.tsv
    fi
    local table parent chain
    for table in filter nat; do
        if [[ $table == filter ]]; then
            for parent in INPUT FORWARD; do
                chain=L2TP_PURE_IN; [[ $parent != FORWARD ]] || chain=L2TP_PURE_FWD
                while iptables -w -t "$table" -C "$parent" -j "$chain" 2>/dev/null; do iptables -w -t "$table" -D "$parent" -j "$chain"; done
                if iptables -w -t "$table" -S "$chain" >/dev/null 2>&1; then
                    iptables -w -t "$table" -F "$chain"; iptables -w -t "$table" -X "$chain"
                fi
            done
        else
            chain=L2TP_PURE_NAT
            while iptables -w -t nat -C POSTROUTING -j "$chain" 2>/dev/null; do iptables -w -t nat -D POSTROUTING -j "$chain"; done
            if iptables -w -t nat -S "$chain" >/dev/null 2>&1; then iptables -w -t nat -F "$chain"; iptables -w -t nat -X "$chain"; fi
        fi
    done
    for table in filter nat; do
        chain=L2TP_PURE_SESSION; [[ $table != nat ]] || chain=L2TP_PURE_SNAT
        if iptables -w -t "$table" -S "$chain" >/dev/null 2>&1; then
            iptables -w -t "$table" -F "$chain"; iptables -w -t "$table" -X "$chain"
        fi
    done
    for f in /etc/ppp/auth-up /etc/ppp/auth-down /etc/ppp/ip-pre-up /etc/ppp/ip-up /etc/ppp/ip-down; do
        [[ -f $f ]] || continue
        # Remove only lines inserted by this script; retain other PPP hooks.
        sed -i -e '\|^/usr/local/libexec/l2tp-limit up$|d' -e '\|^/usr/local/libexec/l2tp-limit down$|d' \
            -e '\|^/usr/local/libexec/l2tp-egress pre-up "\$@"$|d' -e '\|^/usr/local/libexec/l2tp-egress up "\$@"$|d' -e '\|^/usr/local/libexec/l2tp-egress down "\$@"$|d' "$f"
    done
    for directory in /etc/xl2tpd/endpoints /etc/ppp/l2tp-endpoints; do
        [[ ! -L $directory ]] || fail "目录 $directory 为符号链接，未清理。"
        for f in "$directory"/*; do
            [[ -e $f || -L $f ]] || continue
            if [[ ${f##*/} =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\.(conf|options)$ ]]; then rm -f -- "$f"; fi
        done
        [[ ! -d $directory ]] || rmdir -- "$directory" 2>/dev/null || true
    done
    if [[ -f /etc/xl2tpd/xl2tpd.conf ]] && grep -q '^pppoptfile = /etc/ppp/options.xl2tpd$' /etc/xl2tpd/xl2tpd.conf; then rm -f /etc/xl2tpd/xl2tpd.conf; fi
    rm -f -- /etc/l2tp-pure.conf /etc/l2tp-endpoints.tsv /etc/ppp/options.xl2tpd /usr/local/libexec/l2tp-limit /usr/local/libexec/l2tp-egress /usr/local/libexec/l2tp-firewall /etc/systemd/system/l2tp-endpoint@.service /etc/systemd/system/l2tp-endpoints.target /etc/systemd/system/l2tp-firewall.service /etc/sysctl.d/90-l2tp-pure.conf /etc/tmpfiles.d/l2tp-ppp.conf
    systemctl daemon-reload
    logger -t l2tp-admin -- "event=uninstalled keep_accounts=$keep backup=$BACKUP"
    CONFIG_STARTED=0
    echo "卸载完成，备份保留于 $BACKUP。软件包、系统内核、其他账号/防火墙规则及当前系统转发开关未删除。"
}
management_menu() {
    [[ -t 0 ]] || fail '交互菜单需要终端；非交互运行请使用明确子命令。'
    local choice action n
    while true; do
        printf '\nL2TP 管理\n1 安装/重新配置\n2 查看账号\n3 增加账号\n4 修改账号/密码\n5 删除账号\n6 批量增加\n7 批量修改密码\n8 批量删除\n9 启用/禁用账号\n10 修改并发上限\n11 服务诊断\n12 查看日志\n13 更新入口出口映射\n14 卸载\n15 导入账号\n16 导出账号（不含密码）\n17 断开账号连接\n18 绑定账号出口 IP\n19 批量绑定出口 IP\n0 退出\n'
        read -r -p '选择：' choice || return
        case $choice in
            0) return;;
            1) action=install;; 2) action='account list';; 3) action='account add';;
            4) action='account mod';; 5) action='account del';; 6) action='account batch-add';;
            7) action='account batch-mod';; 8) action='account batch-del';;
            9) read -r -p '输入 enable 启用或 disable 禁用：' n; [[ $n == enable || $n == disable ]] || continue; action="account $n";;
            10) read -r -p '单账号并发上限（1–253）：' n; [[ $n =~ ^[0-9]{1,3}$ ]] || continue; action="limit $n";;
            11) action=check;; 12) action='log --no-follow';; 13) action=egress;; 14) action=uninstall;;
            15|16)
                read -r -p '文件完整路径：' n || return
                if [[ $choice == 15 ]]; then
                    if bash "${BASH_SOURCE[0]}" account import --file "$n"; then :; else warn '导入未完成。'; fi
                else
                    if bash "${BASH_SOURCE[0]}" account export --file "$n"; then :; else warn '导出未完成。'; fi
                fi
                continue;;
            17) action='account kick';;
            18|19)
                read -r -p '固定出口 IP（批量时为起始 IP）：' n || return
                if [[ $choice == 18 ]]; then action=bind; else action=batch-bind; fi
                if bash "${BASH_SOURCE[0]}" account "$action" --ip-start "$n"; then :; else warn '绑定未完成。'; fi
                continue;;
            *) echo '无效选项'; continue;;
        esac
        local -a menu_args
        read -r -a menu_args <<< "$action"
        # Separate Bash retains errexit inside each operation and releases locks on exit.
        if bash "${BASH_SOURCE[0]}" "${menu_args[@]}"; then :; else warn '操作未完成，请查看上方错误。'; fi
    done
}
# Allow sourcing functions for isolated validation.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
case ${1:-install} in
    -h|--help) usage; exit 0;;
    version|--version) printf '%s\n' "$SCRIPT_VERSION"; exit 0;;
esac
[[ $EUID -eq 0 ]] || fail 'Run as root (sudo bash l2tp2.sh).'
case ${1:-install} in
    install|egress|uninstall|limit|account|accounts|-a|--add|-d|--del|-m|--mod)
        mkdir -p /run/lock
        exec 8>/run/lock/l2tp-pure-admin.lock
        flock -x 8
        ;;
esac
case ${1:-install} in
    log) shift; show_logs "$@";;
    egress) migrate_egress;;
    check|--check) diagnose;;
    kernel|--install-kernel) kernel_install;;
    menu) management_menu;;
    account|accounts) shift; accounts "$@";;
    limit) shift; set_connection_limit "$@";;
    uninstall) shift; uninstall_l2tp "$@";;
    install) if (($#)); then shift; install_l2tp "$@";
             elif [[ -f /etc/l2tp-pure.conf && -t 0 ]]; then flock -u 8; exec 8>&-; management_menu;
             else install_l2tp; fi;;
    -l|--list|-a|--add|-d|--del|-m|--mod) manage "$1";;
    *) usage; exit 1;;
esac
fi
