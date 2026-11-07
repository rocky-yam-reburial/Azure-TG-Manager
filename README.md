# Azure TG Manager (全功能双栈与成本监控版)

一个运行在 Linux 宿主机上、通过 Telegram 即可全功能管理微软 Azure 云虚拟机的轻量级管家。支持任意 Azure 订阅类型，具备原生 IPv4 + IPv6 双栈部署、两阶段物理洗 IP、全链路孤儿资源粉碎、实时物理流量监控以及 Azure Cost Management 账单实时透视功能。

---

## 一、 Azure 订阅支持与省钱规则

### 1. 全订阅通用与单区 IP 限制

* **适用所有订阅**：无论是 **Azure 100（学生订阅 AZ100）**、**Azure 200（新用户 30 天试用）**，还是绑定信用卡的 **即用即付（Pay-As-You-Go）**、**MSDN 订阅**、**企业号（EA）**，底层调用的都是同一套 ARM 接口，均可原生接管。
* **单区域 3 个 IP 的配额陷阱（针对 AZ100 / AZ200）**：
  * 微软对学生和轻量试用订阅在**单个数据中心区域（例如日本东部 `japaneast`）设置了最多 3 个公网 IP 的硬限制**。
  * 由于本程序部署的是 **IPv4 + IPv6 纯血双栈**，一台机器需要独占 2 个公网 IP（1 个 v4 + 1 个 v6）。
  * **跨区部署准则**：在 AZ100/200 下若要开 2 台双栈机器，**必须跨区域开机**（例如第一台开在 `japaneast` 日本东部，第二台开在 `southeastasia` 新加坡）。各区域配额完全独立，每台机器独享 3 个配额（用 2 剩 1），洗 IP、删建不会撞车。付费订阅无此限制。

### 2. 免费机型与防扣费指南

* **官方推荐的免费规格**：
  * **`Standard_B2pts_v2`**：Ampere 处理器，**2 核 1G 内存（ARM64 架构）**，高并发、低能耗。
  * **`Standard_B2ats_v2`**：AMD EPYC 处理器，**2 核 1G 内存（x86_64 架构）**，传统 Linux 软件兼容性极佳。
* **零成本白嫖三大指标**：
  * **计算时长**：微软每个账号每月赠送 **750 小时免费 Linux 计算时长**。一个月 31 天总共 744 小时，只要**保持同时只有 1 台 Linux 虚拟机开机运行**，算力费用就是 **0 元**。
  * **磁盘存储**：官方每月赠送 **2 块 64GB (P6) 高级 SSD**。开机选 30G~64G 磁盘，存储费用为 **0 元**。
  * **公网流量**：官方每月赠送 **100 GB** 的互联网出站流量（进站全免费），普通个人用途基本用不完。
* **账单扣费细节透视**：
  * **公网 IPv4 租用费**：微软对所有 Standard IPv4 按小时收取极低占用费（每小时约 $0.005，全月约 500~600 日元 / 3~4 美元）。这笔费用会**优先从你赠送的 100/200 美元赠金池里划扣**，赠金用尽前绝对不会扣除银行卡实付资金。
  * **微量流量（如 `Bandwidth: 0.022 JPY`）**：这是开机初始化时虚拟机内部 Azure Agent 探针与机房元数据服务通信产生的几兆字节跨区内部流量（折合不到 0.0001 美元），你的 100GB 免费公网出站额度依然完全未动。
  * **真关机 vs 假关机**：在虚拟机终端执行 `poweroff` 属于操作系统级假关机（后台状态为 `Stopped`，硬件插槽依然保留并计费）。必须在 Telegram 面板中点击 **【🛑 关机】**，调取底层 API 触发 `Deallocate`（已释放），才会彻底停止计费。

---

## 二、 核心架构与避坑复盘

1. **环境装甲（Swap 内存自愈）**：  
   针对 1GB 内存的低配宿主机，脚本在初始化时会自动探查并挂载 **2GB Swap 交换分区**，彻底根治 Conda 解析依赖树时被 Linux 内核 OOM Killer 强行中断的问题。

2. **CPU 架构与镜像严格对齐**：  
   * 自动探测机型架构，规避 ARM64 规格引导 x86 镜像导致的 BIOS/EFI 死锁。
   * 精准映射 Azure Marketplace 真实存在镜像：ARM64 严格匹配 `Debian:debian-12:12-arm64` 与 `Canonical:0001-com-ubuntu-server-jammy:22_04-lts-arm64`（无 `-gen2` 伪后缀）。

3. **两阶段物理绑定（Two-Phase Commit）**：  
   针对 Azure SDN 不允许在老配置上原地将协议从 IPv4 改为 IPv6 的限制（`CannotChangePrivateIpAddressVersion`），程序采用两阶段重构：先单配 `ipcfg-v4` 并挂载公网 IPv4 下发，再以全新命名 `ipcfg-v6-real` 追加挂载 IPv6，确保双栈即开即通。

4. **强类型 SDK 序列化模型**：  
   全量采用 `NetworkInterface` 与 `NetworkInterfaceIPConfiguration` 强类型模型构建，规避使用 Python dict 时被 Azure SDK 序列化器双重包裹 `properties: {properties: ...}` 导致公网 IP 被静默丢弃的缺陷。

5. **级联粉碎清道夫（Cascade Scavenger）**：  
   删除虚拟机时，联动销毁其关联的系统磁盘（OS Disk）、网卡（NIC）、安全组（NSG）以及闲置的公网 IP。开机与洗 IP 前置扫描清理孤儿 IP，腾出配额防撞墙。

6. **通配符防火墙放行**：  
   安全组入站规则端口与协议均设置为通配符 `"*"`，解决端口设置错误导致 ICMP（Ping）被静默丢弃的问题。

---

## 三、 懒人一键获取 Azure API 凭据

无需在 Azure 复杂的网页控制台深层菜单中翻找，按以下步骤 30 秒即可拿齐所有凭据：

1. 浏览器打开 [Azure Portal](https://portal.azure.com/)。
2. 点击页面顶部搜索栏右侧的 **Cloud Shell 图标**（图标样式为 `>_`）。
3. 弹出终端环境时选择 **Bash**（若提示无存储，按默认提示点击创建存储即可）。
4. 在下方黑底终端中粘贴并执行以下命令：

   ```bash
   az ad sp create-for-rbac --role contributor --scopes /subscriptions/$(az account list --query [].id -o tsv)
   ```

5. 终端会立即返回一段 JSON 凭据：

   ```json
   {
     "appId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
     "displayName": "azure-cli-...",
     "password": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
     "tenant": "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy"
   }
   ```

   * `tenant` ➔ 机器人的 **Tenant ID**
   * `appId` ➔ 机器人的 **Client ID**
   * `password` ➔ 机器人的 **Client Secret**

6. 在同一终端运行下方命令查看订阅 ID：

   ```bash
   az account show --query id -o tsv
   ```

   * 输出的一串字符 ➔ 机器人的 **Subscription ID**

---

## 四、 快速上手与操作指南

### 1. 部署运行

在你的 Linux 宿主机终端中以 root 权限运行一键部署脚本：

```bash
bash install.sh
```

首次运行会提示输入：
* **Telegram Bot Token**（通过 [@BotFather](https://t.me/BotFather) 获取）
* **管理员纯数字 UID**（通过 [@userinfobot](https://t.me/userinfobot) 获取）

### 2. Telegram 操作面板说明

在 Telegram 对话框发送 `/start` 或 `/menu`：
* **➕ 绑定新账号 (`/bind`)**：输入凭据，机器人会自动完成 Provider 命名空间核验注册。
* **➕ 动态开机 (双栈)**：选择数据中心区域 ➔ 挑选实例规格（标注核数、内存与 ARM/x86 架构）➔ 挑选操作系统 ➔ 自动下发双栈构建。
* **🔄 洗 IP (V4+V6)**：全自动释放旧 IP、清场配额、两阶段挂载全新 IPv4 与 IPv6。
* **💰 查本月账单 (Cost)**：调取 Azure Cost Management 接口，按服务分类展示当月月初至今的累计账单与币种明细。
* **📊 查流量与时长**：直接下发探针秒级读取虚拟机内物理网卡累计出站流量与持续开机天数。
* **🛡️ 防火墙全开**：一键写入通配规则，全端口放行且 ICMP Ping 全绿。
* **🗑️ 彻底销毁**：虚拟机、磁盘、网卡、安全组、公网 IP 全链路同步粉碎，杜绝后台偷跑资源。

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
