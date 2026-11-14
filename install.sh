#!/bin/sh

BIN="/usr/local/bin/realm"
CONF_DIR="/etc/realm"
CONF="/etc/realm/config.toml"
SCRIPT="/root/realm.sh"
WATCHDOG="/usr/local/bin/realm-ddns.sh"
LOG_FILE="/var/log/realm-ddns.log"
STATE_FILE="/tmp/realm_ddns.state"

echo "=========================================================="
echo "      realm 转发工具 & 10秒 DDNS 守护全量安装/更新脚本     "
echo "=========================================================="

# 1. 检查并补齐基础依赖 (curl/wget/tar)
install_deps() {
    NEED_INSTALL=0
    command -v tar >/dev/null 2>&1 || NEED_INSTALL=1
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        NEED_INSTALL=1
    fi

    if [ "$NEED_INSTALL" -eq 1 ]; then
        echo "[1/5] 正在安装基础依赖工具..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -y >/dev/null 2>&1
            apt-get install -y curl wget tar >/dev/null 2>&1
        elif command -v apk >/dev/null 2>&1; then
            apk update >/dev/null 2>&1
            apk add curl wget tar >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            yum install -y curl wget tar >/dev/null 2>&1
        fi
    else
        echo "[1/5] 基础依赖检查通过。"
    fi
}

# 2. 下载或更新 realm 二进制核心 (采用 mv 原子替换，防止运行中报 Text file busy)
install_realm_bin() {
    if [ ! -f "$BIN" ] || [ "$1" = "update" ]; then
        echo "[2/5] 正在获取最新 realm 核心二进制文件..."
        ARCH=$(uname -m)
        case "$ARCH" in
            x86_64|amd64)
                URL="https://github.com/zhboner/realm/releases/latest/download/realm-x86_64-unknown-linux-musl.tar.gz"
                ;;
            aarch64|arm64)
                URL="https://github.com/zhboner/realm/releases/latest/download/realm-aarch64-unknown-linux-musl.tar.gz"
                ;;
            *)
                echo "[-] 错误: 暂不支持的系统架构 ($ARCH)"
                exit 1
                ;;
        esac

        rm -f /tmp/realm.tar.gz /tmp/realm
        if command -v curl >/dev/null 2>&1; then
            curl -sL -o /tmp/realm.tar.gz "$URL"
        else
            wget -qO /tmp/realm.tar.gz "$URL"
        fi

        if [ ! -s /tmp/realm.tar.gz ]; then
            echo "[-] 下载 realm 失败，请检查网络或 GitHub 连通性！"
            exit 1
        fi

        tar -xzf /tmp/realm.tar.gz -C /tmp
        chmod +x /tmp/realm
        mv -f /tmp/realm "$BIN"
        rm -f /tmp/realm.tar.gz
        echo "[+] realm 核心安装/更新完成 ($BIN)。"
    else
        echo "[2/5] 检测到 realm 核心已安装，跳过重复下载 (如需强制更新核心可执行: sh install.sh update)。"
    fi
}

# 3. 初始化配置文件与系统守护服务
setup_realm_service() {
    echo "[3/5] 配置转发服务守护与默认配置文件..."
    mkdir -p "$CONF_DIR"
    if [ ! -f "$CONF" ]; then
        printf "[network]\nno_tcp = false\nuse_udp = true\n\n" > "$CONF"
    fi

    if command -v systemctl >/dev/null 2>&1; then
        cat << 'SRV_EOF' > /etc/systemd/system/realm.service
[Unit]
Description=realm port forwarding service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Restart=always
RestartSec=2
LimitNOFILE=65535
ExecStart=/usr/local/bin/realm -c /etc/realm/config.toml

[Install]
WantedBy=multi-user.target
SRV_EOF
        systemctl daemon-reload
        systemctl enable realm >/dev/null 2>&1
    elif command -v rc-service >/dev/null 2>&1; then
        cat << 'RC_EOF' > /etc/init.d/realm
#!/sbin/openrc-run
name="realm"
command="/usr/local/bin/realm"
command_args="-c /etc/realm/config.toml"
command_background=true
pidfile="/run/realm.pid"

depend() {
    need net
}
RC_EOF
        chmod +x /etc/init.d/realm
        rc-update add realm default >/dev/null 2>&1
    fi
}

# 4. 部署 10 秒级 DDNS 动态域名解析守护进程
setup_ddns_watchdog() {
    echo "[4/5] 部署 10 秒级 DDNS 动态域名监控守护 ($WATCHDOG)..."
    cat << 'WD_EOF' > "$WATCHDOG"
#!/bin/sh

CONF="/etc/realm/config.toml"
BIN="/usr/local/bin/realm"
STATE_FILE="/tmp/realm_ddns.state"
LOG_FILE="/var/log/realm-ddns.log"

log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    if [ -f "$LOG_FILE" ] && [ "$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)" -gt 1000 ]; then
        tail -n 500 "$LOG_FILE" > "$LOG_FILE.tmp" && mv -f "$LOG_FILE.tmp" "$LOG_FILE"
    fi
}

restart_realm_svc() {
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q "realm.service"; then
        systemctl restart realm >/dev/null 2>&1
    elif command -v rc-service >/dev/null 2>&1 && rc-service -e realm >/dev/null 2>&1; then
        rc-service realm restart >/dev/null 2>&1
    else
        killall realm 2>/dev/null || pkill -9 -f "$BIN" 2>/dev/null
        nohup "$BIN" -c "$CONF" >/dev/null 2>&1 &
    fi
}

resolve_domain() {
    d="$1"
    res=""
    if command -v python3 >/dev/null 2>&1; then
        res=$(python3 -c "import socket, sys; infos = socket.getaddrinfo(sys.argv[1], None); print(','.join(sorted(set(i[4][0] for i in infos))))" "$d" 2>/dev/null)
    fi
    if [ -z "$res" ] && command -v getent >/dev/null 2>&1; then
        res=$(getent ahosts "$d" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ',' | sed 's/,$//')
    fi
    if [ -z "$res" ] && command -v nslookup >/dev/null 2>&1; then
        res=$(nslookup "$d" 2>/dev/null | awk '/^Name:/{f=1; next} f && /^Address/{print $NF}' | sort -u | tr '\n' ',' | sed 's/,$//')
    fi
    echo "$res"
}

log_msg "DDNS 10秒监控守护进程已启动。"

while true; do
    if [ -f "$CONF" ]; then
        DOMAINS=$(awk -F '"' '/^[[:space:]]*remote[[:space:]]*=/ {
            r = $2
            if (r ~ /^\[/) next
            sub(/:[0-9]+$/, "", r)
            if (r ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) next
            print r
        }' "$CONF" | sort -u)

        if [ -z "$DOMAINS" ]; then
            [ -f "$STATE_FILE" ] && rm -f "$STATE_FILE"
        else
            NEW_STATE_TMP="/tmp/realm_ddns.new.$$"
            : > "$NEW_STATE_TMP"
            NEED_RESTART=0

            for domain in $DOMAINS; do
                curr_ips=$(resolve_domain "$domain")
                old_ips=$(awk -F '=' -v d="$domain" '$1 == d {print $2}' "$STATE_FILE" 2>/dev/null)

                if [ -z "$curr_ips" ]; then
                    [ -n "$old_ips" ] && echo "${domain}=${old_ips}" >> "$NEW_STATE_TMP"
                    continue
                fi

                echo "${domain}=${curr_ips}" >> "$NEW_STATE_TMP"

                if [ -z "$old_ips" ]; then
                    log_msg "[初始化解析] $domain -> $curr_ips"
                elif [ "$curr_ips" != "$old_ips" ]; then
                    log_msg "[检测到IP变更] $domain : $old_ips => $curr_ips"
                    NEED_RESTART=1
                fi
            done

            mv -f "$NEW_STATE_TMP" "$STATE_FILE"

            if [ "$NEED_RESTART" -eq 1 ]; then
                log_msg "[触发更新] 正在重启 realm 以刷新 DNS 缓存与旧 UDP 会话..."
                restart_realm_svc
                log_msg "[更新完成] realm 服务已重启生效。"
            fi
        fi
    fi
    sleep 10
done
WD_EOF
    chmod +x "$WATCHDOG"

    if command -v systemctl >/dev/null 2>&1; then
        cat << 'WD_SRV' > /etc/systemd/system/realm-ddns.service
[Unit]
Description=realm DDNS 10s Watchdog Service
After=network-online.target realm.service

[Service]
Type=simple
User=root
Restart=always
RestartSec=3
ExecStart=/usr/local/bin/realm-ddns.sh

[Install]
WantedBy=multi-user.target
WD_SRV
        systemctl daemon-reload
        systemctl enable realm-ddns >/dev/null 2>&1
    elif command -v rc-service >/dev/null 2>&1; then
        cat << 'WD_RC' > /etc/init.d/realm-ddns
#!/sbin/openrc-run
name="realm-ddns"
command="/usr/local/bin/realm-ddns.sh"
command_background=true
pidfile="/run/realm-ddns.pid"

depend() {
    need net
}
WD_RC
        chmod +x /etc/init.d/realm-ddns
        rc-update add realm-ddns default >/dev/null 2>&1
    fi
}

# 5. 生成日常交互管理脚本 (/root/realm.sh)
install_manager_script() {
    echo "[5/5] 生成全功能交互管理脚本 ($SCRIPT)..."
    cat << 'MGR_EOF' > "$SCRIPT"
#!/bin/sh

BIN="/usr/local/bin/realm"
CONF="/etc/realm/config.toml"
WATCHDOG="/usr/local/bin/realm-ddns.sh"
LOG_FILE="/var/log/realm-ddns.log"
STATE_FILE="/tmp/realm_ddns.state"
mkdir -p /etc/realm

init_config() {
    if [ ! -f "$CONF" ]; then
        printf "[network]\nno_tcp = false\nuse_udp = true\n\n" > "$CONF"
    fi
}

check_status() {
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active realm >/dev/null 2>&1; then
        echo "转发服务: [ 运行中 (systemd守护) ]"
    elif command -v rc-service >/dev/null 2>&1 && rc-service realm status >/dev/null 2>&1; then
        echo "转发服务: [ 运行中 (OpenRC守护) ]"
    elif pidof realm >/dev/null 2>&1 || ps | grep -v grep | grep -q "$BIN"; then
        echo "转发服务: [ 运行中 (后台进程) ]"
    else
        echo "转发服务: [ 未运行 ]"
    fi

    if command -v systemctl >/dev/null 2>&1 && systemctl is-active realm-ddns >/dev/null 2>&1; then
        echo "DDNS监控: [ 运行中 (每10秒检测) ]"
    elif command -v rc-service >/dev/null 2>&1 && rc-service realm-ddns status >/dev/null 2>&1; then
        echo "DDNS监控: [ 运行中 (每10秒检测) ]"
    elif ps | grep -v grep | grep -q "realm-ddns.sh"; then
        echo "DDNS监控: [ 运行中 (每10秒检测) ]"
    else
        echo "DDNS监控: [ 未运行 ]"
    fi
}

open_firewall_port() {
    port="$1"
    [ -z "$port" ] && return
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "$port"/tcp >/dev/null 2>&1
        ufw allow "$port"/udp >/dev/null 2>&1
    fi
    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1
        ip6tables -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p udp --dport "$port" -j ACCEPT >/dev/null 2>&1
    fi
    if command -v iptables >/dev/null 2>&1; then
        iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1
        iptables -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "$port" -j ACCEPT >/dev/null 2>&1
    fi
}

restart_realm() {
    rm -f "$STATE_FILE"
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q "realm.service"; then
        systemctl restart realm >/dev/null 2>&1
        systemctl restart realm-ddns >/dev/null 2>&1
    elif command -v rc-service >/dev/null 2>&1 && rc-service -e realm >/dev/null 2>&1; then
        rc-service realm restart >/dev/null 2>&1
        rc-service realm-ddns restart >/dev/null 2>&1
    else
        killall realm 2>/dev/null || pkill -9 -f "$BIN" 2>/dev/null
        nohup "$BIN" -c "$CONF" >/dev/null 2>&1 &
        pkill -9 -f "$WATCHDOG" 2>/dev/null
        nohup "$WATCHDOG" >/dev/null 2>&1 &
    fi
    echo "[+] realm 与 DDNS 守护服务已重启，最新配置已生效！"
}

show_rules() {
    echo "======================================"
    echo " 当前已配置的转发规则 (支持IPv4+IPv6入)："
    awk -F '"' '/listen =/ {l=$2} /remote =/ {r=$2; c++; print " ["c"] " l " -> " r}' "$CONF"
    echo "======================================"
}

format_ipv6() {
    ip="$1"
    case "$ip" in
        *:*)
            case "$ip" in
                \[*\]) echo "$ip" ;;
                *) echo "[$ip]" ;;
            esac
            ;;
        *)
            echo "$ip"
            ;;
    esac
}

init_config

while true; do
    echo ""
    echo "====== realm 一键综合管理工具 ======"
    check_status
    show_rules
    echo " 1. 添加转发规则"
    echo " 2. 删除转发规则"
    echo " 3. 修改转发规则"
    echo " 4. 手动重启服务"
    echo " 5. 查看 DDNS 动态解析状态与日志"
    echo " 6. 彻底卸载 realm 及监控服务"
    echo " 0. 退出管理脚本"
    printf "请选择操作 [0-6]: "
    read opt

    case "$opt" in
        1)
            printf "请输入本地监听端口: "
            read lp
            printf "请输入目标 IP 或域名: "
            read rip
            printf "请输入目标端口: "
            read rp
            
            if [ -n "$lp" ] && [ -n "$rip" ] && [ -n "$rp" ]; then
                rip=$(format_ipv6 "$rip")
                printf "\n[[endpoints]]\nlisten = \"[::]:%s\"\nremote = \"%s:%s\"\n" "$lp" "$rip" "$rp" >> "$CONF"
                open_firewall_port "$lp"
                echo "[+] 成功添加并保存: [::]:$lp -> $rip:$rp"
                restart_realm
            else
                echo "[-] 警告: 输入参数不完整，取消添加！"
            fi
            ;;
        2)
            printf "请输入要删除的规则序号 (上图括号内的数字): "
            read del_id
            [ -z "$del_id" ] && continue

            echo "[network]" > "$CONF.tmp"
            echo "no_tcp = false" >> "$CONF.tmp"
            echo "use_udp = true" >> "$CONF.tmp"
            
            awk -F '"' -v id="$del_id" -v out="$CONF.tmp" '
            /listen =/ {l=$2} 
            /remote =/ {
                r=$2; c++; 
                if(c != id) {
                    printf "\n[[endpoints]]\nlisten = \"%s\"\nremote = \"%s\"\n", l, r >> out
                }
            }' "$CONF"
            
            mv -f "$CONF.tmp" "$CONF"
            echo "[+] 指定规则删除完成！"
            restart_realm
            ;;
        3)
            printf "请输入要修改的规则序号 (上图括号内的数字): "
            read edit_id
            [ -z "$edit_id" ] && continue

            curr_listen=$(awk -F '"' -v id="$edit_id" '/listen =/ {l=$2} /remote =/ {r=$2; c++; if(c==id) print l}' "$CONF")
            curr_remote=$(awk -F '"' -v id="$edit_id" '/listen =/ {l=$2} /remote =/ {r=$2; c++; if(c==id) print r}' "$CONF")
            
            if [ -z "$curr_listen" ] || [ -z "$curr_remote" ]; then
                echo "[-] 无效的序号，找不到对应的规则！"
                continue
            fi
            
            lp_old=${curr_listen##*:}
            rp_old=${curr_remote##*:}
            rip_old=${curr_remote%:*}

            echo ">>> 提示: 若无需修改某项，直接按回车键即可保持原值。"
            printf "修改 本地监听端口 [%s]: " "$lp_old"
            read lp_new
            lp_new=${lp_new:-$lp_old}

            printf "修改 目标 IP 或域名 [%s]: " "$rip_old"
            read rip_new
            rip_new=${rip_new:-$rip_old}
            rip_new=$(format_ipv6 "$rip_new")

            printf "修改 目标端口 [%s]: " "$rp_old"
            read rp_new
            rp_new=${rp_new:-$rp_old}

            echo "[network]" > "$CONF.tmp"
            echo "no_tcp = false" >> "$CONF.tmp"
            echo "use_udp = true" >> "$CONF.tmp"
            
            awk -F '"' -v id="$edit_id" -v nlp="[::]:$lp_new" -v nrem="${rip_new}:${rp_new}" -v out="$CONF.tmp" '
            /listen =/ {l=$2} 
            /remote =/ {
                r=$2; c++; 
                if(c == id) {
                    printf "\n[[endpoints]]\nlisten = \"%s\"\nremote = \"%s\"\n", nlp, nrem >> out
                } else {
                    printf "\n[[endpoints]]\nlisten = \"%s\"\nremote = \"%s\"\n", l, r >> out
                }
            }' "$CONF"
            
            mv -f "$CONF.tmp" "$CONF"
            open_firewall_port "$lp_new"
            echo "[+] 规则修改成功: [::]:$lp_new -> $rip_new:$rp_new"
            restart_realm
            ;;
        4)
            restart_realm
            ;;
        5)
            echo "--------------------------------------"
            echo "当前动态域名解析快照 ($STATE_FILE):"
            if [ -s "$STATE_FILE" ]; then
                cat "$STATE_FILE"
            else
                echo "暂无动态域名规则（当前规则均为固定 IP 或尚未完成首次解析）。"
            fi
            echo "--------------------------------------"
            echo "最近 20 条 DDNS 监控日志 ($LOG_FILE):"
            if [ -f "$LOG_FILE" ]; then
                tail -n 20 "$LOG_FILE"
            else
                echo "暂无日志记录。"
            fi
            echo "--------------------------------------"
            ;;
        6)
            printf "确认彻底卸载 realm 及 DDNS 监控服务吗？[y/N]: "
            read confirm
            if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                if command -v systemctl >/dev/null 2>&1; then
                    systemctl stop realm realm-ddns >/dev/null 2>&1
                    systemctl disable realm realm-ddns >/dev/null 2>&1
                    rm -f /etc/systemd/system/realm.service /etc/systemd/system/realm-ddns.service
                    systemctl daemon-reload
                elif command -v rc-service >/dev/null 2>&1; then
                    rc-service realm stop >/dev/null 2>&1
                    rc-service realm-ddns stop >/dev/null 2>&1
                    rc-update del realm default >/dev/null 2>&1
                    rc-update del realm-ddns default >/dev/null 2>&1
                    rm -f /etc/init.d/realm /etc/init.d/realm-ddns
                fi
                killall realm 2>/dev/null || pkill -9 -f "$BIN" 2>/dev/null
                pkill -9 -f "$WATCHDOG" 2>/dev/null
                rm -rf /etc/realm "$BIN" "$WATCHDOG" "$LOG_FILE" "$STATE_FILE" "$0"
                echo "[+] 卸载清理完成！"
                exit 0
            fi
            ;;
        0)
            echo "退出工具。随时输入 /root/realm.sh 再次进入管理。"
            exit 0
            ;;
        *)
            echo "[-] 无效选项，请重新选择"
            ;;
    esac
done
MGR_EOF
    chmod +x "$SCRIPT"
}

# 执行安装与更新流程
install_deps
install_realm_bin "$1"
setup_realm_service
setup_ddns_watchdog
install_manager_script

# 启动或重启服务
rm -f "$STATE_FILE"
if command -v systemctl >/dev/null 2>&1; then
    systemctl restart realm >/dev/null 2>&1
    systemctl restart realm-ddns >/dev/null 2>&1
elif command -v rc-service >/dev/null 2>&1; then
    rc-service realm restart >/dev/null 2>&1
    rc-service realm-ddns restart >/dev/null 2>&1
else
    killall realm 2>/dev/null || pkill -9 -f "$BIN" 2>/dev/null
    nohup "$BIN" -c "$CONF" >/dev/null 2>&1 &
    pkill -9 -f "$WATCHDOG" 2>/dev/null
    nohup "$WATCHDOG" >/dev/null 2>&1 &
fi

echo ""
echo "=========================================================="
echo "  [+] 全量部署/更新完成！"
echo "  [+] 管理脚本路径: /root/realm.sh"
echo "  [+] DDNS 监控日志: /var/log/realm-ddns.log"
echo "=========================================================="

# 若在交互式终端中运行，自动进入管理菜单
if [ -t 0 ]; then
    exec "$SCRIPT"
fi
