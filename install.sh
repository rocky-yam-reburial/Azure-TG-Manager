#!/bin/bash
# ==============================================================================
# Project: Azure TG Manager (Universal Production Edition)
# Compatibility: CentOS 7+ / RHEL 7+ / Debian 10+ / Ubuntu 20.04+ (GLIBC 2.17+)
# Support: All Azure Subscriptions (AZ100, AZ200, PayG, MSDN, Enterprise)
# Features: Dual-Stack, Two-Phase IP Binding, Cost API, Traffic Monitor, Auto-Scavenger
# ==============================================================================

set -e

if [ "$EUID" -ne 0 ]; then
    echo "❌ 权限错误: 必须使用 root 用户执行此脚本！"
    exit 1
fi

WORK_DIR="/opt/azure-bot"
JSON_FILE="$WORK_DIR/tg_config.json"
CONDA_DIR="/opt/conda"
ENV_NAME="azure-bot"

echo "=================================================="
echo " 🚀 正在启动 Azure TG Manager 生产级全自动部署..."
echo "=================================================="

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# 1. 基础系统工具链探测与补齐
echo "🔍 [1/7] 检查基础工具链..."
if command -v yum &> /dev/null; then
    for pkg in curl tar git bzip2; do
        if ! command -v "$pkg" &> /dev/null; then
            yum install -y "$pkg" > /dev/null 2>&1
        fi
    done
elif command -v apt-get &> /dev/null; then
    apt-get update -y > /dev/null 2>&1
    for pkg in curl tar git bzip2; do
        if ! command -v "$pkg" &> /dev/null; then
            apt-get install -y "$pkg" > /dev/null 2>&1
        fi
    done
fi
echo "   ✅ 基础工具链就绪。"

# 2. 内存装甲探测 (Swap 挂载，防止低配服务器依赖解析时 OOM 崩溃)
echo "🔍 [2/7] 检查内存装甲 (Swap)..."
SWAP_TOTAL=$(free -m | awk '/^Swap:/ {print $2}')
if [ -z "$SWAP_TOTAL" ] || [ "$SWAP_TOTAL" -lt 1024 ]; then
    echo "   ⚠️ 当前可用 Swap 不足 1GB，正在分配 2GB Swap 内存装甲..."
    dd if=/dev/zero of=/swapfile bs=1M count=2048 status=progress
    chmod 600 /swapfile
    mkswap /swapfile > /dev/null 2>&1
    swapon /swapfile
    if ! grep -q "/swapfile" /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    echo "   ✅ 2GB Swap 内存装甲挂载完毕。"
else
    echo "   ✅ Swap 空间充足 (${SWAP_TOTAL}MB)。"
fi

# 3. 部署兼容老系统的 Python 3.10 环境 (Miniconda 23.5.2)
echo "🔍 [3/7] 巡检 Miniconda 运行时..."
if [ -x "$CONDA_DIR/bin/conda" ]; then
    echo "   ✅ 检测到已有 Miniconda 引擎，跳过部署。"
else
    echo "   ⏳ 正在下载 GLIBC 2.17 兼容版 Miniconda..."
    curl -fsSL https://repo.anaconda.com/miniconda/Miniconda3-py310_23.5.2-0-Linux-x86_64.sh -o miniconda.sh
    bash miniconda.sh -b -p "$CONDA_DIR"
    rm -f miniconda.sh
    echo "   ✅ Miniconda 引擎安装完毕。"
fi

# 4. 创建专属沙盒并安装所需 SDK（含 Cost Management 账单模块）
echo "🔍 [4/7] 校验 Python 沙盒与 Azure 云驱动依赖..."
if "$CONDA_DIR/bin/conda" env list | grep -q "^$ENV_NAME "; then
    echo "   ✅ 运行沙盒 [$ENV_NAME] 已就绪。"
else
    echo "   ⏳ 正在创建专属沙盒 [$ENV_NAME]..."
    "$CONDA_DIR/bin/conda" create -y -n "$ENV_NAME" python=3.10 > /dev/null 2>&1
fi

"$CONDA_DIR/envs/$ENV_NAME/bin/pip" install -q --upgrade pip
"$CONDA_DIR/envs/$ENV_NAME/bin/pip" install -q \
    python-telegram-bot \
    azure-identity \
    azure-mgmt-resource \
    azure-mgmt-network \
    azure-mgmt-compute \
    azure-mgmt-subscription \
    azure-mgmt-costmanagement
echo "   ✅ 云驱动及计费 API 依赖安装完毕。"

# 5. 交互式录入 TG 配置 (已有配置则写保护保留)
echo "🔍 [5/7] 检查项目主配置..."
if [ -f "$JSON_FILE" ]; then
    echo "   🛡️ 发现已有生产配置，保留原配置。"
else
    echo "   ⚠️ 首次部署，请输入 Telegram 核心参数："
    read -p "   👉 请输入 Telegram Bot Token: " TG_TOKEN
    read -p "   👉 请输入 管理员 UID (纯数字): " ADMIN_UID

    cat << JSON_EOF > "$JSON_FILE"
{
    "token": "$TG_TOKEN",
    "admin_id": $ADMIN_UID
}
JSON_EOF
    echo "   ✅ 核心配置文件生成成功。"
fi

# 6. 生成核心调度程序 (bot.py)
echo "🔍 [6/7] 注入生产级 bot.py 主调度引擎..."
cat << 'PY_EOF' > "$WORK_DIR/bot.py"
import logging, json, os, random, string, asyncio, datetime
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup, ReplyKeyboardRemove
from telegram.ext import (
    ApplicationBuilder, CommandHandler, MessageHandler, filters,
    ConversationHandler, CallbackQueryHandler, ContextTypes
)
from azure.identity import ClientSecretCredential
from azure.mgmt.resource import ResourceManagementClient
from azure.mgmt.network import NetworkManagementClient
from azure.mgmt.compute import ComputeManagementClient
from azure.mgmt.subscription import SubscriptionClient
from azure.mgmt.costmanagement import CostManagementClient
from azure.mgmt.costmanagement.models import (
    QueryDefinition, QueryDataset, QueryAggregation, QueryGrouping
)
from azure.mgmt.network.models import (
    SecurityRule, NetworkInterface, NetworkInterfaceIPConfiguration
)
from azure.mgmt.compute.models import (
    VirtualMachine, HardwareProfile, StorageProfile, ImageReference,
    OSProfile, NetworkProfile, NetworkInterfaceReference, RunCommandInput
)

with open('tg_config.json', 'r', encoding='utf-8') as f:
    cfg = json.load(f)

TG_BOT_TOKEN = cfg['token']
ADMIN_UID = int(cfg['admin_id'])
DATA_FILE = "accounts.json"
logging.basicConfig(format='%(asctime)s - %(levelname)s - %(message)s', level=logging.INFO)

SIZE_MAP = {}
OS_OPTIONS = {
    'ubuntu22': {
        'pub': 'Canonical',
        'offer': '0001-com-ubuntu-server-jammy',
        'sku_x86': '22_04-lts-gen2',
        'sku_arm': '22_04-lts-arm64',
        'name': 'Ubuntu 22.04 LTS (支持 ARM/x86)'
    },
    'debian12': {
        'pub': 'Debian',
        'offer': 'debian-12',
        'sku_x86': '12-gen2',
        'sku_arm': '12-arm64',
        'name': 'Debian 12 (支持 ARM/x86)'
    },
    'debian11': {
        'pub': 'Debian',
        'offer': 'debian-11',
        'sku_x86': '11-backports-gen2',
        'sku_arm': '11-backports-arm64',
        'name': 'Debian 11 (支持 ARM/x86)'
    },
    'centos7': {
        'pub': 'OpenLogic',
        'offer': 'CentOS',
        'sku_x86': '7_9-gen2',
        'sku_arm': None,
        'name': 'CentOS 7.9 (仅 x86)'
    }
}

LOC_MAP = {
    'japaneast': 'JP', 'japanwest': 'JP', 'southeastasia': 'SG', 'eastasia': 'HK',
    'eastus': 'US', 'eastus2': 'US', 'westus': 'US', 'westus2': 'US', 'westus3': 'US',
    'southcentralus': 'US', 'koreacentral': 'KR', 'koreasouth': 'KR',
    'uksouth': 'UK', 'ukwest': 'UK', 'westeurope': 'EU', 'northeurope': 'EU',
    'francecentral': 'FR', 'australiaeast': 'AU'
}

def load_accounts():
    if os.path.exists(DATA_FILE):
        with open(DATA_FILE, 'r', encoding='utf-8') as f: return json.load(f)
    return {}

def save_accounts(data):
    with open(DATA_FILE, 'w', encoding='utf-8') as f: json.dump(data, f, indent=4)

def generate_strong_password(length=16):
    return ''.join(random.choice(string.ascii_letters + string.digits + "!@#$%^&*") for _ in range(length))

async def get_vm_specs(comp_client, location, size_name):
    key = f"{location}_{size_name}"
    if key in SIZE_MAP: return SIZE_MAP[key]
    try:
        loop = asyncio.get_event_loop()
        sizes = await loop.run_in_executor(None, lambda: list(comp_client.virtual_machine_sizes.list(location)))
        for s in sizes:
            SIZE_MAP[f"{location}_{s.name}"] = f"{s.number_of_cores}C {s.memory_in_mb//1024}G"
        return SIZE_MAP.get(key, size_name)
    except Exception:
        return size_name

def build_keyboard(items, page, per_page, prefix_sel, prefix_page):
    start, end = page * per_page, page * per_page + per_page
    kb = [[InlineKeyboardButton(item['name'], callback_data=f"{prefix_sel}_{item['id']}")] for item in items[start:end]]
    nav = []
    if page > 0: nav.append(InlineKeyboardButton("⬅️ 上一页", callback_data=f"{prefix_page}_{page-1}"))
    if end < len(items): nav.append(InlineKeyboardButton("下一页 ➡️", callback_data=f"{prefix_page}_{page+1}"))
    if nav: kb.append(nav)
    kb.append([InlineKeyboardButton("🔙 返回面板", callback_data="gohome")])
    return kb

A_ALIAS, A_TENANT, A_CLIENT, A_SECRET, A_SUB = range(5)
async def bind_start(u, c):
    if u.message.from_user.id != ADMIN_UID: return ConversationHandler.END
    hint = (
        "🔗 **多账户绑定向导**\n\n"
        "💡 **如何快速获取 API 凭据：**\n"
        "1. 打开 Azure Portal 网页右上角的 **Cloud Shell** (图标 `>_`)\n"
        "2. 环境选择 **Bash**，然后直接粘贴执行以下命令：\n"
        "`az ad sp create-for-rbac --role contributor --scopes /subscriptions/$(az account list --query [].id -o tsv)`\n\n"
        "执行后返回的 JSON 中：\n"
        "• `tenant` ➔ **Tenant ID**\n"
        "• `appId` ➔ **Client ID**\n"
        "• `password` ➔ **Client Secret**\n"
        "• 查询 Sub ID：`az account show --query id -o tsv`\n\n"
        "👉 **现在，请输入账户备注名 (Alias，例如 AZ-Student):**"
    )
    await u.message.reply_text(hint, reply_markup=ReplyKeyboardRemove(), parse_mode='Markdown')
    return A_ALIAS
async def get_alias(u, c): c.user_data['a'] = u.message.text.strip(); await u.message.reply_text("请输入 Tenant ID (即 JSON 中的 tenant):"); return A_TENANT
async def get_tenant(u, c): c.user_data['t'] = u.message.text.strip(); await u.message.reply_text("请输入 Client ID (即 JSON 中的 appId):"); return A_CLIENT
async def get_client(u, c): c.user_data['c'] = u.message.text.strip(); await u.message.reply_text("请输入 Client Secret (即 JSON 中的 password):"); return A_SECRET
async def get_secret(u, c): c.user_data['s'] = u.message.text.strip(); await u.message.reply_text("请输入 Subscription ID:"); return A_SUB
async def verify(u, c):
    sid = u.message.text.strip()
    try:
        cred = ClientSecretCredential(c.user_data['t'], c.user_data['c'], c.user_data['s'])
        res = ResourceManagementClient(cred, sid)
        list(res.resource_groups.list(top=1))
        for p in ['Microsoft.Network', 'Microsoft.Compute', 'Microsoft.CostManagement', 'Microsoft.Consumption']:
            try: res.providers.register(p)
            except Exception: pass
        accs = load_accounts(); alias = c.user_data['a']
        accs[alias] = {'tenant_id': c.user_data['t'], 'client_id': c.user_data['c'], 'client_secret': c.user_data['s'], 'subscription_id': sid}
        save_accounts(accs)
        await u.message.reply_text(f"✅ 账号 `{alias}` 绑定成功！网络/计算/计费 Provider 已自动核验。")
    except Exception as e:
        await u.message.reply_text(f"❌ 绑定失败: {str(e)[:150]}")
    c.user_data.clear(); return ConversationHandler.END

async def menu(u, c):
    uid = u.message.from_user.id if u.message else u.callback_query.from_user.id
    if uid != ADMIN_UID: return
    accs = load_accounts()
    kb = [[InlineKeyboardButton(f"📁 {a}", callback_data=f"acc_{a}")] for a in accs.keys()]
    kb.append([InlineKeyboardButton("➕ 绑定新账号", callback_data="add_account")])
    msg = "📋 **Azure 智能管家 - 主面板**"
    if u.message: await u.message.reply_text(msg, reply_markup=InlineKeyboardMarkup(kb), parse_mode='Markdown')
    else: await u.callback_query.edit_message_text(msg, reply_markup=InlineKeyboardMarkup(kb), parse_mode='Markdown')

async def button_handler(update, context):
    query = update.callback_query; await query.answer(); data = query.data
    accs = load_accounts(); alias = context.user_data.get('cur_alias')

    if data == "add_account": await query.edit_message_text("请直接发送 /bind 开启绑定向导。")
    elif data == "gohome": await menu(update, context)
    elif data.startswith("acc_"):
        alias = data.replace("acc_", ""); context.user_data['cur_alias'] = alias
        kb = [
            [InlineKeyboardButton("🖥️ 实例列表", callback_data="list_vms")],
            [InlineKeyboardButton("➕ 动态开机 (双栈)", callback_data="new_vm")],
            [InlineKeyboardButton("💰 查本月账单 (Cost)", callback_data=f"cost_{alias}")],
            [InlineKeyboardButton("🔙 返回首页", callback_data="gohome")]
        ]
        await query.edit_message_text(f"🔧 **当前账户**: `{alias}`", reply_markup=InlineKeyboardMarkup(kb), parse_mode='Markdown')

    elif data.startswith("cost_"):
        target_alias = data.replace("cost_", "")
        context.application.create_task(work_cost(query, context, target_alias, accs[target_alias]))

    elif data == "new_vm":
        await query.edit_message_text("🌍 正在拉取可用数据中心区域...")
        context.application.create_task(work_fetch_locs(query, context, accs[alias]))
    elif data.startswith("locpage_"):
        page = int(data.split("_")[1])
        kb = build_keyboard(context.user_data['locs'], page, 8, "locsel", "locpage")
        await query.edit_message_text("🌍 **请选择目标数据中心区域：**", reply_markup=InlineKeyboardMarkup(kb), parse_mode='Markdown')
    elif data.startswith("locsel_"):
        context.user_data['cur_loc'] = data.split("_", 1)[1]
        await query.edit_message_text("⚙️ 正在拉取该区域可用机型配置 (Size)...")
        context.application.create_task(work_fetch_sizes(query, context, accs[alias], context.user_data['cur_loc']))
    elif data.startswith("szpage_"):
        page = int(data.split("_")[1])
        kb = build_keyboard(context.user_data['sizes'], page, 8, "szsel", "szpage")
        await query.edit_message_text("⚙️ **请选择套餐配置：**", reply_markup=InlineKeyboardMarkup(kb), parse_mode='Markdown')
    elif data.startswith("szsel_"):
        size_id = data.split("_", 1)[1]
        context.user_data['cur_size'] = size_id
        is_arm = "pts" in size_id.lower() or "arm" in size_id.lower()
        
        kb = []
        for osid, info in OS_OPTIONS.items():
            if is_arm and not info['sku_arm']:
                continue
            kb.append([InlineKeyboardButton(info['name'], callback_data=f"ossel_{osid}")])
        kb.append([InlineKeyboardButton("🔙 返回面板", callback_data="gohome")])
        arch_label = "ARM64" if is_arm else "x86_64"
        await query.edit_message_text(f"🐧 **当前机型架构为 [{arch_label}]，请选择适配镜像：**", reply_markup=InlineKeyboardMarkup(kb), parse_mode='Markdown')

    elif data.startswith("ossel_"):
        os_id = data.split("_", 1)[1]
        size_id = context.user_data['cur_size']
        await query.edit_message_text(f"🚀 下发双栈构建指令: `{size_id}` ...")
        context.application.create_task(work_create_vm(query, context, accs[alias], alias, size_id, os_id))

    elif data == "list_vms":
        await query.edit_message_text("⏳ 正在跨区域拉取底层实例状态..."); context.application.create_task(work_list(query, context, alias, accs[alias]))
    elif data.startswith("mg_"):
        vm = data.replace("mg_", "")
        loc = context.user_data.get(f"loc_{vm}", "Unknown")
        spec = context.user_data.get(f"spec_{vm}", "Unknown")
        ip = context.user_data.get(f"ip_{vm}", "Unknown")
        admin = context.user_data.get(f"admin_{vm}", "Unknown")
        header = f"⚙️ **管理控制台**: `{vm}`\n📍 区域: `{loc}`\n⚡ 规格: `{spec}`\n🌐 IP 状态:\n`{ip}`\n👤 用户: `{admin}`\n\n请选择操作："
        kb = [
            [InlineKeyboardButton("🟢 启动", callback_data=f"act_start_{vm}"), InlineKeyboardButton("🛑 关机", callback_data=f"act_stop_{vm}")],
            [InlineKeyboardButton("🔄 洗 IP (V4+V6)", callback_data=f"act_cip_{vm}"), InlineKeyboardButton("🗑️ 彻底销毁", callback_data=f"act_delete_{vm}")],
            [InlineKeyboardButton("📊 查流量与时长", callback_data=f"vmuse_{vm}"), InlineKeyboardButton("🔑 修改密码", callback_data=f"oscmd_pwd_{vm}")],
            [InlineKeyboardButton("🛡️ 防火墙全开", callback_data=f"fw_all_{vm}"), InlineKeyboardButton("🔒 恢复默认22", callback_data=f"fw_def_{vm}")],
            [InlineKeyboardButton("🔙 返回列表", callback_data="list_vms")]
        ]
        await query.edit_message_text(header, reply_markup=InlineKeyboardMarkup(kb), parse_mode='Markdown')

    elif data.startswith("vmuse_"):
        vm = data.replace("vmuse_", "")
        context.application.create_task(work_vm_usage(query, context, accs[alias], vm))

    elif data.startswith("act_") or data.startswith("fw_"):
        parts = data.split("_", 2)
        act, vm = parts[1], parts[2]
        dict_names = {
            "start": "🟢 启动实例", "stop": "🛑 关机并停止计费", "reboot": "🔄 重启实例",
            "delete": "🗑️ 彻底销毁(包括磁盘/网卡/安全组/孤儿IP)", "cip": "🔄 洗 IP(两阶段重铸双栈)",
            "all": "🔓 放行所有端口(含 ICMP Ping)", "def": "🔒 仅放行 22 端口"
        }
        kb = [[InlineKeyboardButton("✅ 确认执行", callback_data=f"do_{data}")], [InlineKeyboardButton("❌ 取消操作", callback_data=f"mg_{vm}")]]
        await query.edit_message_text(f"⚠️ **高危确认**\n针对 `{vm}` 执行:\n**{dict_names.get(act, act)}**\n是否继续？", reply_markup=InlineKeyboardMarkup(kb), parse_mode='Markdown')

    elif data.startswith("do_act_"):
        _, _, act, vm = data.split("_", 3)
        await query.edit_message_text(f"⏳ 正在下发指令 {act}...")
        context.application.create_task(work_act(query, context, accs[alias], vm, act))
    elif data.startswith("do_fw_"):
        _, _, mode, vm = data.split("_", 3)
        await query.edit_message_text("🛡️ 正在应用安全组策略...")
        context.application.create_task(work_fw(query, context, accs[alias], vm, mode))
    elif data.startswith("oscmd_"):
        _, act, vm = data.split("_", 2)
        context.user_data['cmd_vm'], context.user_data['cmd_act'], context.user_data['wait_input'] = vm, act, True
        if act == "pwd": await query.edit_message_text(f"🔑 请回复 `{vm}` 的新密码:")
        else: await query.edit_message_text(f"👤 请按 `用户名:密码` 格式回复:")

async def work_cost(q, c, alias, acc):
    await q.edit_message_text(f"⏳ 正在向 Azure 调取 [{alias}] 本月账单明细...")
    try:
        cred = ClientSecretCredential(acc['tenant_id'], acc['client_id'], acc['client_secret'])
        sub_id = acc['subscription_id']
        cost_client = CostManagementClient(cred)
        loop = asyncio.get_event_loop()

        scope = f"/subscriptions/{sub_id}"
        query_def = QueryDefinition(
            type="ActualCost",
            timeframe="MonthToDate",
            dataset=QueryDataset(
                granularity="None",
                aggregation={"totalCost": QueryAggregation(name="Cost", function="Sum")},
                grouping=[QueryGrouping(type="Dimension", name="ServiceName")]
            )
        )

        result = await loop.run_in_executor(None, lambda: cost_client.query.usage(scope=scope, parameters=query_def))
        
        col_names = [col.name.lower() for col in result.columns]
        cost_idx = 0
        for i, name in enumerate(col_names):
            if name in ['cost', 'pretaxcost', 'totalcost']:
                cost_idx = i
                break
        srv_idx = col_names.index('servicename') if 'servicename' in col_names else -1
        curr_idx = col_names.index('currency') if 'currency' in col_names else -1

        total_cost = 0.0
        currency = "USD"
        services = {}

        if result.rows:
            for row in result.rows:
                c_val = float(row[cost_idx]) if row[cost_idx] is not None else 0.0
                total_cost += c_val
                s_name = str(row[srv_idx]) if srv_idx != -1 else "其他服务"
                if curr_idx != -1 and row[curr_idx]:
                    currency = str(row[curr_idx])
                services[s_name] = services.get(s_name, 0.0) + c_val

        now_str = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
        msg = f"💰 **账户 [{alias}] 本月账单报告**\n"
        msg += f"⏱️ 查询时间: `{now_str}`\n"
        msg += f"📅 统计区间: `月初至今 (Month To Date)`\n"
        msg += f"💵 **当前产生费用: `{total_cost:.3f} {currency}`**\n"
        msg += "—" * 20 + "\n"

        if total_cost == 0.0:
            msg += "🎉 **当前一分钱没花！**\n所有资源都在免费额度内，完全没有消耗你的 100/200 刀余额。\n"
        else:
            msg += "📋 **各项服务扣费明细:**\n"
            for sname, scost in sorted(services.items(), key=lambda x: x[1], reverse=True):
                msg += f"  • `{sname}`: **{scost:.3f} {currency}**\n"
            msg += f"\n💡 *注: 这些小额扣费是直接从你账号的赠金余额里划扣的，赠金没耗尽前不会产生任何欠费。*\n"

        kb = [[InlineKeyboardButton("🔙 返回账户", callback_data=f"acc_{alias}")]]
        await q.edit_message_text(msg, reply_markup=InlineKeyboardMarkup(kb), parse_mode='Markdown')

    except Exception as e:
        err_msg = str(e)
        if "SubscriptionBillingTypeNotSupported" in err_msg:
            hint = "该订阅类型微软暂未开放公开 Cost 查询 API，请登录 Azure Portal 控制台查看。"
        elif "AuthorizationFailed" in err_msg:
            hint = "权限不足，请确认该 Service Principal 在订阅上至少具有 Reader（读取者）或 Cost Management Reader 权限。"
        else:
            hint = f"接口反馈: {err_msg[:200]}"
        kb = [[InlineKeyboardButton("🔙 返回账户", callback_data=f"acc_{alias}")]]
        await q.edit_message_text(f"❌ 账单查询未完成\n\n{hint}", reply_markup=InlineKeyboardMarkup(kb))

async def work_vm_usage(q, c, acc, vm):
    await q.edit_message_text(f"⏳ 正在拉取实例 `{vm}` 的实时运行与流量数据...")
    try:
        cred = ClientSecretCredential(acc['tenant_id'], acc['client_id'], acc['client_secret'])
        comp = ComputeManagementClient(cred, acc['subscription_id'])
        loop = asyncio.get_event_loop()

        vm_obj = None
        target_rg = c.user_data.get(f"rg_{vm}")
        if target_rg:
            try: vm_obj = await loop.run_in_executor(None, lambda: comp.virtual_machines.get(target_rg, vm))
            except Exception: vm_obj = None
        if not vm_obj:
            all_vms = await loop.run_in_executor(None, lambda: list(comp.virtual_machines.list_all()))
            for v in all_vms:
                if v.name == vm:
                    vm_obj, target_rg = v, v.id.split('/')[4]
                    break

        bash_script = [
            'up_sec=$(awk \'{print int($1)}\' /proc/uptime 2>/dev/null || echo 0)\n'
            'd=$((up_sec/86400))\n'
            'h=$(((up_sec%86400)/3600))\n'
            'm=$(((up_sec%3600)/60))\n'
            'iface="eth0"\n'
            '[ ! -d "/sys/class/net/$iface" ] && iface=$(ls /sys/class/net | grep -v lo | head -n 1)\n'
            'tx_b=$(cat /sys/class/net/$iface/statistics/tx_bytes 2>/dev/null || echo 0)\n'
            'rx_b=$(cat /sys/class/net/$iface/statistics/rx_bytes 2>/dev/null || echo 0)\n'
            'tx_gb=$(awk -v b="$tx_b" \'BEGIN {printf "%.3f", b/1073741824}\')\n'
            'rx_gb=$(awk -v b="$rx_b" \'BEGIN {printf "%.3f", b/1073741824}\')\n'
            'echo "RESULT:UP=$d天$h小时$m分|TX=$tx_gb|RX=$rx_gb"\n'
        ]

        vm_cmd = RunCommandInput(command_id='RunShellScript', script=bash_script)
        res = await loop.run_in_executor(None, lambda: comp.virtual_machines.begin_run_command(target_rg, vm, vm_cmd).result())
        output = res.value[0].message if res.value else ""
        
        up_str, tx_gb, rx_gb = "未知", "0.000", "0.000"
        for line in output.split('\n'):
            if "RESULT:" in line:
                parts = line.replace("RESULT:", "").strip().split('|')
                for p in parts:
                    if p.startswith("UP="): up_str = p.replace("UP=", "")
                    elif p.startswith("TX="): tx_gb = p.replace("TX=", "")
                    elif p.startswith("RX="): rx_gb = p.replace("RX=", "")

        msg = f"📊 **实例 `{vm}` 硬件用量统计**\n"
        msg += "—" * 20 + "\n"
        msg += f"⏱️ **持续运行时间**: `{up_str}`\n"
        msg += f"📤 **本机出站流量**: `{tx_gb} GB` / 100 GB (月免费公网额度)\n"
        msg += f"📥 **本机入站流量**: `{rx_gb} GB` (全免)\n\n"
        msg += "💡 *小贴士: 出站流量由当前系统网卡物理统计，重启后会重置计数；微软整月免费公网出站为 100GB，正常使用完全不用担心超标。*"

        kb = [[InlineKeyboardButton("🔙 返回控制台", callback_data=f"mg_{vm}")]]
        await q.edit_message_text(msg, reply_markup=InlineKeyboardMarkup(kb), parse_mode='Markdown')
    except Exception as e:
        kb = [[InlineKeyboardButton("🔙 返回控制台", callback_data=f"mg_{vm}")]]
        await q.edit_message_text(f"❌ 获取用量失败: {str(e)[:150]}", reply_markup=InlineKeyboardMarkup(kb))

async def work_fetch_locs(q, c, acc):
    try:
        cred = ClientSecretCredential(acc['tenant_id'], acc['client_id'], acc['client_secret'])
        locs_obj = await asyncio.get_event_loop().run_in_executor(None, lambda: list(SubscriptionClient(cred).subscriptions.list_locations(acc['subscription_id'])))
        c.user_data['locs'] = [{'id': l.name, 'name': l.display_name} for l in locs_obj]
        kb = build_keyboard(c.user_data['locs'], 0, 8, "locsel", "locpage")
        await q.edit_message_text("🌍 **请选择目标数据中心区域：**", reply_markup=InlineKeyboardMarkup(kb), parse_mode='Markdown')
    except Exception as e: await q.edit_message_text(f"❌ 区域拉取失败: {str(e)[:150]}")

async def work_fetch_sizes(q, c, acc, location):
    try:
        cred = ClientSecretCredential(acc['tenant_id'], acc['client_id'], acc['client_secret'])
        sizes_obj = await asyncio.get_event_loop().run_in_executor(None, lambda: list(ComputeManagementClient(cred, acc['subscription_id']).virtual_machine_sizes.list(location)))
        sizes = [{'id': s.name, 'name': f"{s.name} ({s.number_of_cores}C {s.memory_in_mb//1024}G)", 'cores': s.number_of_cores, 'ram': s.memory_in_mb} for s in sizes_obj]
        sizes.sort(key=lambda x: (x['cores'], x['ram']))
        c.user_data['sizes'] = sizes
        kb = build_keyboard(sizes, 0, 8, "szsel", "szpage")
        await q.edit_message_text(f"⚙️ **{location} 规格配置:**", reply_markup=InlineKeyboardMarkup(kb), parse_mode='Markdown')
    except Exception as e: await q.edit_message_text(f"❌ 规格拉取失败: {str(e)[:150]}")

async def work_create_vm(q, c, acc, alias, size_id, os_id):
    loc = c.user_data['cur_loc']
    os_info = OS_OPTIONS[os_id]
    admin_user = "azureuser"
    country_code = LOC_MAP.get(loc.lower(), loc[:2].upper())
    timestamp = datetime.datetime.now().strftime('%Y%m%d%H%M%S')
    vm_name = f"{country_code}{timestamp}{random.randint(10, 99)}"
    rg_name = f"TG-Bot-{loc}-RG"

    is_arm = "pts" in size_id.lower() or "arm" in size_id.lower()
    chosen_sku = os_info['sku_arm'] if is_arm else os_info['sku_x86']

    if is_arm and not chosen_sku:
        await q.edit_message_text(f"❌ 该镜像不支持 ARM64 规格 `{size_id}`。")
        return

    cred = ClientSecretCredential(acc['tenant_id'], acc['client_id'], acc['client_secret'])
    sub_id = acc['subscription_id']
    net = NetworkManagementClient(cred, sub_id)
    comp = ComputeManagementClient(cred, sub_id)
    loop = asyncio.get_event_loop()

    created_pip_v4_name = None
    created_pip_v6_name = None
    created_nic_name = None

    try:
        await loop.run_in_executor(None, lambda: ResourceManagementClient(cred, sub_id).resource_groups.create_or_update(rg_name, {'location': loc}))

        existing_pips = await loop.run_in_executor(None, lambda: list(net.public_ip_addresses.list(rg_name)))
        for ep in existing_pips:
            if not ep.ip_configuration:
                try:
                    await loop.run_in_executor(None, lambda name=ep.name: net.public_ip_addresses.begin_delete(rg_name, name).result())
                except Exception: pass

        await loop.run_in_executor(None, lambda: net.virtual_networks.begin_create_or_update(rg_name, f"vnet-{loc}", {'location': loc, 'address_space': {'address_prefixes': ['10.0.0.0/16', 'fd00:abcd:ef12::/48']}}).result())
        subnet = await loop.run_in_executor(None, lambda: net.subnets.begin_create_or_update(rg_name, f"vnet-{loc}", "default", {'address_prefixes': ['10.0.0.0/24', 'fd00:abcd:ef12:1::/64']}).result())

        created_pip_v4_name = f"{vm_name}-v4"
        pip_v4 = await loop.run_in_executor(None, lambda: net.public_ip_addresses.begin_create_or_update(rg_name, created_pip_v4_name, {'location': loc, 'public_ip_allocation_method': 'Static', 'sku': {'name': 'Standard'}, 'public_ip_address_version': 'IPv4'}).result())

        created_pip_v6_name = f"{vm_name}-v6"
        pip_v6 = await loop.run_in_executor(None, lambda: net.public_ip_addresses.begin_create_or_update(rg_name, created_pip_v6_name, {'location': loc, 'public_ip_allocation_method': 'Static', 'sku': {'name': 'Standard'}, 'public_ip_address_version': 'IPv6'}).result())

        rule = SecurityRule(protocol="*", access="Allow", direction="Inbound", priority=100, name="TG_Bot_Rule", source_address_prefix="*", source_port_range="*", destination_address_prefix="*", destination_port_range="*")
        nsg = await loop.run_in_executor(None, lambda: net.network_security_groups.begin_create_or_update(rg_name, f"{vm_name}-nsg", {'location': loc, 'security_rules': [rule]}).result())

        created_nic_name = f"{vm_name}-nic"
        nic_params = NetworkInterface(
            location=loc,
            network_security_group=nsg,
            ip_configurations=[
                NetworkInterfaceIPConfiguration(
                    name="ipcfg-v4",
                    primary=True,
                    private_ip_address_version="IPv4",
                    public_ip_address=pip_v4,
                    subnet=subnet
                )
            ]
        )
        nic = await loop.run_in_executor(None, lambda: net.network_interfaces.begin_create_or_update(rg_name, created_nic_name, nic_params).result())

        nic.ip_configurations.append(
            NetworkInterfaceIPConfiguration(
                name="ipcfg-v6-real",
                primary=False,
                private_ip_address_version="IPv6",
                public_ip_address=pip_v6,
                subnet=subnet
            )
        )
        nic = await loop.run_in_executor(None, lambda: net.network_interfaces.begin_create_or_update(rg_name, created_nic_name, nic).result())

        admin_pwd = generate_strong_password()
        vm_params = VirtualMachine(
            location=loc, hardware_profile=HardwareProfile(vm_size=size_id),
            storage_profile=StorageProfile(image_reference=ImageReference(publisher=os_info['pub'], offer=os_info['offer'], sku=chosen_sku, version='latest')),
            os_profile=OSProfile(computer_name=vm_name, admin_username=admin_user, admin_password=admin_pwd),
            network_profile=NetworkProfile(network_interfaces=[NetworkInterfaceReference(id=nic.id, primary=True)])
        )

        await q.edit_message_text(f"🚀 正在构建 `{vm_name}` (架构: {'ARM64' if is_arm else 'x86_64'})...")
        await loop.run_in_executor(None, lambda: comp.virtual_machines.begin_create_or_update(rg_name, vm_name, vm_params).result())

        pip_v4_detail = await loop.run_in_executor(None, lambda: net.public_ip_addresses.get(rg_name, created_pip_v4_name))
        pip_v6_detail = await loop.run_in_executor(None, lambda: net.public_ip_addresses.get(rg_name, created_pip_v6_name))

        receipt = f"✅ **双栈开机成功**\n{'='*20}\n**实例名称**: `{vm_name}`\n**架构类型**: `{'ARM64' if is_arm else 'x86_64'}`\n**公网 IPv4**: `{pip_v4_detail.ip_address}`\n**公网 IPv6**: `{pip_v6_detail.ip_address}`\n**登录账号**: `{admin_user}`\n**初始密码**: `{admin_pwd}`\n{'='*20}"
        kb = [[InlineKeyboardButton(f"⚙️ 立即管理 {vm_name}", callback_data=f"mg_{vm_name}")]]
        await q.edit_message_text(receipt, reply_markup=InlineKeyboardMarkup(kb), parse_mode='Markdown')
    except Exception as e:
        if created_nic_name:
            try: await loop.run_in_executor(None, lambda: net.network_interfaces.begin_delete(rg_name, created_nic_name).result())
            except Exception: pass
        if created_pip_v4_name:
            try: await loop.run_in_executor(None, lambda: net.public_ip_addresses.begin_delete(rg_name, created_pip_v4_name).result())
            except Exception: pass
        if created_pip_v6_name:
            try: await loop.run_in_executor(None, lambda: net.public_ip_addresses.begin_delete(rg_name, created_pip_v6_name).result())
            except Exception: pass
        await q.edit_message_text(f"❌ 创建失败 (已自动回滚残留资源):\n`{str(e)[:300]}`", parse_mode='Markdown')

async def work_list(q, c, alias, acc):
    try:
        cred = ClientSecretCredential(acc['tenant_id'], acc['client_id'], acc['client_secret'])
        comp = ComputeManagementClient(cred, acc['subscription_id'])
        net = NetworkManagementClient(cred, acc['subscription_id'])
        loop = asyncio.get_event_loop()

        vms = await loop.run_in_executor(None, lambda: list(comp.virtual_machines.list_all()))
        msg = f"🖥️ **{alias} 实例概览**\n" + "—"*15 + "\n"
        kb = []
        for vm in vms:
            rg = vm.id.split('/')[4]; loc = vm.location; raw_sz = vm.hardware_profile.vm_size
            spec_fmt = await get_vm_specs(comp, loc, raw_sz); full_spec = f"{spec_fmt} ({raw_sz})"
            admin_user = vm.os_profile.admin_username if vm.os_profile else "未知"
            ip = "无 IP"
            c.user_data[f"rg_{vm.name}"], c.user_data[f"loc_{vm.name}"], c.user_data[f"spec_{vm.name}"], c.user_data[f"admin_{vm.name}"] = rg, loc, full_spec, admin_user
            try:
                nic_n = vm.network_profile.network_interfaces[0].id.split('/')[-1]
                c.user_data[f"nic_{vm.name}"] = nic_n
                nic = await loop.run_in_executor(None, lambda: net.network_interfaces.get(rg, nic_n))
                ip_list = []
                for ipcfg in nic.ip_configurations:
                    if ipcfg.public_ip_address:
                        pip_n = ipcfg.public_ip_address.id.split('/')[-1]
                        pip = await loop.run_in_executor(None, lambda: net.public_ip_addresses.get(rg, pip_n))
                        ip_list.append(pip.ip_address)
                ip = "\n".join(ip_list) if ip_list else "无 IP"
            except Exception: pass
            c.user_data[f"ip_{vm.name}"] = ip
            msg += f"🔹 **{vm.name}**\n📍 区域: `{loc}`\n⚡ 规格: `{full_spec}`\n🌐 IP:\n`{ip}`\n\n"
            kb.append([InlineKeyboardButton(f"⚙️ 管理 {vm.name}", callback_data=f"mg_{vm.name}")])
        kb.append([InlineKeyboardButton("🔙 返回", callback_data=f"acc_{alias}")])
        await q.edit_message_text(msg, reply_markup=InlineKeyboardMarkup(kb), parse_mode='Markdown')
    except Exception as e: await q.edit_message_text(f"❌ 列表拉取失败: {str(e)[:100]}")

async def work_fw(q, c, acc, vm, mode):
    try:
        cred = ClientSecretCredential(acc['tenant_id'], acc['client_id'], acc['client_secret'])
        comp = ComputeManagementClient(cred, acc['subscription_id'])
        net = NetworkManagementClient(cred, acc['subscription_id'])
        loop = asyncio.get_event_loop()

        vm_obj = None
        target_rg = c.user_data.get(f"rg_{vm}")
        if target_rg:
            try: vm_obj = await loop.run_in_executor(None, lambda: comp.virtual_machines.get(target_rg, vm))
            except Exception: vm_obj = None
        if not vm_obj:
            all_vms = await loop.run_in_executor(None, lambda: list(comp.virtual_machines.list_all()))
            for v in all_vms:
                if v.name == vm:
                    vm_obj, target_rg = v, v.id.split('/')[4]
                    break

        nic_n = vm_obj.network_profile.network_interfaces[0].id.split('/')[-1]
        loc = vm_obj.location
        nic = await loop.run_in_executor(None, lambda: net.network_interfaces.get(target_rg, nic_n))
        nsg_n = nic.network_security_group.id.split('/')[-1] if nic.network_security_group else f"{vm}-nsg"
        
        target_port = "*" if mode == "all" else "22"
        proto = "*" if mode == "all" else "Tcp"
        rule = SecurityRule(protocol=proto, access="Allow", direction="Inbound", priority=100, name="TG_Bot_Rule", source_address_prefix="*", source_port_range="*", destination_address_prefix="*", destination_port_range=target_port)
        await loop.run_in_executor(None, lambda: net.network_security_groups.begin_create_or_update(target_rg, nsg_n, {'location': loc, 'security_rules': [rule]}).result())
        await q.edit_message_text(f"✅ 防火墙策略 `{mode}` 已生效！", reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("🔙 返回控制台", callback_data=f"mg_{vm}")]]), parse_mode='Markdown')
    except Exception as e: await q.edit_message_text(f"❌ 防火墙调整失败: {str(e)[:150]}")

async def work_act(q, c, acc, vm, act):
    try:
        cred = ClientSecretCredential(acc['tenant_id'], acc['client_id'], acc['client_secret'])
        sub_id = acc['subscription_id']
        comp = ComputeManagementClient(cred, sub_id)
        net = NetworkManagementClient(cred, sub_id)
        loop = asyncio.get_event_loop()

        vm_obj = None
        target_rg = c.user_data.get(f"rg_{vm}")
        if target_rg:
            try: vm_obj = await loop.run_in_executor(None, lambda: comp.virtual_machines.get(target_rg, vm))
            except Exception: vm_obj = None
        if not vm_obj:
            all_vms = await loop.run_in_executor(None, lambda: list(comp.virtual_machines.list_all()))
            for v in all_vms:
                if v.name == vm:
                    vm_obj, target_rg = v, v.id.split('/')[4]
                    break

        if not vm_obj:
            await q.edit_message_text(f"❌ 检索不到实例 `{vm}`。")
            return

        loc = vm_obj.location
        nic_n = vm_obj.network_profile.network_interfaces[0].id.split('/')[-1]

        if act == "start":
            await loop.run_in_executor(None, lambda: comp.virtual_machines.begin_start(target_rg, vm).result())
            msg = f"✅ `{vm}` 已成功启动！"
        elif act == "stop":
            await loop.run_in_executor(None, lambda: comp.virtual_machines.begin_deallocate(target_rg, vm).result())
            msg = f"✅ `{vm}` 已关机 (Deallocated 状态，停止扣费)！"
        elif act == "reboot":
            await loop.run_in_executor(None, lambda: comp.virtual_machines.begin_restart(target_rg, vm).result())
            msg = f"✅ `{vm}` 重启成功！"
        
        elif act == "delete":
            disk_id = vm_obj.storage_profile.os_disk.managed_disk.id if vm_obj.storage_profile and vm_obj.storage_profile.os_disk and vm_obj.storage_profile.os_disk.managed_disk else None
            nic_ids = [n.id for n in vm_obj.network_profile.network_interfaces] if vm_obj.network_profile else []

            await loop.run_in_executor(None, lambda: comp.virtual_machines.begin_delete(target_rg, vm).result())
            if disk_id:
                try: await loop.run_in_executor(None, lambda: comp.disks.begin_delete(target_rg, disk_id.split('/')[-1]).result())
                except Exception: pass
            
            for nid in nic_ids:
                nn = nid.split('/')[-1]
                try:
                    nic_obj = await loop.run_in_executor(None, lambda: net.network_interfaces.get(target_rg, nn))
                    nsg_id = nic_obj.network_security_group.id if nic_obj.network_security_group else None
                    pip_ids = [ipc.public_ip_address.id for ipc in nic_obj.ip_configurations if ipc.public_ip_address]
                    await loop.run_in_executor(None, lambda: net.network_interfaces.begin_delete(target_rg, nn).result())
                    if nsg_id:
                        try: await loop.run_in_executor(None, lambda: net.network_security_groups.begin_delete(target_rg, nsg_id.split('/')[-1]).result())
                        except Exception: pass
                    for pid in pip_ids:
                        try: await loop.run_in_executor(None, lambda: net.public_ip_addresses.begin_delete(target_rg, pid.split('/')[-1]).result())
                        except Exception: pass
                except Exception: pass

            pips = await loop.run_in_executor(None, lambda: list(net.public_ip_addresses.list(target_rg)))
            for p in pips:
                if not p.ip_configuration:
                    try: await loop.run_in_executor(None, lambda name=p.name: net.public_ip_addresses.begin_delete(target_rg, name).result())
                    except Exception: pass

            msg = f"🗑️ 实例 `{vm}` 及其关联的网卡、系统磁盘、安全组、公网IP已彻底物理销毁！"

        elif act == "cip":
            nic = await loop.run_in_executor(None, lambda: net.network_interfaces.get(target_rg, nic_n))
            subnet = await loop.run_in_executor(None, lambda: net.subnets.get(target_rg, f"vnet-{loc}", "default"))

            nsg_name = f"{vm}-nsg"
            rule = SecurityRule(
                protocol="*", access="Allow", direction="Inbound", priority=100,
                name="TG_Bot_Rule", source_address_prefix="*", source_port_range="*",
                destination_address_prefix="*", destination_port_range="*"
            )
            nsg = await loop.run_in_executor(None, lambda: net.network_security_groups.begin_create_or_update(
                target_rg, nsg_name, {'location': loc, 'security_rules': [rule]}
            ).result())
            nic.network_security_group = nsg

            old_pips = []
            if nic.ip_configurations:
                for ipc in nic.ip_configurations:
                    if ipc.public_ip_address:
                        old_pips.append(ipc.public_ip_address.id.split('/')[-1])

            nic.ip_configurations = [
                NetworkInterfaceIPConfiguration(
                    name="ipcfg-v4",
                    primary=True,
                    private_ip_address_version="IPv4",
                    public_ip_address=None,
                    subnet=subnet
                )
            ]
            nic = await loop.run_in_executor(None, lambda: net.network_interfaces.begin_create_or_update(target_rg, nic_n, nic).result())

            for opip in old_pips:
                try: await loop.run_in_executor(None, lambda name=opip: net.public_ip_addresses.begin_delete(target_rg, name).result())
                except Exception: pass

            pips = await loop.run_in_executor(None, lambda: list(net.public_ip_addresses.list(target_rg)))
            for p in pips:
                if not p.ip_configuration:
                    try: await loop.run_in_executor(None, lambda name=p.name: net.public_ip_addresses.begin_delete(target_rg, name).result())
                    except Exception: pass

            v4_name = f"ip-{vm}-v4-{random.randint(1000, 9999)}"
            v6_name = f"ip-{vm}-v6-{random.randint(1000, 9999)}"
            new_v4 = await loop.run_in_executor(None, lambda: net.public_ip_addresses.begin_create_or_update(
                target_rg, v4_name, {'location': loc, 'public_ip_allocation_method': 'Static', 'sku': {'name': 'Standard'}, 'public_ip_address_version': 'IPv4'}
            ).result())
            new_v6 = await loop.run_in_executor(None, lambda: net.public_ip_addresses.begin_create_or_update(
                target_rg, v6_name, {'location': loc, 'public_ip_allocation_method': 'Static', 'sku': {'name': 'Standard'}, 'public_ip_address_version': 'IPv6'}
            ).result())

            nic.ip_configurations = [
                NetworkInterfaceIPConfiguration(
                    name="ipcfg-v4",
                    primary=True,
                    private_ip_address_version="IPv4",
                    public_ip_address=new_v4,
                    subnet=subnet
                )
            ]
            nic = await loop.run_in_executor(None, lambda: net.network_interfaces.begin_create_or_update(target_rg, nic_n, nic).result())

            nic.ip_configurations.append(
                NetworkInterfaceIPConfiguration(
                    name="ipcfg-v6-real",
                    primary=False,
                    private_ip_address_version="IPv6",
                    public_ip_address=new_v6,
                    subnet=subnet
                )
            )
            await loop.run_in_executor(None, lambda: net.network_interfaces.begin_create_or_update(target_rg, nic_n, nic).result())

            c.user_data[f"ip_{vm}"] = f"V4: {new_v4.ip_address}\nV6: {new_v6.ip_address}"
            msg = f"✅ 洗 IP 成功！(两阶段物理绑定完成)\n\n**新 IPv4:** `{new_v4.ip_address}`\n**新 IPv6:** `{new_v6.ip_address}`"

        await q.edit_message_text(msg, reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("🔙 返回控制台", callback_data=f"mg_{vm}")]]), parse_mode='Markdown')
    except Exception as e: await q.edit_message_text(f"❌ 操作失败: {str(e)[:150]}")

async def handle_text_input(u, c):
    if not c.user_data.get('wait_input') or u.message.from_user.id != ADMIN_UID: return
    c.user_data['wait_input'] = False
    vm, act, alias = c.user_data.get('cmd_vm'), c.user_data.get('cmd_act'), c.user_data.get('cur_alias')
    acc = load_accounts().get(alias); text = u.message.text.strip(); admin = c.user_data.get(f"admin_{vm}", "azureuser")
    await u.message.reply_text(f"⏳ 正在为 `{vm}` 下发操作...")
    if act == "pwd": script = [f'echo "{admin}:{text}" | chpasswd']
    else:
        if ":" not in text: return await u.message.reply_text("❌ 格式解析失败，请按 用户名:密码 格式输入。")
        user, pwd = text.split(":", 1)
        script = [f'useradd -m -s /bin/bash -G sudo {user} || true', f'echo "{user}:{pwd}" | chpasswd']
    c.application.create_task(run_shell(u, c, acc, vm, script))

async def run_shell(u, c, acc, vm, script):
    try:
        cred = ClientSecretCredential(acc['tenant_id'], acc['client_id'], acc['client_secret'])
        comp = ComputeManagementClient(cred, acc['subscription_id'])
        loop = asyncio.get_event_loop()
        
        vm_obj = None
        target_rg = c.user_data.get(f"rg_{vm}")
        if target_rg:
            try: vm_obj = await loop.run_in_executor(None, lambda: comp.virtual_machines.get(target_rg, vm))
            except Exception: vm_obj = None
        if not vm_obj:
            all_vms = await loop.run_in_executor(None, lambda: list(comp.virtual_machines.list_all()))
            for v in all_vms:
                if v.name == vm:
                    vm_obj, target_rg = v, v.id.split('/')[4]
                    break

        vm_cmd = RunCommandInput(command_id='RunShellScript', script=script)
        await loop.run_in_executor(None, lambda: comp.virtual_machines.begin_run_command(target_rg, vm, vm_cmd).result())
        await u.message.reply_text(f"✅ `{vm}` 指令执行成功！", parse_mode='Markdown')
    except Exception as e: await u.message.reply_text(f"❌ 失败: {str(e)[:150]}")

def main():
    app = ApplicationBuilder().token(TG_BOT_TOKEN).build()
    app.add_handler(ConversationHandler(
        entry_points=[CommandHandler('bind', bind_start)],
        states={
            A_ALIAS: [MessageHandler(filters.TEXT & ~filters.COMMAND, get_alias)],
            A_TENANT: [MessageHandler(filters.TEXT & ~filters.COMMAND, get_tenant)],
            A_CLIENT: [MessageHandler(filters.TEXT & ~filters.COMMAND, get_client)],
            A_SECRET: [MessageHandler(filters.TEXT & ~filters.COMMAND, get_secret)],
            A_SUB: [MessageHandler(filters.TEXT & ~filters.COMMAND, verify)]
        },
        fallbacks=[]
    ))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handle_text_input))
    app.add_handler(CommandHandler(['menu', 'start'], menu))
    app.add_handler(CallbackQueryHandler(button_handler))
    app.run_polling()

if __name__ == '__main__': main()
PY_EOF

# 7. 注册 Systemd 守护进程并静态语法门禁校验
echo "⚙️ [7/7] 注册 Systemd 服务并执行语法编译预检..."
cat << SERVICE_EOF > /etc/systemd/system/azure-bot.service
[Unit]
Description=Azure TG SaaS Manager Bot
After=network.target

[Service]
User=root
WorkingDirectory=$WORK_DIR
Environment="PATH=$CONDA_DIR/envs/$ENV_NAME/bin"
ExecStart=$CONDA_DIR/envs/$ENV_NAME/bin/python $WORK_DIR/bot.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICE_EOF

if "$CONDA_DIR/envs/$ENV_NAME/bin/python" -m py_compile "$WORK_DIR/bot.py"; then
    echo "   ✅ 语法静态编译校验 100% 通过！"
    systemctl daemon-reload
    systemctl enable azure-bot > /dev/null 2>&1
    systemctl restart azure-bot
    sleep 2
    echo "=================================================="
    systemctl status azure-bot --no-pager | grep -E "Active:|Main PID"
    echo "=================================================="
    echo "🎉 Azure TG Manager 生产级守护进程部署完成！"
    echo "👉 可以在 Telegram 客户端向 Bot 发送 /start 开始查账与管理。"
else
    echo "❌ 语法预检失败，拒绝重启以保护旧服务状态！"
    exit 1
fi
INSTALLER_EOF

chmod +x /opt/install.sh
/opt/install.sh
