# Azure TG Manager (全功能双栈、DDNS 与成本监控版)

一个运行在 Linux 宿主机上、通过 Telegram 即可全功能管理微软 Azure 云虚拟机的轻量级管家。支持任意 Azure 订阅类型，具备原生 IPv4 + IPv6 双栈部署、64GB (`P6`) 免费盘锁定、单栈/双栈独立洗 IP、Cloudflare 双域名自动 DDNS 同步、全链路孤儿资源粉碎、实时物理流量监控以及 Azure Cost Management 账单实时透视功能。

---

## 一、 Azure 订阅支持与省钱避坑规则

### 1. 全订阅通用与区域/配额限制

- **适用所有订阅**：无论是 **Azure 100（学生订阅 AZ100）**、**Azure 200（新用户 30 天试用）**，还是绑定信用卡的 **即用即付（Pay-As-You-Go）**、**MSDN 订阅**、**企业号（EA）**，底层调用的都是同一套 ARM 接口，均可原生接管。
- **单区域 3 个 IP 的配额陷阱（针对 AZ100 / AZ200）**：
  * 微软对学生和轻量试用订阅在**单个物理数据中心区域（例如日本东部 `japaneast`）设置了最多 3 个公网 IP 的硬限制**。
  * 由于本程序部署的是 **IPv4 + IPv6 原生双栈**，一台机器需要独占 2 个公网 IP（1 个 v4 + 1 个 v6）。
  * **跨区部署准则**：在 AZ100/200 下若要开 2 台双栈机器，**必须跨物理区域开机**（例如第一台开在 `japaneast` 日本东部，第二台开在另一个未受限区域）。各区域配额完全独立，每台机器独享 3 个配额（用 2 剩 1），洗 IP、删建不会撞车。付费订阅无此限制。
- **热门区域机型限制说明**：
  * 微软针对 AZ100 学生订阅在部分亚太热门区域（如新加坡 `southeastasia`、香港 `eastasia`）实施了订阅级容量限制，可能会屏蔽入门级 `B2ats_v2` / `B2pts_v2` / `B1s` 规格。程序已内置接口探测，会自动隐藏当前区域无货或受限的机型，并将可用免费规格置顶标注 `⭐[免费]`。

### 2. 免费机型与零成本白嫖指标（含双 750h 池玩法）

- **官方推荐的免费规格**：
  * **`Standard_B2pts_v2`**：Ampere 处理器，**2 核 1G 内存（ARM64 架构）**，高并发、低能耗。
  * **`Standard_B2ats_v2`**：AMD EPYC 处理器，**2 核 1G 内存（x86_64 架构）**，传统 Linux 与 Windows 兼容性极佳。
- **零成本白嫖三大硬指标**：
  * **计算时长（Linux 与 Windows 双池独立各 750 小时）**：
    * 微软每个账号每月赠送 **750 小时免费 Linux 计算时长** + **750 小时免费 Windows 计算时长**（两个计时池完全独立、互不占用）。
    * **同账号双开 2 台免费 Linux 进阶玩法**：第一台直接开 Linux（如 `B2pts_v2`）；第二台通过本机器人选择 **`Standard_B2ats_v2` + `Windows 2022 Smalldisk`** 开机，随后使用支持 UEFI 的脚本（如 `bin456789/reinstall`）DD 重装为 Linux。由于 Azure 计费系统仅根据创建时的镜像元数据归类，该机依然走 Windows 750 小时独立免费池，实现**单订阅同时 24 小时运行 2 台 2C1G Linux 算力 0 元**。
  * **磁盘存储（必须精确锁定 64GB `P6` 档位）**：
    * 官方每月免费赠送 **2 块精确 `64GB`（`P6` 档位）高级 SSD**。
    * **避坑提示**：若创建 30GB 系统盘，会被计费系统归入付费 `P4` 档位（按全价每天扣约 32 日元）。本程序已底层强制指定 `disk_size_gb=64`，创建即精准命中 `P6` 免费池，存储费用为 **0 元**。
  * **公网流量**：官方每月赠送 **100 GB 单向公网出站（Outbound / Egress）流量**，所有入站流量（Inbound）永久全免。

### 3. 账单扣费细节与真假关机

- **公网 IPv4 租用费**：微软对所有 Standard 静态 IPv4 按小时收取极低占用费（每小时约 $0.005，全月约 500~600 日元 / 3~4 美元）。这笔费用会**优先从你赠送的 100/200 美元赠金池里划扣**，赠金用尽前不会扣除实付资金。
- **微量流量（如 `Bandwidth: 0.022 JPY`）**：开机初始化时虚拟机内部 Azure Agent 与机房元数据服务通信产生的几兆字节内部流量，你的 100GB 免费公网出站额度依然完整保留。
- **真关机 vs 假关机**：在系统终端执行 `poweroff` 属于操作系统级假关机（后台状态为 `Stopped`，硬件插槽依然保留并计费）。必须在 Telegram 面板中点击 **【🛑 关机】**，调取底层 API 触发 `Deallocate`（已释放），才会彻底停止算力计费。

---

## 二、 核心架构与工程避坑复盘

1. **环境装甲（2GB Swap 自愈 + GLIBC 2.17 兼容运行时）**：  
   针对 1GB 内存的低配宿主机，部署脚本会自动探查并挂载 **2GB Swap 交换分区**，搭配兼容性极佳的 Miniconda 运行时，彻底根治安装依赖时被 Linux 内核 OOM Killer 强行中断的问题。

2. **精确 64GB (`P6`) 盘锁定与 Windows Smalldisk 适配**：  
   * 显式传入 `OSDisk(create_option='FromImage', disk_size_gb=64)`，规避默认 30GB 触发 `P4` 扣费及标准版 Windows 默认 127GB `P10` 高价盘问题。
   * 自动截断 `computer_name[:15]`，解决 Azure 对 Windows 计算机名超过 15 个字符直接报错 `InvalidParameter` 的限制。

3. **智能物理区域与受限规格过滤**：  
   * 过滤 `southeastasia3` 等后台逻辑节点（`Logical Region`），仅展示可真实建机的物理数据中心（`Physical`）。
   * 调用 `resource_skus` 接口实时剔除当前区域容量受限（`SkuNotAvailable`）的规格，并将免费机型置顶标注 `⭐[免费]`。

4. **CPU 架构对齐与强密码强制校验**：  
   * 自动探测 ARM64 与 x86_64 架构，精准匹配官方可用镜像（剔除已下架的 Debian 11），避免架构错配导致的启动死锁。
   * 密码生成器强制包含大小写字母、数字与特殊符号四类字符，百分百通过 Azure 复杂度策略校验。

5. **两阶段物理绑定与协议栈解耦洗 IP（Two-Phase Commit）**：  
   * 针对 Azure SDN 不允许原地修改 IP 协议版本的限制（`CannotChangePrivateIpAddressVersion`），采用 `ipcfg-v4` ➔ `ipcfg-v6-real` 两阶段重构。
   * 支持 **单独更换 IPv4**、**单独更换 IPv6** 以及 **双栈全洗** 三种模式，单洗时另一协议栈业务全程不断线。

6. **Cloudflare 双域名自动 DDNS 与会话状态持久化**：  
   * 零额外第三方依赖调用 Cloudflare v4 API，支持为每台实例分别绑定 **IPv4 域名（`A` 记录）** 和 **IPv6 域名（`AAAA` 记录）**，自动建改解析（`TTL=60s`，关闭代理小黄云直连）。
   * 每次洗 IP 前自动检测本地配置，未填完时弹窗提示（支持随时跳过，下次洗 IP 继续提醒直至配置完成）；引入 `PicklePersistence` 持久化会话状态，重启服务不丢失交互上下文。

7. **强类型 SDK 序列化与级联粉碎清道夫**：  
   * 全量采用 `NetworkInterface` 与 `NetworkInterfaceIPConfiguration` 强类型模型构建，避免 dict 序列化双重包裹导致公网 IP 丢失。
   * 删机时按顺序联动物理销毁系统磁盘、网卡、安全组与孤儿公网 IP；通配符 `"*"` 放行入站规则确保 ICMP Ping 全通。

---

## 三、 懒人一键获取 Azure 与 Cloudflare 凭据

### 1. 获取 Azure API 凭据（30 秒）

1. 浏览器打开 [Azure Portal](https://portal.azure.com/)，点击顶部搜索栏右侧的 **Cloud Shell 图标 (`>_`)** 并选择 **Bash**。
2. 粘贴并执行以下命令生成订阅级服务主体（Service Principal）：
   ```bash
   az ad sp create-for-rbac --role contributor --scopes /subscriptions/$(az account list --query [].id -o tsv)
   ```
3. 终端会返回如下 JSON 凭据：
   ```json
   {
     "appId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
     "displayName": "azure-cli-...",
     "password": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
     "tenant": "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy"
   }
   ```
   * `tenant` ➔ **Tenant ID**
   * `appId` ➔ **Client ID**
   * `password` ➔ **Client Secret**
4. 在同一终端执行下方命令获取 **Subscription ID**：
   ```bash
   az account show --query id -o tsv
   ```

### 2. 获取 Cloudflare DDNS 凭据（可选，用于洗 IP 自动改解析）

* **前提要求**：你的根域名（Zone，例如 `example.com`）已托管在 Cloudflare 且状态为 `Active`；**具体的子域名记录（如 `v4.example.com`、`v6.example.com`）无需提前创建**，机器人会在同步时自动新建或覆盖更新。
* **支持两种密钥格式（二选一）**：
  1. **方式 A（推荐，API Token）**：登录 Cloudflare 控制台进入 `My Profile -> API Tokens -> Create Token`，使用 **`Edit zone DNS`** 模板生成 40 位 Token，直接发送给机器人即可。
  2. **方式 B（Global API Key）**：若使用 37 位全局密钥，需按 **`你的CF注册邮箱:37位Global_API_Key`** 的格式发送给机器人。

---

## 四、 快速上手与操作指南

### 1. 一键部署与目录结构

在你的 Linux 宿主机终端中以 `root` 权限运行一键部署脚本：

```bash
bash install.sh
```

首次运行根据提示输入 **Telegram Bot Token**（通过 [@BotFather](https://t.me/BotFather) 获取）与 **管理员纯数字 UID**（通过 [@userinfobot](https://t.me/userinfobot) 获取）。所有运行文件均位于 `/opt/azure-bot/` 目录：

| 文件名 | 用途说明 |
| :--- | :--- |
| `bot.py` | 机器人核心调度与 Azure / Cloudflare API 交互主程序 |
| `tg_config.json` | Telegram Bot Token 与管理员 UID 配置（重跑安装脚本时自动保留） |
| `accounts.json` | 已绑定的 Azure 多订阅 API 凭据 |
| `cf_config.json` | Cloudflare 认证密钥及各实例的 V4 / V6 双域名映射表 |
| `bot_state.pkl` | 对话交互状态持久化文件 |

### 2. Telegram 操作面板说明

在 Telegram 对话框发送 `/start` 或 `/menu`：
- **➕ 绑定新账号 (`/bind`)**：输入凭据，机器人会自动完成 Provider 命名空间核验注册。
- **🌐 Cloudflare DNS 设置**：配置全局 CF 认证密钥，查看所有实例绑定的 V4 / V6 双域名列表。
- **➕ 动态开机 (双栈/64G免费盘)**：选择物理区域 ➔ 挑选规格（免费机型置顶）➔ 挑选镜像（支持 Ubuntu 22.04、Debian 12、CentOS 7.9 及可 DD 的 Windows 2022 Smalldisk）➔ 自动下发双栈构建。
- **🔄 洗 IPv4 / 洗 IPv6 / 双栈全洗**：支持单独更换 IPv4 或 IPv6，也可双栈全洗；每次操作前自动检测本地是否已配好 CF 双域名（未配完时弹窗引导，支持跳过），换 IP 完成后自动同步更新对应 `A` / `AAAA` 解析。
- **🚀 立即同步 CF / 🔗 配置双域名 (V4/V6)**：随时修改某台实例绑定的两个子域名，或手动一键将当前公网 IP 推送至 Cloudflare。
- **💰 查本月账单 (Cost)**：调取 Azure Cost Management 接口，按服务分类展示当月月初至今的累计账单明细。
- **📊 查流量与时长**：下发探针秒级读取虚拟机内物理网卡累计出站/入站流量与持续开机天数。
- **🛡️ 防火墙全开 / 🗑️ 彻底销毁**：一键全端口放行（含 ICMP Ping）；删机时全链路同步粉碎磁盘、网卡、安全组与公网 IP。

### 3. 进阶提示：Windows DD 重装 Linux 后启用 Azure IPv6

Azure 虚拟网络通过 **DHCPv6 + 1:1 NAT** 分配 IPv6（网卡内部仅显示 `fd00:...` 内网映射地址，外部通过公网 IPv6 直通）。若使用第三方重装脚本将 Windows DD 为 Debian/Ubuntu 后未在 `ifconfig` 中看到 IPv6，在目标实例内执行以下命令开启 DHCPv6 客户端即可：

```bash
sysctl -w net.ipv6.conf.all.disable_ipv6=0
sysctl -w net.ipv6.conf.eth0.accept_ra=2
dhclient -6 -1 -v eth0
```

---

## 五、 常用运维命令速查

```bash
# 查看机器人实时运行日志
journalctl -u azure-bot -f

# 检查服务运行状态
systemctl status azure-bot

# 重启机器人守护进程
systemctl restart azure-bot

# 停止机器人服务
systemctl stop azure-bot
```
