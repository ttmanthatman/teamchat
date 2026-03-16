#!/bin/bash
#===============================================================================
# TeamChat 一键部署脚本 (全功能增强版 v7.1)
# 新增: Web Push 推送通知 + 置顶通知功能
#===============================================================================

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

trap 'echo -e "${RED}[致命错误] 部署中断！脚本在第 $LINENO 行执行失败${NC}"' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="/var/www/teamchat"

print_header() {
    echo -e "\n${CYAN}================================================${NC}"
    echo -e "${CYAN}  TeamChat 一键部署脚本 v7.1${NC}"
    echo -e "${CYAN}================================================${NC}\n"
}

print_menu() {
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}  请选择操作:${NC}"
    echo -e "${BLUE}================================================${NC}"
    echo -e "  ${GREEN}1${NC}. 安装/修复 (保留数据)"
    echo -e "  ${GREEN}2${NC}. 启动/重启服务"
    echo -e "  ${GREEN}3${NC}. 停止服务"
    echo -e "  ${GREEN}4${NC}. 查看运行日志"
    echo -e "  ${GREEN}5${NC}. 修改配置参数"
    echo -e "  ${GREEN}6${NC}. 配置 SSL/HTTPS"
    echo -e "  ${GREEN}7${NC}. 卸载程序"
    echo -e "  ${GREEN}0${NC}. 退出"
    echo -e "${BLUE}================================================${NC}"
    echo -n "请输入选项 [0-7]: "
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}错误: 请使用 sudo 或 root 用户运行此脚本！${NC}"
        exit 1
    fi
}

detect_os() {
    if [ -f /etc/os-release ]; then . /etc/os-release; OS=$ID; else OS="unknown"; fi
    echo "检测到操作系统: $OS"
}

validate_input() {
    local input="$1" field_name="$2"
    if [[ ! "$input" =~ ^[a-zA-Z0-9_.\-]+$ ]]; then
        echo -e "${RED}错误: ${field_name} 包含非法字符${NC}"; return 1
    fi
    return 0
}

get_admin_username() {
    if [ -f "$APP_DIR/database.sqlite" ] && command -v node >/dev/null 2>&1 && [ -d "$APP_DIR/node_modules" ]; then
        local admin_user
        admin_user=$(cd "$APP_DIR" && node -e "
const Database = require('better-sqlite3');
try {
  const db = new Database('$APP_DIR/database.sqlite');
  const user = db.prepare('SELECT username FROM users WHERE is_admin = 1 LIMIT 1').get();
  if (user) process.stdout.write(user.username);
} catch(e) {}
" 2>/dev/null)
        if [ -n "$admin_user" ]; then echo "$admin_user"; return 0; fi
    fi
    echo "admin"; return 0
}

get_current_port() {
    if [ -f "$APP_DIR/server.js" ]; then
        grep -oP 'const PORT = process\.env\.PORT \|\| \K\d+' "$APP_DIR/server.js" 2>/dev/null || echo "3000"
    else echo "3000"; fi
}

install_dependencies() {
    echo -e "${YELLOW}阶段 1/6: 正在安装系统依赖...${NC}"
    if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
        apt-get update -y
        apt-get install -y curl wget git build-essential python3 nginx certbot python3-certbot-nginx
    elif [ "$OS" = "centos" ] || [ "$OS" = "rhel" ] || [ "$OS" = "rocky" ] || [ "$OS" = "alma" ]; then
        yum install -y epel-release || true
        yum install -y curl wget git gcc-c++ make python3 nginx certbot python3-certbot-nginx
    else
        apt-get update -y
        apt-get install -y curl wget git build-essential python3 nginx certbot python3-certbot-nginx
    fi
    echo -e "${GREEN}✅ 系统依赖安装完成${NC}"
}

install_nodejs() {
    echo -e "\n${YELLOW}阶段 2/6: 检查并配置 Node.js 环境...${NC}"
    if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
        echo "正在安装 Node.js 20.x..."
        if [ "$OS" = "centos" ] || [ "$OS" = "rhel" ] || [ "$OS" = "rocky" ] || [ "$OS" = "alma" ]; then
            curl -fsSL https://rpm.nodesource.com/setup_20.x | bash - > /dev/null 2>&1; yum install -y nodejs
        else
            curl -fsSL https://deb.nodesource.com/setup_20.x | bash - > /dev/null 2>&1; apt-get install -y nodejs
        fi
    else
        local node_major; node_major=$(node -v | grep -oP '(?<=v)\d+')
        if [ "$node_major" -lt 18 ]; then
            echo -e "${YELLOW}Node.js 版本过低，正在升级...${NC}"
            if [ "$OS" = "centos" ] || [ "$OS" = "rhel" ] || [ "$OS" = "rocky" ] || [ "$OS" = "alma" ]; then
                curl -fsSL https://rpm.nodesource.com/setup_20.x | bash - > /dev/null 2>&1; yum install -y nodejs
            else
                curl -fsSL https://deb.nodesource.com/setup_20.x | bash - > /dev/null 2>&1; apt-get install -y nodejs
            fi
        else echo "✅ Node.js 已安装: $(node -v)"; fi
    fi
    if ! command -v pm2 >/dev/null 2>&1; then echo "正在安装 PM2..."; npm install -g pm2; else echo "✅ PM2 已安装"; fi
    echo -e "${GREEN}✅ Node.js 环境配置完成${NC}"
}

get_server_ip() {
    curl -s --connect-timeout 5 -4 ifconfig.me 2>/dev/null || \
    curl -s --connect-timeout 5 -4 ipinfo.io/ip 2>/dev/null || \
    curl -s --connect-timeout 5 -4 icanhazip.com 2>/dev/null || \
    hostname -I | awk '{print $1}'
}
get_local_ip() { hostname -I | awk '{print $1}'; }

show_ip_menu() {
    local public_ip local_ip
    public_ip=$(get_server_ip); local_ip=$(get_local_ip)
    echo "" >&2
    echo -e "${YELLOW}请选择 IP 地址:${NC}" >&2
    echo "  1. 公网 IP: $public_ip" >&2
    echo "  2. 内网 IP: $local_ip" >&2
    echo "  3. 手动输入" >&2
    printf "请选择 [1]: " >&2
    read -r ip_choice
    case $ip_choice in
        2) echo "$local_ip" ;;
        3) printf "请输入 IP 地址: " >&2; read -r custom_ip
           while [ -z "$custom_ip" ]; do printf "IP 不能为空: " >&2; read -r custom_ip; done
           echo "$custom_ip" ;;
        *) echo "$public_ip" ;;
    esac
}

#===============================================================================
# 写入前端文件
#===============================================================================

write_frontend_files() {
    echo "正在写入前端文件..."

    cat > "$APP_DIR/public/images/default-avatar.svg" <<'SVGEOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><circle cx="50" cy="50" r="50" fill="#667eea"/><circle cx="50" cy="38" r="16" fill="white"/><ellipse cx="50" cy="75" rx="28" ry="20" fill="white"/></svg>
SVGEOF

    # ===== PWA: manifest.json =====
    cat > "$APP_DIR/public/manifest.json" <<'MANIFESTEOF'
{
  "name": "TeamChat",
  "short_name": "TeamChat",
  "description": "团队聊天室",
  "start_url": "/",
  "display": "standalone",
  "background_color": "#667eea",
  "theme_color": "#667eea",
  "icons": [
    {
      "src": "/images/icon-192.png",
      "sizes": "192x192",
      "type": "image/png"
    },
    {
      "src": "/images/icon-512.png",
      "sizes": "512x512",
      "type": "image/png"
    }
  ]
}
MANIFESTEOF

    # 生成简易 PWA 图标 (SVG 转 inline，浏览器兼容)
    cat > "$APP_DIR/public/images/icon-192.svg" <<'ICONEOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 192 192"><rect width="192" height="192" rx="40" fill="#667eea"/><text x="96" y="120" font-size="90" text-anchor="middle" fill="white" font-family="Arial">💬</text></svg>
ICONEOF
    cp "$APP_DIR/public/images/icon-192.svg" "$APP_DIR/public/images/icon-512.svg"

    # 如果有 node+sharp 可以转 PNG，否则用 SVG 兼容
    if command -v node >/dev/null 2>&1; then
        cd "$APP_DIR" && node -e '
const fs = require("fs");
// 简单写一个 1x1 PNG 占位，浏览器会用 SVG fallback
const placeholder = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPj/HwADBwIAMCbHYQAAAABJRU5ErkJggg==","base64");
if (!fs.existsSync("public/images/icon-192.png")) fs.writeFileSync("public/images/icon-192.png", placeholder);
if (!fs.existsSync("public/images/icon-512.png")) fs.writeFileSync("public/images/icon-512.png", placeholder);
' 2>/dev/null || true
    fi

    # ===== Service Worker =====
    cat > "$APP_DIR/public/sw.js" <<'SWEOF'
// TeamChat Service Worker - 推送通知
self.addEventListener("push", function(event) {
  let data = { title: "TeamChat", body: "您有新消息", icon: "/images/icon-192.svg" };
  try {
    if (event.data) {
      const payload = event.data.json();
      data.title = payload.title || data.title;
      data.body = payload.body || data.body;
      data.icon = payload.icon || data.icon;
      data.data = payload.data || {};
    }
  } catch(e) {
    if (event.data) data.body = event.data.text();
  }

  const options = {
    body: data.body,
    icon: data.icon,
    badge: "/images/icon-192.svg",
    vibrate: [200, 100, 200],
    data: data.data || {},
    actions: [{ action: "open", title: "查看" }],
    tag: "teamchat-msg",
    renotify: true
  };

  event.waitUntil(
    self.registration.showNotification(data.title, options)
  );
});

self.addEventListener("notificationclick", function(event) {
  event.notification.close();
  event.waitUntil(
    clients.matchAll({ type: "window", includeUncontrolled: true }).then(function(clientList) {
      for (var i = 0; i < clientList.length; i++) {
        var client = clientList[i];
        if (client.url.indexOf(self.location.origin) !== -1 && "focus" in client) {
          return client.focus();
        }
      }
      if (clients.openWindow) return clients.openWindow("/");
    })
  );
});

// 基础缓存（让 PWA 可安装）
var CACHE_NAME = "teamchat-v1";
self.addEventListener("install", function(event) {
  self.skipWaiting();
});
self.addEventListener("activate", function(event) {
  event.waitUntil(clients.claim());
});
SWEOF

    # ===== index.html =====
    cat > "$APP_DIR/public/index.html" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover">
  <meta name="apple-mobile-web-app-capable" content="yes">
  <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
  <meta name="apple-mobile-web-app-title" content="TeamChat">
  <meta name="theme-color" content="#667eea">
  <link rel="manifest" href="/manifest.json">
  <link rel="apple-touch-icon" href="/images/icon-192.svg">
  <title>团队聊天室</title>
  <link rel="stylesheet" href="style.css?v=20260315a">
</head>
<body>
  <div id="loginPage" class="page">
    <div class="login-card">
      <h1 id="loginTitle">团队聊天室</h1>
      <form id="loginForm">
        <input type="text" id="loginUsername" placeholder="用户名" required>
        <input type="password" id="loginPassword" placeholder="密码" required>
        <button type="submit">登录</button>
      </form>
      <p id="loginError" class="error"></p>
    </div>
  </div>

  <div id="chatPage" class="page hidden">
    <header class="chat-header">
      <div class="header-left">
        <h2 id="chatTitle">团队聊天</h2>
        <span id="onlineCount">0 人在线</span>
      </div>
      <div class="header-right">
        <span id="currentUser"></span>
        <button onclick="showSettings()" class="icon-btn">⚙️</button>
        <button onclick="logout()" class="icon-btn">🚪</button>
      </div>
    </header>
    <!-- 置顶通知栏 -->
    <div id="noticeBar" class="notice-bar hidden">
      <div class="notice-bar-collapsed" onclick="toggleNoticeExpand()">
        <span class="notice-icon">📌</span>
        <span id="noticePreview" class="notice-preview">置顶通知</span>
        <span id="noticeToggleIcon" class="notice-toggle">▼</span>
      </div>
      <div id="noticeFullContent" class="notice-full hidden">
        <div id="noticeFullText" class="notice-full-text"></div>
      </div>
    </div>
    <div id="messages" class="messages"><div class="load-more" onclick="loadMoreMessages()">加载更多</div></div>
    <div class="input-area">
      <button onclick="document.getElementById('fileInput').click()" class="attach-btn">📎</button>
      <input type="file" id="fileInput" hidden onchange="handleFileUpload(this)">
      <input type="text" id="messageInput" placeholder="输入消息..." onkeypress="handleKeyPress(event)">
      <button onclick="sendMessage()" class="send-btn" id="sendBtn">发送</button>
    </div>
  </div>

  <!-- 设置弹窗 -->
  <div id="settingsModal" class="modal hidden">
    <div class="modal-content">
      <h3>设置</h3>
      <div class="settings-section">
        <h4>🔔 消息通知</h4>
        <div id="pushSection">
          <p id="pushStatus" style="font-size:13px;color:#666;margin-bottom:10px">检测中...</p>
          <button id="pushToggleBtn" onclick="togglePushNotification()" style="display:none">开启推送通知</button>
          <p id="pushIosHint" class="hidden" style="font-size:12px;color:#e67e22;margin-top:8px">
            📱 iOS 用户：请先点击 Safari 底部的"分享"按钮 → "添加到主屏幕"，然后从主屏幕打开才能收到推送通知。
          </p>
        </div>
      </div>
      <div class="settings-section">
        <h4>上传头像</h4>
        <div class="avatar-upload">
          <img id="currentAvatar" src="/images/default-avatar.svg" alt="头像" class="avatar-preview">
          <input type="file" id="avatarInput" accept="image/*" onchange="handleAvatarUpload(this)">
          <button onclick="document.getElementById('avatarInput').click()">选择图片</button>
        </div>
        <p id="avatarMsg"></p>
      </div>
      <div class="settings-section">
        <h4>修改密码</h4>
        <input type="password" id="oldPassword" placeholder="原密码">
        <input type="password" id="newPassword" placeholder="新密码 (至少6位)">
        <button onclick="changePassword()">确认修改</button>
        <p id="passwordMsg"></p>
      </div>
      <div class="settings-section admin-section hidden" id="adminSection">
        <h4>管理功能</h4>
        <div class="timezone-setting">
          <label for="timezoneSelect">消息时间时区:</label>
          <select id="timezoneSelect" onchange="saveTimezone()">
            <option value="Asia/Shanghai">中国标准时间 (UTC+8)</option>
            <option value="Asia/Tokyo">日本标准时间 (UTC+9)</option>
            <option value="Asia/Singapore">新加坡时间 (UTC+8)</option>
            <option value="Asia/Kolkata">印度标准时间 (UTC+5:30)</option>
            <option value="Asia/Dubai">海湾标准时间 (UTC+4)</option>
            <option value="Europe/London">英国时间 (UTC+0/+1)</option>
            <option value="Europe/Paris">中欧时间 (UTC+1/+2)</option>
            <option value="Europe/Moscow">莫斯科时间 (UTC+3)</option>
            <option value="America/New_York">美国东部时间 (UTC-5/-4)</option>
            <option value="America/Chicago">美国中部时间 (UTC-6/-5)</option>
            <option value="America/Denver">美国山地时间 (UTC-7/-6)</option>
            <option value="America/Los_Angeles">美国太平洋时间 (UTC-8/-7)</option>
            <option value="Pacific/Auckland">新西兰时间 (UTC+12/+13)</option>
            <option value="Australia/Sydney">澳洲东部时间 (UTC+10/+11)</option>
          </select>
          <p id="timezoneMsg" style="font-size:12px;color:#666;margin-top:4px"></p>
        </div>
        <button onclick="showNoticeAdmin()" class="admin-btn">📌 置顶通知</button>
        <button onclick="showAppearance()" class="admin-btn">🎨 外观定制</button>
        <button onclick="showUserManagement()" class="admin-btn">👥 用户管理</button>
        <button onclick="showBackup()" class="admin-btn">💾 备份/还原</button>
        <button onclick="showDeleteMessages()" class="admin-btn danger">🗑️ 删除记录</button>
      </div>
      <button onclick="closeSettings()" class="close-btn">关闭</button>
    </div>
  </div>

  <!-- 置顶通知管理弹窗 -->
  <div id="noticeModal" class="modal hidden">
    <div class="modal-content">
      <h3>📌 置顶通知管理</h3>
      <div class="settings-section">
        <label class="field-label">通知内容</label>
        <textarea id="noticeContentInput" placeholder="输入置顶通知内容..." rows="5" style="width:100%;padding:12px;border:1px solid #ddd;border-radius:8px;font-size:14px;resize:vertical;font-family:inherit"></textarea>
      </div>
      <button onclick="saveNotice()" style="background:#667eea">发布置顶通知</button>
      <button onclick="clearNotice()" class="danger-btn">撤下置顶通知</button>
      <p id="noticeMsg" style="text-align:center;margin-top:8px;font-size:13px"></p>
      <button onclick="closeNoticeModal()" class="close-btn">关闭</button>
    </div>
  </div>

  <!-- 外观定制弹窗 -->
  <div id="appearanceModal" class="modal hidden">
    <div class="modal-content modal-wide">
      <h3>🎨 外观定制</h3>
      <div class="settings-section">
        <h4>名称设置</h4>
        <label class="field-label">登录页标题</label>
        <input type="text" id="appLoginTitle" placeholder="团队聊天室" maxlength="30">
        <label class="field-label">聊天室标题</label>
        <input type="text" id="appChatTitle" placeholder="团队聊天" maxlength="30">
      </div>
      <div class="settings-section">
        <h4>发送按钮</h4>
        <label class="field-label">按钮文字</label>
        <input type="text" id="appSendText" placeholder="发送" maxlength="10">
        <label class="field-label">按钮颜色</label>
        <div class="color-row">
          <input type="color" id="appSendColor" value="#667eea">
          <span id="appSendColorHex" class="color-hex">#667eea</span>
        </div>
      </div>
      <div class="settings-section">
        <h4>聊天背景</h4>
        <label class="field-label">背景类型</label>
        <div class="radio-group">
          <label><input type="radio" name="bgType" value="color" checked onchange="toggleBgType()"> 纯色</label>
          <label><input type="radio" name="bgType" value="image" onchange="toggleBgType()"> 图片</label>
        </div>
        <div id="bgColorSection">
          <label class="field-label">背景颜色</label>
          <div class="color-row">
            <input type="color" id="appBgColor" value="#f5f5f5">
            <span id="appBgColorHex" class="color-hex">#f5f5f5</span>
          </div>
        </div>
        <div id="bgImageSection" class="hidden">
          <label class="field-label">背景图片</label>
          <div class="bg-preview-area">
            <img id="bgPreview" src="" alt="预览" class="bg-preview hidden">
            <span id="bgFileName" class="bg-filename">未选择图片</span>
          </div>
          <input type="file" id="bgImageInput" accept="image/*" style="display:none" onchange="handleBgImageUpload(this)">
          <button onclick="document.getElementById('bgImageInput').click()" class="admin-btn" style="margin-top:8px">选择图片</button>
          <label class="field-label" style="margin-top:12px">显示方式</label>
          <select id="appBgMode">
            <option value="cover">填充 (cover)</option>
            <option value="contain">适应 (contain)</option>
            <option value="stretch">拉伸 (stretch)</option>
            <option value="tile">平铺 (tile)</option>
          </select>
        </div>
      </div>
      <div class="settings-section" style="border-bottom:none">
        <div id="bgLivePreview" class="live-preview">
          <div class="preview-label">实时预览</div>
          <div id="previewArea" class="preview-messages">
            <div class="preview-bubble left">大家好！</div>
            <div class="preview-bubble right">你好呀 👋</div>
          </div>
        </div>
      </div>
      <button onclick="saveAppearance()" class="save-appear-btn">💾 保存并应用</button>
      <p id="appearanceMsg"></p>
      <button onclick="closeAppearance()" class="close-btn">关闭</button>
    </div>
  </div>

  <!-- 用户管理弹窗 -->
  <div id="userModal" class="modal hidden">
    <div class="modal-content">
      <h3>用户管理</h3>
      <div class="add-user">
        <input type="text" id="newUsername" placeholder="新用户名">
        <input type="password" id="newUserPassword" placeholder="初始密码 (至少6位)">
        <input type="text" id="newUserNickname" placeholder="昵称">
        <button onclick="addUser()">添加用户</button>
      </div>
      <div id="userList" class="user-list"></div>
      <div class="settings-section" style="margin-top:16px">
        <h4>批量导入/导出用户</h4>
        <button onclick="exportUsers()" class="admin-btn">📤 导出用户数据</button>
        <input type="file" id="importUsersFile" accept=".json" style="display:none" onchange="importUsers(this)">
        <button onclick="document.getElementById('importUsersFile').click()" class="admin-btn">📥 导入用户数据</button>
        <p id="userImportMsg" style="font-size:13px;color:#666;margin-top:8px"></p>
      </div>
      <button onclick="closeUserModal()" class="close-btn">关闭</button>
    </div>
  </div>

  <div id="backupModal" class="modal hidden">
    <div class="modal-content">
      <h3>备份与还原</h3>
      <div class="settings-section"><h4>导出备份</h4>
        <input type="date" id="backupStart"><input type="date" id="backupEnd">
        <button onclick="exportBackup()">下载备份</button></div>
      <div class="settings-section"><h4>还原备份</h4>
        <input type="file" id="restoreFile" accept=".json">
        <button onclick="restoreBackup()">还原</button></div>
      <p id="backupMsg"></p>
      <button onclick="closeBackupModal()" class="close-btn">关闭</button>
    </div>
  </div>

  <div id="deleteModal" class="modal hidden">
    <div class="modal-content">
      <h3>删除聊天记录</h3>
      <p class="danger-text">⚠️ 此操作不可恢复！</p>
      <input type="date" id="deleteStart"><input type="date" id="deleteEnd">
      <button onclick="deleteMessages()" class="danger-btn">确认删除</button>
      <p id="deleteMsg"></p>
      <button onclick="closeDeleteModal()" class="close-btn">关闭</button>
    </div>
  </div>

  <div id="imageModal" class="modal hidden" onclick="this.classList.add('hidden')">
    <img id="previewImage" src="" alt="预览">
  </div>

  <script src="https://cdn.socket.io/4.7.2/socket.io.min.js"></script>
  <script src="app.js?v=20260315a"></script>
</body>
</html>
HTMLEOF

    # ===== style.css =====
    cat > "$APP_DIR/public/style.css" <<'CSSEOF'
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;background:#f5f5f5;height:100vh;overflow:hidden}
.page{width:100%;height:100vh;display:flex;flex-direction:column}
.hidden{display:none!important}
#loginPage{justify-content:center;align-items:center;background:linear-gradient(135deg,#667eea 0%,#764ba2 100%)}
.login-card{background:#fff;padding:40px;border-radius:16px;box-shadow:0 10px 40px rgba(0,0,0,.2);width:90%;max-width:400px}
.login-card h1{text-align:center;margin-bottom:30px;color:#333}
.login-card input{width:100%;padding:14px;margin-bottom:16px;border:1px solid #ddd;border-radius:8px;font-size:16px}
.login-card button{width:100%;padding:14px;background:#667eea;color:#fff;border:none;border-radius:8px;font-size:16px;cursor:pointer;margin-bottom:10px}
.error{color:#dc2626;text-align:center;margin-top:10px;font-size:14px}
#chatPage{background:#f5f5f5}
.chat-header{background:#fff;padding:12px 16px;display:flex;justify-content:space-between;align-items:center;box-shadow:0 2px 8px rgba(0,0,0,.1);flex-shrink:0}
.header-left h2{font-size:18px;color:#333}.header-left span{font-size:12px;color:#666}
.header-right{display:flex;align-items:center;gap:10px}.header-right span{font-size:14px;color:#667eea}
.icon-btn{background:none;border:none;font-size:20px;cursor:pointer;padding:5px}
/* 置顶通知栏 */
.notice-bar{flex-shrink:0;background:linear-gradient(135deg,#fff8e1 0%,#fff3c4 100%);border-bottom:1px solid #f0d060;box-shadow:0 2px 6px rgba(0,0,0,.06);z-index:10;overflow:hidden;transition:all .3s ease}
.notice-bar-collapsed{display:flex;align-items:center;padding:10px 16px;cursor:pointer;gap:8px;min-height:42px}
.notice-icon{font-size:16px;flex-shrink:0}
.notice-preview{flex:1;font-size:13px;color:#8b6914;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-weight:500}
.notice-toggle{font-size:10px;color:#b8860b;flex-shrink:0;transition:transform .3s ease}
.notice-toggle.expanded{transform:rotate(180deg)}
.notice-full{padding:0 16px 12px 40px;animation:noticeSlideDown .25s ease}
.notice-full-text{font-size:14px;color:#5d4e14;line-height:1.7;white-space:pre-wrap;word-break:break-word;max-height:200px;overflow-y:auto;padding:8px 12px;background:rgba(255,255,255,.5);border-radius:8px}
@keyframes noticeSlideDown{from{opacity:0;max-height:0}to{opacity:1;max-height:300px}}
.messages{flex:1;overflow-y:auto;padding:16px;display:flex;flex-direction:column;gap:12px;min-height:0;background-color:#f5f5f5;background-position:center;transition:background-color .3s}
.load-more{text-align:center;padding:12px;color:#667eea;cursor:pointer;background:rgba(255,255,255,.85);border-radius:8px;margin-bottom:10px}
.message{max-width:75%;padding:10px 14px;border-radius:16px;position:relative;word-wrap:break-word;display:flex;gap:10px;align-items:flex-start}
.message.my{align-self:flex-end;background:#667eea;color:#fff;border-bottom-right-radius:4px}
.message.other{align-self:flex-start;background:#fff;color:#333;border-bottom-left-radius:4px;box-shadow:0 1px 3px rgba(0,0,0,.1)}
.message-avatar{width:36px;height:36px;border-radius:50%;object-fit:cover;flex-shrink:0}
.message-body{flex:1;min-width:0}
.message .sender{font-size:12px;font-weight:600;margin-bottom:2px;opacity:.8}
.message .time{font-size:10px;opacity:.6;display:block;text-align:right;margin-top:6px;white-space:nowrap}
.message img.chat-image{max-width:200px;max-height:200px;border-radius:8px;cursor:pointer;margin-top:8px}
.message .file{display:flex;align-items:center;gap:8px;padding:8px 12px;background:rgba(0,0,0,.05);border-radius:8px;margin-top:8px;cursor:pointer}
.message a{color:inherit;text-decoration:underline}
.input-area{background:#fff;padding:12px 16px;display:flex;gap:10px;align-items:center;box-shadow:0 -2px 8px rgba(0,0,0,.05);flex-shrink:0}
.input-area input[type="text"]{flex:1;padding:12px 16px;border:1px solid #ddd;border-radius:24px;font-size:15px;outline:none}
.attach-btn,.send-btn{height:44px;border-radius:22px;border:none;font-size:15px;cursor:pointer;display:flex;align-items:center;justify-content:center}
.attach-btn{width:44px;background:#f0f0f0;font-size:20px}.send-btn{min-width:44px;padding:0 18px;background:#667eea;color:#fff;font-weight:500;white-space:nowrap}
.reply-box{background:#f0f2ff;padding:8px 16px;display:flex;align-items:center;gap:8px;font-size:13px;color:#555;border-left:3px solid #667eea}
.reply-box .reply-label{font-weight:600;color:#667eea;white-space:nowrap}
.reply-box .reply-content{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.reply-box .reply-cancel{background:none;border:none;font-size:16px;cursor:pointer;color:#999;padding:0 4px;width:auto;min-width:24px}
.reply-preview{background:rgba(0,0,0,.06);padding:4px 8px;border-radius:6px;margin-bottom:4px;font-size:12px;border-left:2px solid #667eea;color:#666;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.reply-preview .reply-name{font-weight:600}
.message-menu{background:#fff;border-radius:8px;box-shadow:0 4px 16px rgba(0,0,0,.15);z-index:2000;overflow:hidden;min-width:140px}
.message-menu .menu-item{padding:10px 16px;cursor:pointer;font-size:14px;transition:background .15s}
.message-menu .menu-item:hover{background:#f0f2ff}
.modal{position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,.5);display:flex;justify-content:center;align-items:center;z-index:1000}
.modal-content{background:#fff;padding:24px;border-radius:16px;width:90%;max-width:450px;max-height:80vh;overflow-y:auto}
.modal-wide{max-width:520px}
.modal-content h3{margin-bottom:20px;text-align:center}
.modal-content h4{margin:16px 0 10px;font-size:14px;color:#666}
.modal-content input[type="text"],.modal-content input[type="password"],.modal-content input[type="date"],.modal-content select{width:100%;padding:12px;margin-bottom:10px;border:1px solid #ddd;border-radius:8px;font-size:14px}
.modal-content button{width:100%;padding:12px;background:#667eea;color:#fff;border:none;border-radius:8px;font-size:14px;cursor:pointer;margin-bottom:10px}
.modal-content button.danger{background:#dc2626}.modal-content button.admin-btn{background:#10b981}
.close-btn{background:#f0f0f0!important;color:#333!important}
.danger-btn{width:100%;padding:12px;background:#dc2626;color:#fff;border:none;border-radius:8px;font-size:14px;cursor:pointer;margin-bottom:10px}
.danger-text{color:#dc2626;text-align:center;margin-bottom:16px}
.settings-section{margin-bottom:20px;padding-bottom:20px;border-bottom:1px solid #eee}
.field-label{display:block;font-size:13px;color:#555;margin-bottom:6px;font-weight:500}
.timezone-setting{margin-bottom:14px}.timezone-setting label{display:block;font-size:13px;color:#555;margin-bottom:6px}
.timezone-setting select{width:100%;padding:10px;border:1px solid #ddd;border-radius:8px;font-size:14px;background:#fff}
.add-user{display:flex;flex-direction:column;gap:8px;margin-bottom:16px}
.user-list{max-height:200px;overflow-y:auto}
.user-item{display:flex;justify-content:space-between;align-items:center;padding:10px;background:#f9f9f9;border-radius:8px;margin-bottom:8px}
.user-item .username{font-weight:600}.user-item .nickname{font-size:12px;color:#666}
.user-item .delete-btn{background:#dc2626;color:#fff;border:none;padding:6px 12px;border-radius:6px;cursor:pointer;font-size:12px}
.avatar-upload{display:flex;flex-direction:column;align-items:center;gap:10px}
.avatar-preview{width:80px;height:80px;border-radius:50%;object-fit:cover;border:2px solid #ddd}
#avatarInput{display:none}
.color-row{display:flex;align-items:center;gap:12px;margin-bottom:10px}
.color-row input[type="color"]{width:50px;height:40px;border:1px solid #ddd;border-radius:8px;padding:2px;cursor:pointer}
.color-hex{font-size:13px;color:#666;font-family:monospace}
.radio-group{display:flex;gap:20px;margin-bottom:12px}
.radio-group label{display:flex;align-items:center;gap:6px;font-size:14px;color:#555;cursor:pointer}
.bg-preview-area{display:flex;align-items:center;gap:10px;margin-bottom:8px}
.bg-preview{width:80px;height:60px;object-fit:cover;border-radius:8px;border:1px solid #ddd}
.bg-filename{font-size:13px;color:#888}
.save-appear-btn{background:#667eea!important;font-size:15px!important;padding:14px!important}
.live-preview{border:1px solid #ddd;border-radius:12px;overflow:hidden}
.preview-label{background:#f9f9f9;padding:8px 12px;font-size:12px;color:#999;text-align:center;border-bottom:1px solid #eee}
.preview-messages{padding:16px;min-height:100px;display:flex;flex-direction:column;gap:10px;background-color:#f5f5f5;background-position:center;transition:background-color .3s}
.preview-bubble{padding:8px 14px;border-radius:14px;font-size:13px;max-width:70%}
.preview-bubble.left{align-self:flex-start;background:#fff;color:#333;box-shadow:0 1px 2px rgba(0,0,0,.1)}
.preview-bubble.right{align-self:flex-end;background:#667eea;color:#fff}
#imageModal{cursor:zoom-out}#imageModal img{max-width:90vw;max-height:90vh;border-radius:8px}
.avatar-wrapper{position:relative;display:inline-block;flex-shrink:0}
.avatar-wrapper .message-avatar{width:36px;height:36px;border-radius:50%;object-fit:cover}
.online-dot{position:absolute;bottom:0;right:0;width:10px;height:10px;border-radius:50%;background:#22c55e;border:2px solid #fff;display:none}
.online-dot.online{display:block}
.kicked-overlay{position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,.7);display:flex;justify-content:center;align-items:center;z-index:9999}
.kicked-overlay .kicked-card{background:#fff;padding:32px;border-radius:16px;text-align:center;max-width:360px;width:90%}
.kicked-overlay .kicked-card h3{margin-bottom:12px;color:#dc2626}
.kicked-overlay .kicked-card p{margin-bottom:20px;color:#666;font-size:14px}
.kicked-overlay .kicked-card button{padding:12px 32px;background:#667eea;color:#fff;border:none;border-radius:8px;font-size:14px;cursor:pointer}
@media(min-width:768px){.message{max-width:60%}.message img.chat-image{max-width:300px;max-height:300px}}
@media screen and (max-width:768px){.page{height:100dvh}body{height:100dvh}}
CSSEOF

    # ===== app.js =====
    cat > "$APP_DIR/public/app.js" <<'APPEOF'
const API_BASE='';
let currentUser=null,socket=null,oldestMessageId=null,isLoading=false;
let replyingToMsg=null,onlineUsernames=new Set(),chatTimezone='Asia/Shanghai',appearanceData={};
let pushSubscription=null;
let noticeExpanded=false;

function escapeHtml(t){const d=document.createElement('div');d.appendChild(document.createTextNode(t));return d.innerHTML}
function escapeAttr(t){return String(t).replace(/&/g,'&amp;').replace(/"/g,'&quot;').replace(/'/g,'&#39;').replace(/</g,'&lt;').replace(/>/g,'&gt;')}
function authHeaders(x){const h={'Authorization':'Bearer '+(currentUser?currentUser.token:'')};return Object.assign(h,x||{})}

// ===== 置顶通知 =====
async function loadNotice(){
  try{
    const r=await fetch(API_BASE+'/api/settings/notice');
    if(!r.ok)return;
    const d=await r.json();
    applyNotice(d);
  }catch(e){}
}

function applyNotice(d){
  const bar=document.getElementById('noticeBar');
  if(d&&d.enabled&&d.content&&d.content.trim()){
    document.getElementById('noticePreview').textContent=d.content.replace(/\n/g,' ').substring(0,60)+(d.content.length>60?'...':'');
    document.getElementById('noticeFullText').textContent=d.content;
    bar.classList.remove('hidden');
    noticeExpanded=false;
    document.getElementById('noticeFullContent').classList.add('hidden');
    document.getElementById('noticeToggleIcon').classList.remove('expanded');
  }else{
    bar.classList.add('hidden');
  }
}

function toggleNoticeExpand(){
  noticeExpanded=!noticeExpanded;
  const full=document.getElementById('noticeFullContent');
  const icon=document.getElementById('noticeToggleIcon');
  if(noticeExpanded){full.classList.remove('hidden');icon.classList.add('expanded')}
  else{full.classList.add('hidden');icon.classList.remove('expanded')}
}

function showNoticeAdmin(){
  // 加载当前通知内容
  fetch(API_BASE+'/api/settings/notice').then(r=>r.json()).then(d=>{
    document.getElementById('noticeContentInput').value=d.content||'';
  }).catch(()=>{});
  document.getElementById('noticeMsg').textContent='';
  document.getElementById('noticeModal').classList.remove('hidden');
}
function closeNoticeModal(){document.getElementById('noticeModal').classList.add('hidden')}

async function saveNotice(){
  const content=document.getElementById('noticeContentInput').value.trim();
  const m=document.getElementById('noticeMsg');
  if(!content){m.textContent='请输入通知内容';m.style.color='#dc2626';return}
  try{
    const r=await fetch(API_BASE+'/api/settings/notice',{method:'POST',headers:authHeaders({'Content-Type':'application/json'}),body:JSON.stringify({content:content,enabled:true})});
    const d=await r.json();
    if(d.success){m.textContent='✅ 置顶通知已发布';m.style.color='#10b981';setTimeout(()=>{m.textContent=''},3000)}
    else{m.textContent=d.message||'保存失败';m.style.color='#dc2626'}
  }catch(e){m.textContent='保存失败';m.style.color='#dc2626'}
}

async function clearNotice(){
  const m=document.getElementById('noticeMsg');
  try{
    const r=await fetch(API_BASE+'/api/settings/notice',{method:'POST',headers:authHeaders({'Content-Type':'application/json'}),body:JSON.stringify({content:'',enabled:false})});
    const d=await r.json();
    if(d.success){document.getElementById('noticeContentInput').value='';m.textContent='✅ 置顶通知已撤下';m.style.color='#10b981';setTimeout(()=>{m.textContent=''},3000)}
    else{m.textContent=d.message||'操作失败';m.style.color='#dc2626'}
  }catch(e){m.textContent='操作失败';m.style.color='#dc2626'}
}

// ===== 推送通知 =====
let swRegistration=null;

async function initServiceWorker(){
  if(!('serviceWorker' in navigator)){console.log('SW not supported');return}
  try{
    swRegistration=await navigator.serviceWorker.register('/sw.js');
    console.log('Service Worker registered');
  }catch(e){console.error('SW registration failed:',e)}
}

function detectPushSupport(){
  const statusEl=document.getElementById('pushStatus');
  const btnEl=document.getElementById('pushToggleBtn');
  const iosHint=document.getElementById('pushIosHint');
  const isIos=/iPad|iPhone|iPod/.test(navigator.userAgent);
  const isStandalone=window.matchMedia('(display-mode: standalone)').matches||navigator.standalone;

  if(!('serviceWorker' in navigator)||!('PushManager' in window)){
    statusEl.textContent='您的浏览器不支持推送通知';
    if(isIos&&!isStandalone)iosHint.classList.remove('hidden');
    return;
  }
  if(isIos&&!isStandalone){
    statusEl.textContent='iOS 需要添加到主屏幕后才能推送';
    iosHint.classList.remove('hidden');
    btnEl.style.display='block';
    btnEl.textContent='尝试开启推送';
    return;
  }
  checkCurrentSubscription();
}

async function checkCurrentSubscription(){
  const statusEl=document.getElementById('pushStatus');
  const btnEl=document.getElementById('pushToggleBtn');
  if(!swRegistration){await initServiceWorker()}
  if(!swRegistration)return;
  try{
    const sub=await swRegistration.pushManager.getSubscription();
    if(sub){
      pushSubscription=sub;
      statusEl.textContent='✅ 推送通知已开启';
      btnEl.style.display='block';
      btnEl.textContent='关闭推送通知';
      btnEl.className='';
      btnEl.style.background='#dc2626';
      btnEl.style.color='#fff';
      btnEl.style.border='none';
      btnEl.style.borderRadius='8px';
      btnEl.style.padding='12px';
      btnEl.style.width='100%';
      btnEl.style.cursor='pointer';
    }else{
      statusEl.textContent='推送通知未开启';
      btnEl.style.display='block';
      btnEl.textContent='开启推送通知';
      btnEl.style.background='#667eea';
      btnEl.style.color='#fff';
      btnEl.style.border='none';
      btnEl.style.borderRadius='8px';
      btnEl.style.padding='12px';
      btnEl.style.width='100%';
      btnEl.style.cursor='pointer';
    }
  }catch(e){statusEl.textContent='检测推送状态失败'}
}

async function togglePushNotification(){
  if(pushSubscription){
    try{
      await pushSubscription.unsubscribe();
      await fetch(API_BASE+'/api/push/unsubscribe',{
        method:'POST',
        headers:authHeaders({'Content-Type':'application/json'}),
        body:JSON.stringify({endpoint:pushSubscription.endpoint})
      });
      pushSubscription=null;
      checkCurrentSubscription();
    }catch(e){alert('取消推送失败')}
  }else{
    try{
      const keyRes=await fetch(API_BASE+'/api/push/vapid-key');
      const keyData=await keyRes.json();
      if(!keyData.publicKey){alert('服务器推送未配置');return}

      const permission=await Notification.requestPermission();
      if(permission!=='granted'){
        document.getElementById('pushStatus').textContent='您拒绝了通知权限，请在浏览器设置中允许';
        return;
      }

      if(!swRegistration)await initServiceWorker();
      const sub=await swRegistration.pushManager.subscribe({
        userVisibleOnly:true,
        applicationServerKey:urlBase64ToUint8Array(keyData.publicKey)
      });

      await fetch(API_BASE+'/api/push/subscribe',{
        method:'POST',
        headers:authHeaders({'Content-Type':'application/json'}),
        body:JSON.stringify({subscription:sub.toJSON()})
      });

      pushSubscription=sub;
      checkCurrentSubscription();
    }catch(e){
      console.error('Push subscribe error:',e);
      document.getElementById('pushStatus').textContent='开启推送失败: '+e.message;
    }
  }
}

function urlBase64ToUint8Array(base64String){
  const padding='='.repeat((4-base64String.length%4)%4);
  const base64=(base64String+padding).replace(/-/g,'+').replace(/_/g,'/');
  const rawData=window.atob(base64);
  const outputArray=new Uint8Array(rawData.length);
  for(let i=0;i<rawData.length;++i)outputArray[i]=rawData.charCodeAt(i);
  return outputArray;
}

// ===== 页面加载 =====
document.addEventListener('DOMContentLoaded',async()=>{
  await initServiceWorker();
  await loadAppearancePublic();
  await loadNotice();
  const token=localStorage.getItem('token');
  const username=localStorage.getItem('username');
  if(token&&username){
    currentUser={username,token,userId:parseInt(localStorage.getItem('userId')),
      isAdmin:localStorage.getItem('isAdmin')==='true',
      nickname:localStorage.getItem('nickname'),avatar:localStorage.getItem('avatar')};
    initChat();
  }
});

async function loadAppearancePublic(){
  try{const r=await fetch(API_BASE+'/api/settings/appearance');if(r.ok){const d=await r.json();appearanceData=d;applyAppearance(d)}}catch(e){}
}

function applyAppearance(d){
  if(!d)return;
  if(d.login_title)document.getElementById('loginTitle').textContent=d.login_title;
  if(d.chat_title){document.getElementById('chatTitle').textContent=d.chat_title;document.title=d.chat_title}
  const sendBtn=document.getElementById('sendBtn');
  if(d.send_text)sendBtn.textContent=d.send_text;
  if(d.send_color)sendBtn.style.background=d.send_color;
  const msgEl=document.getElementById('messages');
  if(d.bg_type==='image'&&d.bg_image){
    applyBgToElement(msgEl,'image',d.bg_color,API_BASE+'/backgrounds/'+encodeURIComponent(d.bg_image),d.bg_mode);
  }else{applyBgToElement(msgEl,'color',d.bg_color||'#f5f5f5','','')}
  if(d.timezone){chatTimezone=d.timezone;const sel=document.getElementById('timezoneSelect');if(sel)sel.value=chatTimezone}
}

function applyBgToElement(el,type,color,url,mode){
  if(type==='image'&&url){
    el.style.backgroundColor=color||'#f5f5f5';el.style.backgroundImage='url('+url+')';el.style.backgroundPosition='center';
    switch(mode){case 'tile':el.style.backgroundSize='auto';el.style.backgroundRepeat='repeat';break;case 'stretch':el.style.backgroundSize='100% 100%';el.style.backgroundRepeat='no-repeat';break;case 'contain':el.style.backgroundSize='contain';el.style.backgroundRepeat='no-repeat';break;default:el.style.backgroundSize='cover';el.style.backgroundRepeat='no-repeat'}
  }else{el.style.backgroundImage='none';el.style.backgroundColor=color||'#f5f5f5'}
}

function showLogin(){document.getElementById('loginPage').classList.remove('hidden');document.getElementById('chatPage').classList.add('hidden')}

document.getElementById('loginForm').addEventListener('submit',async(e)=>{
  e.preventDefault();
  const username=document.getElementById('loginUsername').value,password=document.getElementById('loginPassword').value;
  try{
    const r=await fetch(API_BASE+'/api/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username,password})});
    const d=await r.json();
    if(d.success){
      localStorage.setItem('token',d.token);localStorage.setItem('username',d.username);
      localStorage.setItem('userId',d.userId);localStorage.setItem('isAdmin',d.isAdmin?'true':'false');
      localStorage.setItem('nickname',d.nickname||'');localStorage.setItem('avatar',d.avatar||'');
      currentUser={username:d.username,token:d.token,userId:d.userId,nickname:d.nickname,avatar:d.avatar,isAdmin:d.isAdmin};
      initChat();
    }else{document.getElementById('loginError').textContent=d.message}
  }catch(err){document.getElementById('loginError').textContent='登录失败，请重试'}
});

function getAvatarUrl(a){return a?API_BASE+'/avatars/'+encodeURIComponent(a):API_BASE+'/images/default-avatar.svg'}

function initChat(){
  document.getElementById('loginPage').classList.add('hidden');
  document.getElementById('chatPage').classList.remove('hidden');
  document.getElementById('currentUser').textContent=currentUser.nickname||currentUser.username;
  document.getElementById('currentAvatar').src=getAvatarUrl(currentUser.avatar);
  if(currentUser.isAdmin)document.getElementById('adminSection').classList.remove('hidden');
  loadTimezone();
  loadNotice();
  detectPushSupport();

  socket=io({auth:{token:currentUser.token}});
  socket.on('connect_error',(err)=>{if(err.message==='认证失败'||err.message==='未提供认证信息'){alert('登录已过期');logout()}});
  socket.on('newMessage',(msg)=>appendMessage(msg));
  socket.on('onlineUsers',(users)=>{
    document.getElementById('onlineCount').textContent=users.length+' 人在线: '+users.map(u=>u.nickname||u.username).join(', ');
    onlineUsernames=new Set(users.map(u=>u.username));updateOnlineDots();
  });
  socket.on('kicked',(d)=>showKickedOverlay(d.message||'您的账号已在其他设备登录'));
  socket.on('timezoneChanged',(d)=>{if(d.timezone){chatTimezone=d.timezone;const s=document.getElementById('timezoneSelect');if(s)s.value=chatTimezone;refreshMessageTimes()}});
  socket.on('appearanceChanged',(d)=>{appearanceData=d;applyAppearance(d)});
  socket.on('noticeChanged',(d)=>{applyNotice(d)});
  loadMessages();
}

function showKickedOverlay(msg){
  if(socket){socket.disconnect();socket=null}
  const o=document.createElement('div');o.className='kicked-overlay';
  o.innerHTML='<div class="kicked-card"><h3>⚠️ 账号已下线</h3><p>'+escapeHtml(msg)+'</p><button onclick="kickedRelogin()">重新登录</button></div>';
  document.body.appendChild(o);
}
function kickedRelogin(){const o=document.querySelector('.kicked-overlay');if(o)o.remove();logout()}

async function loadMessages(){
  if(isLoading)return;isLoading=true;
  try{
    let url=API_BASE+'/api/messages?limit=50';if(oldestMessageId)url+='&before='+oldestMessageId;
    const r=await fetch(url,{headers:authHeaders()});if(r.status===401){logout();return}
    const msgs=await r.json();
    if(msgs.length>0){const c=document.getElementById('messages');msgs.forEach(m=>appendMessage(m,!!oldestMessageId));oldestMessageId=msgs[0].id;if(msgs.length<50){const l=c.querySelector('.load-more');if(l)l.style.display='none'}}
  }catch(e){console.error('加载消息失败:',e)}
  isLoading=false;
}
function loadMoreMessages(){loadMessages()}

function updateOnlineDots(){
  document.getElementById('messages').querySelectorAll('.message[data-message-id]').forEach(div=>{
    const msg=messageCache.get(parseInt(div.dataset.messageId));if(!msg)return;
    const dot=div.querySelector('.online-dot');if(!dot)return;
    if(onlineUsernames.has(msg.username))dot.classList.add('online');else dot.classList.remove('online');
  });
}

const messageCache=new Map();

function appendMessage(message,prepend){
  if(messageCache.has(message.id)&&document.querySelector('[data-message-id="'+message.id+'"]'))return;
  const container=document.getElementById('messages');
  const isMy=message.username===currentUser.username;
  const div=document.createElement('div');div.className='message '+(isMy?'my':'other');div.dataset.messageId=message.id;
  messageCache.set(message.id,message);
  div.addEventListener('contextmenu',(e)=>{e.preventDefault();showMessageMenu(e,message)});
  const time=new Date(message.created_at).toLocaleString('zh-CN',{timeZone:chatTimezone,year:'numeric',month:'long',day:'numeric',hour:'2-digit',minute:'2-digit',second:'2-digit'});
  const displayName=escapeHtml(message.nickname||message.username);
  const avatarUrl=getAvatarUrl(message.avatar);
  const isOnline=onlineUsernames.has(message.username);
  let content='';
  if(message.type==='text'){const s=escapeHtml(message.content);content=s.replace(/(https?:\/\/[^\s&lt;]+)/g,'<a href="$1" target="_blank" rel="noopener">$1</a>')}
  else if(message.type==='image'){const src=API_BASE+'/uploads/'+encodeURIComponent(message.file_path);content='<img class="chat-image" src="'+escapeAttr(src)+'" onclick="showImagePreview(this.src)" alt="'+escapeAttr(message.file_name)+'">'}
  else if(message.type==='file'){const src=API_BASE+'/uploads/'+encodeURIComponent(message.file_path);content='<div class="file" data-url="'+escapeAttr(src)+'" data-filename="'+escapeAttr(message.file_name)+'" onclick="downloadFile(this.dataset.url,this.dataset.filename)"><span>📄</span><div><span>'+escapeHtml(message.file_name)+'</span><span> ('+formatFileSize(message.file_size)+')</span></div></div>'}
  let replyHtml='';
  if(message.reply_to){const rm=messageCache.get(message.reply_to);if(rm){const rn=escapeHtml(rm.nickname||rm.username);const rc=rm.type==='image'?'[图片]':(rm.type==='file'?'[文件]':escapeHtml(rm.content.substring(0,50)));replyHtml='<div class="reply-preview"><span class="reply-name">'+rn+':</span> '+rc+'</div>'}}
  div.innerHTML='<div class="avatar-wrapper"><img src="'+escapeAttr(avatarUrl)+'" class="message-avatar" alt="头像"><span class="online-dot '+(isOnline?'online':'')+'"></span></div><div class="message-body">'+replyHtml+'<div class="sender">'+displayName+'</div><div class="content">'+content+'</div><span class="time">'+time+'</span></div>';
  if(prepend){const l=container.querySelector('.load-more');if(l)l.after(div);else container.insertBefore(div,container.firstChild)}
  else{container.appendChild(div);container.scrollTop=container.scrollHeight}
}

function showMessageMenu(e,message){
  const old=document.getElementById('messageMenu');if(old)old.remove();
  const menu=document.createElement('div');menu.id='messageMenu';menu.className='message-menu';
  const item=document.createElement('div');item.className='menu-item';item.textContent='💬 引用回复';
  item.addEventListener('click',()=>replyToMessage(message.id));menu.appendChild(item);
  menu.style.position='fixed';menu.style.left=Math.min(e.clientX,window.innerWidth-160)+'px';menu.style.top=Math.min(e.clientY,window.innerHeight-50)+'px';
  document.body.appendChild(menu);
  setTimeout(()=>{document.addEventListener('click',function c(){menu.remove();document.removeEventListener('click',c)})},100);
}

function replyToMessage(id){
  const msg=messageCache.get(id);if(!msg)return;replyingToMsg=msg;
  const inputArea=document.querySelector('.input-area');let rb=document.getElementById('replyBox');
  if(!rb){rb=document.createElement('div');rb.id='replyBox';rb.className='reply-box';inputArea.parentNode.insertBefore(rb,inputArea)}
  const rn=escapeHtml(msg.nickname||msg.username);const rc=msg.type==='image'?'[图片]':(msg.type==='file'?'[文件]':escapeHtml(msg.content.substring(0,30)));
  rb.innerHTML='<span class="reply-label">引用 '+rn+':</span><span class="reply-content">'+rc+'</span><button class="reply-cancel" onclick="cancelReply()">✕</button>';
  document.getElementById('messageInput').focus();
}
function cancelReply(){replyingToMsg=null;const rb=document.getElementById('replyBox');if(rb)rb.remove()}

function sendMessage(){
  const input=document.getElementById('messageInput');const content=input.value.trim();
  if(!content||!socket)return;const d={content};if(replyingToMsg)d.replyTo=replyingToMsg.id;
  socket.emit('sendMessage',d);cancelReply();input.value='';
}
function handleKeyPress(e){if(e.key==='Enter'&&!e.shiftKey){e.preventDefault();sendMessage()}}

async function handleFileUpload(input){
  const file=input.files[0];if(!file)return;const fd=new FormData();fd.append('file',file);
  try{const r=await fetch(API_BASE+'/api/upload',{method:'POST',headers:{'Authorization':'Bearer '+currentUser.token},body:fd});const d=await r.json();if(!d.success)alert(d.message||'上传失败')}catch(e){alert('上传失败')}
  input.value='';
}

function formatFileSize(b){if(!b)return '0 B';if(b<1024)return b+' B';if(b<1048576)return(b/1024).toFixed(1)+' KB';return(b/1048576).toFixed(1)+' MB'}
function showImagePreview(s){document.getElementById('previewImage').src=s;document.getElementById('imageModal').classList.remove('hidden')}
function downloadFile(u,f){const a=document.createElement('a');a.href=u;a.download=f;a.click()}
function showSettings(){document.getElementById('settingsModal').classList.remove('hidden');detectPushSupport()}
function closeSettings(){document.getElementById('settingsModal').classList.add('hidden')}

async function changePassword(){
  const o=document.getElementById('oldPassword').value,n=document.getElementById('newPassword').value;
  if(!o||!n)return document.getElementById('passwordMsg').textContent='请填写完整';
  if(n.length<6)return document.getElementById('passwordMsg').textContent='新密码至少6字符';
  try{const r=await fetch(API_BASE+'/api/change-password',{method:'POST',headers:authHeaders({'Content-Type':'application/json'}),body:JSON.stringify({oldPassword:o,newPassword:n})});const d=await r.json();if(d.success){document.getElementById('passwordMsg').textContent='修改成功';document.getElementById('oldPassword').value='';document.getElementById('newPassword').value=''}else document.getElementById('passwordMsg').textContent=d.message}catch(e){document.getElementById('passwordMsg').textContent='修改失败'}
}

async function handleAvatarUpload(input){
  const file=input.files[0];if(!file)return;const fd=new FormData();fd.append('avatar',file);
  try{const r=await fetch(API_BASE+'/api/upload-avatar',{method:'POST',headers:{'Authorization':'Bearer '+currentUser.token},body:fd});const d=await r.json();if(d.success){currentUser.avatar=d.avatar;localStorage.setItem('avatar',d.avatar);document.getElementById('currentAvatar').src=getAvatarUrl(d.avatar);document.getElementById('avatarMsg').textContent='头像已更新'}else document.getElementById('avatarMsg').textContent=d.message||'上传失败'}catch(e){document.getElementById('avatarMsg').textContent='上传失败'}
}

// ===== 时区 =====
async function loadTimezone(){try{const r=await fetch(API_BASE+'/api/settings/timezone',{headers:authHeaders()});if(r.ok){const d=await r.json();if(d.timezone){chatTimezone=d.timezone;const s=document.getElementById('timezoneSelect');if(s)s.value=chatTimezone}}}catch(e){}}
async function saveTimezone(){
  const tz=document.getElementById('timezoneSelect').value,m=document.getElementById('timezoneMsg');
  try{const r=await fetch(API_BASE+'/api/settings/timezone',{method:'POST',headers:authHeaders({'Content-Type':'application/json'}),body:JSON.stringify({timezone:tz})});const d=await r.json();if(d.success){chatTimezone=tz;refreshMessageTimes();m.textContent='时区已更新';setTimeout(()=>{m.textContent=''},3000)}else m.textContent=d.message||'保存失败'}catch(e){m.textContent='保存失败'}
}
function refreshMessageTimes(){
  document.getElementById('messages').querySelectorAll('.message[data-message-id]').forEach(div=>{
    const msg=messageCache.get(parseInt(div.dataset.messageId));if(!msg)return;const t=div.querySelector('.time');if(!t)return;
    t.textContent=new Date(msg.created_at).toLocaleString('zh-CN',{timeZone:chatTimezone,year:'numeric',month:'long',day:'numeric',hour:'2-digit',minute:'2-digit',second:'2-digit'});
  });
}

// ===== 外观定制 =====
let pendingBgFilename='';
function showAppearance(){
  const d=appearanceData;
  document.getElementById('appLoginTitle').value=d.login_title||'';document.getElementById('appChatTitle').value=d.chat_title||'';
  document.getElementById('appSendText').value=d.send_text||'';document.getElementById('appSendColor').value=d.send_color||'#667eea';
  document.getElementById('appSendColorHex').textContent=d.send_color||'#667eea';
  document.getElementById('appBgColor').value=d.bg_color||'#f5f5f5';document.getElementById('appBgColorHex').textContent=d.bg_color||'#f5f5f5';
  document.querySelectorAll('input[name="bgType"]').forEach(r=>{r.checked=(r.value===(d.bg_type||'color'))});toggleBgType();
  if(d.bg_image){pendingBgFilename=d.bg_image;document.getElementById('bgFileName').textContent=d.bg_image;const p=document.getElementById('bgPreview');p.src=API_BASE+'/backgrounds/'+encodeURIComponent(d.bg_image);p.classList.remove('hidden')}
  else{pendingBgFilename='';document.getElementById('bgFileName').textContent='未选择图片';document.getElementById('bgPreview').classList.add('hidden')}
  document.getElementById('appBgMode').value=d.bg_mode||'cover';updateLivePreview();
  document.getElementById('appearanceModal').classList.remove('hidden');
}
function closeAppearance(){document.getElementById('appearanceModal').classList.add('hidden')}
function toggleBgType(){const isImg=document.querySelector('input[name="bgType"]:checked').value==='image';document.getElementById('bgColorSection').classList.toggle('hidden',isImg);document.getElementById('bgImageSection').classList.toggle('hidden',!isImg);updateLivePreview()}
document.addEventListener('input',(e)=>{if(e.target.id==='appSendColor'){document.getElementById('appSendColorHex').textContent=e.target.value;updateLivePreview()}if(e.target.id==='appBgColor'){document.getElementById('appBgColorHex').textContent=e.target.value;updateLivePreview()}});
document.addEventListener('change',(e)=>{if(e.target.id==='appBgMode')updateLivePreview()});
function updateLivePreview(){
  const p=document.getElementById('previewArea');if(!p)return;
  const bt=document.querySelector('input[name="bgType"]:checked')?.value||'color';
  const bc=document.getElementById('appBgColor')?.value||'#f5f5f5';
  const bm=document.getElementById('appBgMode')?.value||'cover';
  if(bt==='image'&&pendingBgFilename)applyBgToElement(p,'image',bc,API_BASE+'/backgrounds/'+encodeURIComponent(pendingBgFilename),bm);
  else applyBgToElement(p,'color',bc,'','');
  const rb=p.querySelector('.preview-bubble.right');const sc=document.getElementById('appSendColor')?.value||'#667eea';if(rb)rb.style.background=sc;
}
async function handleBgImageUpload(input){
  const file=input.files[0];if(!file)return;const fd=new FormData();fd.append('bg',file);
  try{const r=await fetch(API_BASE+'/api/upload-bg',{method:'POST',headers:{'Authorization':'Bearer '+currentUser.token},body:fd});const d=await r.json();if(d.success){pendingBgFilename=d.filename;document.getElementById('bgFileName').textContent=file.name;const p=document.getElementById('bgPreview');p.src=API_BASE+'/backgrounds/'+encodeURIComponent(d.filename);p.classList.remove('hidden');updateLivePreview()}else alert(d.message||'上传失败')}catch(e){alert('上传失败')}
  input.value='';
}
async function saveAppearance(){
  const m=document.getElementById('appearanceMsg');const bt=document.querySelector('input[name="bgType"]:checked').value;
  const payload={login_title:document.getElementById('appLoginTitle').value.trim()||'团队聊天室',chat_title:document.getElementById('appChatTitle').value.trim()||'团队聊天',send_text:document.getElementById('appSendText').value.trim()||'发送',send_color:document.getElementById('appSendColor').value||'#667eea',bg_type:bt,bg_color:document.getElementById('appBgColor').value||'#f5f5f5',bg_image:bt==='image'?pendingBgFilename:'',bg_mode:document.getElementById('appBgMode').value||'cover'};
  try{const r=await fetch(API_BASE+'/api/settings/appearance',{method:'POST',headers:authHeaders({'Content-Type':'application/json'}),body:JSON.stringify(payload)});const d=await r.json();if(d.success){appearanceData=payload;applyAppearance(payload);m.textContent='✅ 外观已保存';m.style.color='#10b981';setTimeout(()=>{m.textContent=''},3000)}else{m.textContent=d.message||'保存失败';m.style.color='#dc2626'}}catch(e){m.textContent='保存失败';m.style.color='#dc2626'}
}

// ===== 用户管理 =====
function showUserManagement(){loadUsers();document.getElementById('userModal').classList.remove('hidden')}
function closeUserModal(){document.getElementById('userModal').classList.add('hidden')}
async function loadUsers(){
  try{const r=await fetch(API_BASE+'/api/users',{headers:authHeaders()});if(r.status===403)return alert('需要管理员权限');const users=await r.json();
  const list=document.getElementById('userList');list.innerHTML='';
  users.forEach(u=>{const item=document.createElement('div');item.className='user-item';
    const info=document.createElement('div');const ns=document.createElement('span');ns.className='username';ns.textContent=u.username;
    const nk=document.createElement('span');nk.className='nickname';nk.textContent=' '+(u.nickname||'');info.appendChild(ns);info.appendChild(nk);item.appendChild(info);
    if(u.is_admin){const a=document.createElement('span');a.style.cssText='color:#667eea;font-size:12px';a.textContent='管理员';item.appendChild(a)}
    else{const b=document.createElement('button');b.className='delete-btn';b.textContent='删除';b.addEventListener('click',()=>deleteUser(u.username));item.appendChild(b)}
    list.appendChild(item)});
  }catch(e){console.error('加载用户失败:',e)}
}
async function addUser(){
  const u=document.getElementById('newUsername').value,p=document.getElementById('newUserPassword').value,n=document.getElementById('newUserNickname').value;
  if(!u||!p)return alert('请填写用户名和密码');if(p.length<6)return alert('密码至少6字符');
  try{const r=await fetch(API_BASE+'/api/users',{method:'POST',headers:authHeaders({'Content-Type':'application/json'}),body:JSON.stringify({username:u,password:p,nickname:n})});const d=await r.json();if(d.success){document.getElementById('newUsername').value='';document.getElementById('newUserPassword').value='';document.getElementById('newUserNickname').value='';loadUsers()}else alert(d.message)}catch(e){alert('添加失败')}
}
async function deleteUser(u){if(!confirm('确定删除用户 '+u+'？'))return;await fetch(API_BASE+'/api/users/'+encodeURIComponent(u),{method:'DELETE',headers:authHeaders()});loadUsers()}
async function exportUsers(){try{const r=await fetch(API_BASE+'/api/users/export',{headers:authHeaders()});if(r.status===403)return alert('需要管理员权限');const d=await r.json();const b=new Blob([JSON.stringify(d,null,2)],{type:'application/json'});const u=URL.createObjectURL(b);const a=document.createElement('a');a.href=u;a.download='users_'+new Date().toISOString().slice(0,10)+'.json';a.click();URL.revokeObjectURL(u);document.getElementById('userImportMsg').textContent='已导出 '+d.users.length+' 个用户'}catch(e){alert('导出失败')}}
async function importUsers(input){const file=input.files[0];if(!file)return;const m=document.getElementById('userImportMsg');try{const t=await file.text();const d=JSON.parse(t);if(!d.users||!Array.isArray(d.users)){m.textContent='格式错误';input.value='';return}const r=await fetch(API_BASE+'/api/users/import',{method:'POST',headers:authHeaders({'Content-Type':'application/json'}),body:JSON.stringify({users:d.users})});const res=await r.json();if(res.success){m.textContent='新增'+res.created+'人，跳过'+res.skipped+'人';loadUsers()}else m.textContent=res.message||'导入失败'}catch(e){m.textContent='导入失败'}input.value=''}

function showBackup(){const t=new Date();const l=new Date(t.getFullYear(),t.getMonth()-1,1);document.getElementById('backupStart').value=l.toISOString().slice(0,10);document.getElementById('backupEnd').value=t.toISOString().slice(0,10);document.getElementById('backupModal').classList.remove('hidden')}
function closeBackupModal(){document.getElementById('backupModal').classList.add('hidden')}
async function exportBackup(){const s=document.getElementById('backupStart').value,e=document.getElementById('backupEnd').value;if(!s||!e)return document.getElementById('backupMsg').textContent='请选择日期';try{const r=await fetch(API_BASE+'/api/backup?startDate='+s+'&endDate='+e,{headers:authHeaders()});if(r.status===403)return document.getElementById('backupMsg').textContent='需要管理员权限';const b=await r.blob();const u=URL.createObjectURL(b);const a=document.createElement('a');a.href=u;a.download='backup_'+new Date().toISOString().slice(0,10)+'.json';a.click();URL.revokeObjectURL(u);document.getElementById('backupMsg').textContent='备份开始下载'}catch(e){document.getElementById('backupMsg').textContent='备份失败'}}
async function restoreBackup(){const f=document.getElementById('restoreFile').files[0];if(!f)return document.getElementById('backupMsg').textContent='请选择文件';try{const t=await f.text();const d=JSON.parse(t);const r=await fetch(API_BASE+'/api/restore',{method:'POST',headers:authHeaders({'Content-Type':'application/json'}),body:JSON.stringify({messages:d.messages})});const res=await r.json();if(res.success){document.getElementById('backupMsg').textContent='还原成功 '+res.count+' 条';oldestMessageId=null;document.getElementById('messages').innerHTML='<div class="load-more" onclick="loadMoreMessages()">加载更多</div>';loadMessages()}else document.getElementById('backupMsg').textContent=res.message}catch(e){document.getElementById('backupMsg').textContent='还原失败'}}

function showDeleteMessages(){const t=new Date();document.getElementById('deleteStart').value=t.toISOString().slice(0,10);document.getElementById('deleteEnd').value=t.toISOString().slice(0,10);document.getElementById('deleteModal').classList.remove('hidden')}
function closeDeleteModal(){document.getElementById('deleteModal').classList.add('hidden')}
async function deleteMessages(){const s=document.getElementById('deleteStart').value,e=document.getElementById('deleteEnd').value;if(!s||!e)return document.getElementById('deleteMsg').textContent='请选择日期';if(!confirm('确定删除？不可恢复！'))return;try{const r=await fetch(API_BASE+'/api/messages',{method:'DELETE',headers:authHeaders({'Content-Type':'application/json'}),body:JSON.stringify({startDate:s,endDate:e})});const d=await r.json();if(d.success){document.getElementById('deleteMsg').textContent='已删除'+d.deleted+'条';setTimeout(()=>location.reload(),1500)}else document.getElementById('deleteMsg').textContent=d.message}catch(e){document.getElementById('deleteMsg').textContent='删除失败'}}

function logout(){
  ['token','username','userId','isAdmin','nickname','avatar'].forEach(k=>localStorage.removeItem(k));
  currentUser=null;oldestMessageId=null;replyingToMsg=null;onlineUsernames.clear();messageCache.clear();
  if(socket){socket.disconnect();socket=null}
  document.getElementById('messages').innerHTML='<div class="load-more" onclick="loadMoreMessages()">加载更多</div>';showLogin();
}
APPEOF

    echo -e "${GREEN}✅ 前端文件写入完成${NC}"
}

#===============================================================================
# 写入后端文件
#===============================================================================

write_app_files() {
    echo -e "\n${YELLOW}阶段 3/6: 正在写入应用程序文件...${NC}"

    mkdir -p "$APP_DIR/public/images" "$APP_DIR/avatars" "$APP_DIR/uploads" "$APP_DIR/backgrounds"

    if [ -d "$SCRIPT_DIR/public" ] && [ -f "$SCRIPT_DIR/public/index.html" ]; then
        echo "使用本地 public 文件夹..."; cp -r "$SCRIPT_DIR/public/"* "$APP_DIR/public/" 2>/dev/null || true
    else
        echo "使用内置前端文件..."; write_frontend_files
    fi

    cat > "$APP_DIR/package.json" <<'PKGEOF'
{
  "name": "teamchat",
  "version": "2.4.0",
  "main": "server.js",
  "dependencies": {
    "express": "^4.18.2",
    "socket.io": "^4.7.2",
    "better-sqlite3": "^9.2.2",
    "multer": "^1.4.5-lts.1",
    "uuid": "^9.0.0",
    "jsonwebtoken": "^9.0.2",
    "bcryptjs": "^2.4.3",
    "cors": "^2.8.5",
    "web-push": "^3.6.7"
  }
}
PKGEOF

    # ===== server.js (引号 heredoc，不展开 $) =====
    cat > "$APP_DIR/server.js" <<'SERVEREOF'
const express = require("express");
const http = require("http");
const { Server } = require("socket.io");
const Database = require("better-sqlite3");
const multer = require("multer");
const { v4: uuidv4 } = require("uuid");
const jwt = require("jsonwebtoken");
const bcrypt = require("bcryptjs");
const cors = require("cors");
const path = require("path");
const fs = require("fs");
const crypto = require("crypto");
const webpush = require("web-push");

const app = express();
const server = http.createServer(app);
const io = new Server(server, { cors: { origin: "*", methods: ["GET", "POST"] } });

// JWT Secret
const SECRET_FILE = path.join(__dirname, ".jwt_secret");
let JWT_SECRET;
if (fs.existsSync(SECRET_FILE)) { JWT_SECRET = fs.readFileSync(SECRET_FILE, "utf-8").trim(); }
else { JWT_SECRET = crypto.randomBytes(32).toString("hex"); fs.writeFileSync(SECRET_FILE, JWT_SECRET, { mode: 0o600 }); }

// VAPID Keys for Web Push
const VAPID_FILE = path.join(__dirname, ".vapid_keys");
let vapidKeys;
if (fs.existsSync(VAPID_FILE)) {
  vapidKeys = JSON.parse(fs.readFileSync(VAPID_FILE, "utf-8"));
} else {
  vapidKeys = webpush.generateVAPIDKeys();
  fs.writeFileSync(VAPID_FILE, JSON.stringify(vapidKeys), { mode: 0o600 });
}
webpush.setVapidDetails("mailto:admin@teamchat.local", vapidKeys.publicKey, vapidKeys.privateKey);

const PORT = process.env.PORT || __PORT_PLACEHOLDER__;
const DB_PATH = path.join(__dirname, "database.sqlite");
const UPLOAD_DIR = path.join(__dirname, "uploads");
const AVATAR_DIR = path.join(__dirname, "avatars");
const BG_DIR = path.join(__dirname, "backgrounds");

[UPLOAD_DIR, AVATAR_DIR, BG_DIR].forEach(d => { if (!fs.existsSync(d)) fs.mkdirSync(d, { recursive: true }); });

const db = new Database(DB_PATH);
db.pragma("journal_mode = WAL");
db.pragma("foreign_keys = ON");

// 迁移
try { db.exec("ALTER TABLE users ADD COLUMN is_admin INTEGER DEFAULT 0"); } catch(e) {}
try { db.exec("ALTER TABLE messages ADD COLUMN reply_to INTEGER"); } catch(e) {}
try { db.exec("ALTER TABLE users ADD COLUMN last_login_at TEXT"); } catch(e) {}

db.exec(`
  CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP);
  CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT UNIQUE NOT NULL, password TEXT NOT NULL, nickname TEXT, avatar TEXT, is_admin INTEGER DEFAULT 0, last_login_at TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP);
  CREATE TABLE IF NOT EXISTS messages (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL, username TEXT NOT NULL, content TEXT, type TEXT DEFAULT 'text', file_name TEXT, file_path TEXT, file_size INTEGER, reply_to INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE);
  CREATE TABLE IF NOT EXISTS push_subscriptions (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL, endpoint TEXT UNIQUE NOT NULL, keys_p256dh TEXT NOT NULL, keys_auth TEXT NOT NULL, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE);
`);

const defaultSettings = { timezone:"Asia/Shanghai", login_title:"团队聊天室", chat_title:"团队聊天", send_text:"发送", send_color:"#667eea", bg_type:"color", bg_color:"#f5f5f5", bg_image:"", bg_mode:"cover", pinned_notice:"", pinned_notice_enabled:"0" };
const insSetting = db.prepare("INSERT OR IGNORE INTO settings (key, value) VALUES (?, ?)");
for (const [k, v] of Object.entries(defaultSettings)) insSetting.run(k, v);

app.use(cors());
app.use(express.json({ limit: "5mb" }));
app.use(express.static(path.join(__dirname, "public")));
app.use("/uploads", express.static(UPLOAD_DIR));
app.use("/avatars", express.static(AVATAR_DIR));
app.use("/backgrounds", express.static(BG_DIR));

const ALLOWED_EXTENSIONS = [".jpg",".jpeg",".png",".gif",".webp",".bmp",".pdf",".doc",".docx",".xls",".xlsx",".ppt",".pptx",".txt",".csv",".zip",".rar",".7z",".mp3",".mp4",".mov"];

function fixFilename(file) {
  try { const raw=file.originalname; let h=false; for(let i=0;i<raw.length;i++){if(raw.charCodeAt(i)>127){h=true;break}} if(!h)return; const buf=Buffer.from(raw,"latin1"); const dec=buf.toString("utf8"); if(!dec.includes("\ufffd"))file.originalname=dec; } catch(e) {}
}

const storage = multer.diskStorage({ destination:(r,f,cb)=>cb(null,UPLOAD_DIR), filename:(r,f,cb)=>{fixFilename(f);cb(null,uuidv4()+path.extname(f.originalname).toLowerCase())} });
function fileFilter(r,f,cb){fixFilename(f);const ext=path.extname(f.originalname).toLowerCase();cb(ALLOWED_EXTENSIONS.includes(ext)?null:new Error("不支持的文件类型"),ALLOWED_EXTENSIONS.includes(ext))}
const upload = multer({storage,limits:{fileSize:50*1024*1024},fileFilter,defParamCharset:"utf8"});

const avatarStorage = multer.diskStorage({ destination:(r,f,cb)=>cb(null,AVATAR_DIR), filename:(r,f,cb)=>{fixFilename(f);cb(null,uuidv4()+path.extname(f.originalname).toLowerCase())} });
const uploadAvatar = multer({storage:avatarStorage,limits:{fileSize:5*1024*1024},fileFilter:(r,f,cb)=>{fixFilename(f);const ext=path.extname(f.originalname).toLowerCase();cb([".jpg",".jpeg",".png",".gif",".webp"].includes(ext)?null:new Error("头像只支持图片"),[".jpg",".jpeg",".png",".gif",".webp"].includes(ext))},defParamCharset:"utf8"});

const bgStorage = multer.diskStorage({ destination:(r,f,cb)=>cb(null,BG_DIR), filename:(r,f,cb)=>{fixFilename(f);cb(null,uuidv4()+path.extname(f.originalname).toLowerCase())} });
const uploadBg = multer({storage:bgStorage,limits:{fileSize:10*1024*1024},fileFilter:(r,f,cb)=>{fixFilename(f);const ext=path.extname(f.originalname).toLowerCase();const ok=[".jpg",".jpeg",".png",".gif",".webp",".bmp",".svg"].includes(ext);cb(ok?null:new Error("背景只支持图片"),ok)},defParamCharset:"utf8"});

function authMiddleware(req,res,next){
  const token=req.headers.authorization?.split(" ")[1];
  if(!token)return res.status(401).json({success:false,message:"未提供认证信息"});
  try{
    const decoded=jwt.verify(token,JWT_SECRET);
    const user=db.prepare("SELECT last_login_at FROM users WHERE id = ?").get(decoded.userId);
    if(user&&user.last_login_at&&decoded.loginAt&&user.last_login_at!==decoded.loginAt)return res.status(401).json({success:false,message:"账号已在其他设备登录"});
    req.user=decoded;next();
  }catch(e){res.status(401).json({success:false,message:"认证失败"})}
}
function adminMiddleware(req,res,next){if(!req.user.isAdmin)return res.status(403).json({success:false,message:"需要管理员权限"});next()}

function getSetting(k){const r=db.prepare("SELECT value FROM settings WHERE key=?").get(k);return r?r.value:(defaultSettings[k]||"")}
function setSetting(k,v){db.prepare("INSERT OR REPLACE INTO settings (key,value,updated_at) VALUES (?,?,datetime('now'))").run(k,v)}

// ===== Push Notification 相关 =====
app.get("/api/push/vapid-key",(req,res)=>{
  res.json({publicKey:vapidKeys.publicKey});
});

app.post("/api/push/subscribe",authMiddleware,(req,res)=>{
  const {subscription}=req.body;
  if(!subscription||!subscription.endpoint||!subscription.keys)return res.json({success:false,message:"无效的订阅数据"});
  try{
    db.prepare("INSERT OR REPLACE INTO push_subscriptions (user_id,endpoint,keys_p256dh,keys_auth) VALUES (?,?,?,?)")
      .run(req.user.userId,subscription.endpoint,subscription.keys.p256dh,subscription.keys.auth);
    res.json({success:true});
  }catch(e){res.json({success:false,message:"保存订阅失败"})}
});

app.post("/api/push/unsubscribe",authMiddleware,(req,res)=>{
  const {endpoint}=req.body;
  if(!endpoint)return res.json({success:false,message:"缺少endpoint"});
  db.prepare("DELETE FROM push_subscriptions WHERE endpoint=?").run(endpoint);
  res.json({success:true});
});

function sendPushToOthers(senderUserId, senderName, messageText){
  const subs=db.prepare("SELECT * FROM push_subscriptions WHERE user_id != ?").all(senderUserId);
  const chatTitle=getSetting("chat_title")||"TeamChat";
  const body=messageText.length>100?messageText.substring(0,100)+"...":messageText;
  const payload=JSON.stringify({
    title:chatTitle,
    body:senderName+": "+body,
    icon:"/images/icon-192.svg",
    data:{url:"/"}
  });
  for(const sub of subs){
    const pushSub={endpoint:sub.endpoint,keys:{p256dh:sub.keys_p256dh,auth:sub.keys_auth}};
    webpush.sendNotification(pushSub,payload).catch(err=>{
      if(err.statusCode===410||err.statusCode===404){
        db.prepare("DELETE FROM push_subscriptions WHERE id=?").run(sub.id);
      }
    });
  }
}

// ===== 置顶通知 API =====
app.get("/api/settings/notice",(req,res)=>{
  res.json({
    content:getSetting("pinned_notice"),
    enabled:getSetting("pinned_notice_enabled")==="1"
  });
});

app.post("/api/settings/notice",authMiddleware,adminMiddleware,(req,res)=>{
  const{content,enabled}=req.body;
  if(typeof content==="string"){
    const trimmed=content.substring(0,2000);
    setSetting("pinned_notice",trimmed);
  }
  if(typeof enabled==="boolean"){
    setSetting("pinned_notice_enabled",enabled?"1":"0");
  }
  const noticeData={
    content:getSetting("pinned_notice"),
    enabled:getSetting("pinned_notice_enabled")==="1"
  };
  io.emit("noticeChanged",noticeData);
  res.json({success:true});
});

// ===== 业务路由 =====
app.post("/api/register",authMiddleware,adminMiddleware,async(req,res)=>{
  const{username,password,nickname}=req.body;
  if(!username||!password)return res.json({success:false,message:"缺少参数"});
  if(!/^[a-zA-Z0-9_.\-]+$/.test(username))return res.json({success:false,message:"用户名只允许字母数字下划线"});
  if(password.length<6)return res.json({success:false,message:"密码不能小于6位"});
  const hashed=await bcrypt.hash(password,10);
  try{db.prepare("INSERT INTO users (username,password,nickname) VALUES (?,?,?)").run(username,hashed,nickname||username);res.json({success:true})}
  catch(e){res.json({success:false,message:"用户名已存在"})}
});

app.post("/api/login",async(req,res)=>{
  const{username,password}=req.body;
  if(!username||!password)return res.json({success:false,message:"缺少参数"});
  const user=db.prepare("SELECT * FROM users WHERE username=?").get(username);
  if(!user||!(await bcrypt.compare(password,user.password)))return res.json({success:false,message:"用户名或密码错误"});
  const loginAt=new Date().toISOString();
  db.prepare("UPDATE users SET last_login_at=? WHERE id=?").run(loginAt,user.id);
  const token=jwt.sign({userId:user.id,username:user.username,isAdmin:user.is_admin,loginAt},JWT_SECRET,{expiresIn:"7d"});
  for(const[sid,info] of onlineUsers.entries()){if(info.userId===user.id){const s=io.sockets.sockets.get(sid);if(s){s.emit("kicked",{message:"您的账号已在其他设备登录"});s.disconnect(true)}}}
  res.json({success:true,token,username:user.username,userId:user.id,nickname:user.nickname,avatar:user.avatar,isAdmin:!!user.is_admin});
});

app.get("/api/messages",authMiddleware,(req,res)=>{
  const{before,limit=50}=req.query;const pl=Math.min(Math.max(parseInt(limit)||50,1),200);
  let sql="SELECT m.*,u.nickname,u.avatar FROM messages m JOIN users u ON m.user_id=u.id";const params=[];
  if(before){const pb=parseInt(before);if(!isNaN(pb)&&pb>0){sql+=" WHERE m.id < ?";params.push(pb)}}
  sql+=" ORDER BY m.id DESC LIMIT ?";params.push(pl);
  res.json(db.prepare(sql).all(...params).reverse());
});

app.post("/api/upload",authMiddleware,upload.single("file"),(req,res)=>{
  if(!req.file)return res.json({success:false,message:"上传失败"});
  const type=req.file.mimetype.startsWith("image/")?"image":"file";
  const user=db.prepare("SELECT username,nickname,avatar FROM users WHERE id=?").get(req.user.userId);
  if(!user)return res.json({success:false,message:"用户不存在"});
  const result=db.prepare("INSERT INTO messages (user_id,username,content,type,file_name,file_path,file_size) VALUES (?,?,?,?,?,?,?)").run(req.user.userId,user.username,req.body.content||"",type,req.file.originalname,req.file.filename,req.file.size);
  const message={id:result.lastInsertRowid,username:user.username,nickname:user.nickname,avatar:user.avatar,content:req.body.content||"",type,file_name:req.file.originalname,file_path:req.file.filename,file_size:req.file.size,created_at:new Date().toISOString()};
  io.emit("newMessage",message);
  const pushText=type==="image"?"[图片] "+req.file.originalname:"[文件] "+req.file.originalname;
  sendPushToOthers(req.user.userId,user.nickname||user.username,pushText);
  res.json({success:true,filePath:req.file.filename});
});

app.post("/api/upload-avatar",authMiddleware,uploadAvatar.single("avatar"),(req,res)=>{if(!req.file)return res.json({success:false,message:"上传失败"});db.prepare("UPDATE users SET avatar=? WHERE id=?").run(req.file.filename,req.user.userId);res.json({success:true,avatar:req.file.filename})});
app.post("/api/upload-bg",authMiddleware,adminMiddleware,uploadBg.single("bg"),(req,res)=>{if(!req.file)return res.json({success:false,message:"上传失败"});res.json({success:true,filename:req.file.filename})});

app.post("/api/change-password",authMiddleware,async(req,res)=>{
  const{oldPassword,newPassword}=req.body;if(!newPassword||newPassword.length<6)return res.json({success:false,message:"新密码不能小于6位"});
  const user=db.prepare("SELECT password FROM users WHERE id=?").get(req.user.userId);if(!user)return res.json({success:false,message:"用户不存在"});
  if(!(await bcrypt.compare(oldPassword,user.password)))return res.json({success:false,message:"原密码错误"});
  db.prepare("UPDATE users SET password=? WHERE id=?").run(await bcrypt.hash(newPassword,10),req.user.userId);res.json({success:true});
});

// ===== Settings =====
const VALID_TZ=["Asia/Shanghai","Asia/Tokyo","Asia/Singapore","Asia/Kolkata","Asia/Dubai","Europe/London","Europe/Paris","Europe/Moscow","America/New_York","America/Chicago","America/Denver","America/Los_Angeles","Pacific/Auckland","Australia/Sydney"];
app.get("/api/settings/timezone",authMiddleware,(req,res)=>{res.json({timezone:getSetting("timezone")})});
app.post("/api/settings/timezone",authMiddleware,adminMiddleware,(req,res)=>{const{timezone}=req.body;if(!timezone||!VALID_TZ.includes(timezone))return res.json({success:false,message:"不支持的时区"});setSetting("timezone",timezone);io.emit("timezoneChanged",{timezone});res.json({success:true})});

app.get("/api/settings/appearance",(req,res)=>{
  const keys=["login_title","chat_title","send_text","send_color","bg_type","bg_color","bg_image","bg_mode","timezone"];
  const r={};keys.forEach(k=>{r[k]=getSetting(k)});res.json(r);
});
app.post("/api/settings/appearance",authMiddleware,adminMiddleware,(req,res)=>{
  const body=req.body;const allowed=["login_title","chat_title","send_text","send_color","bg_type","bg_color","bg_image","bg_mode"];
  if(body.send_color&&!/^#[0-9a-fA-F]{6}$/.test(body.send_color))return res.json({success:false,message:"颜色格式错误"});
  if(body.bg_color&&!/^#[0-9a-fA-F]{6}$/.test(body.bg_color))return res.json({success:false,message:"颜色格式错误"});
  if(body.bg_type&&!["color","image"].includes(body.bg_type))return res.json({success:false,message:"类型错误"});
  if(body.bg_mode&&!["cover","contain","stretch","tile"].includes(body.bg_mode))return res.json({success:false,message:"显示方式错误"});
  if(body.login_title&&body.login_title.length>30)body.login_title=body.login_title.substring(0,30);
  if(body.chat_title&&body.chat_title.length>30)body.chat_title=body.chat_title.substring(0,30);
  if(body.send_text&&body.send_text.length>10)body.send_text=body.send_text.substring(0,10);
  const upd=db.prepare("INSERT OR REPLACE INTO settings (key,value,updated_at) VALUES (?,?,datetime('now'))");
  db.transaction(()=>{for(const k of allowed){if(body[k]!==undefined)upd.run(k,String(body[k]))}})();
  const bd={};["login_title","chat_title","send_text","send_color","bg_type","bg_color","bg_image","bg_mode","timezone"].forEach(k=>{bd[k]=getSetting(k)});
  io.emit("appearanceChanged",bd);res.json({success:true});
});

// Users (具名路由在参数路由之前)
app.get("/api/users/export",authMiddleware,adminMiddleware,(req,res)=>{res.json({version:2,exported_at:new Date().toISOString(),users:db.prepare("SELECT username,password,nickname,is_admin,created_at FROM users").all().map(u=>({username:u.username,password_hash:u.password,nickname:u.nickname,is_admin:!!u.is_admin,created_at:u.created_at}))})});
app.post("/api/users/import",authMiddleware,adminMiddleware,async(req,res)=>{
  const{users}=req.body;if(!Array.isArray(users))return res.json({success:false,message:"格式错误"});
  let created=0,skipped=0;
  for(const u of users){if(!u.username||!/^[a-zA-Z0-9_.\-]+$/.test(u.username)){skipped++;continue}if(db.prepare("SELECT id FROM users WHERE username=?").get(u.username)){skipped++;continue}
  let finalHash;
  if(u.password_hash&&/^\$2[aby]?\$/.test(u.password_hash)){finalHash=u.password_hash}
  else{const pw=u.password||crypto.randomBytes(8).toString("hex");finalHash=await bcrypt.hash(pw,10)}
  try{db.prepare("INSERT INTO users (username,password,nickname,is_admin) VALUES (?,?,?,?)").run(u.username,finalHash,u.nickname||u.username,u.is_admin?1:0);created++}catch(e){skipped++}}
  res.json({success:true,created,skipped});
});
app.get("/api/users",authMiddleware,adminMiddleware,(req,res)=>{res.json(db.prepare("SELECT id,username,nickname,avatar,is_admin,created_at FROM users").all())});
app.post("/api/users",authMiddleware,adminMiddleware,async(req,res)=>{
  const{username,password,nickname}=req.body;if(!username||!password)return res.json({success:false,message:"缺少参数"});
  if(!/^[a-zA-Z0-9_.\-]+$/.test(username))return res.json({success:false,message:"用户名非法"});if(password.length<6)return res.json({success:false,message:"密码不能小于6位"});
  try{db.prepare("INSERT INTO users (username,password,nickname) VALUES (?,?,?)").run(username,await bcrypt.hash(password,10),nickname||username);res.json({success:true})}catch(e){res.json({success:false,message:"用户名已存在"})}
});
app.delete("/api/users/:username",authMiddleware,adminMiddleware,(req,res)=>{
  const t=db.prepare("SELECT is_admin FROM users WHERE username=?").get(req.params.username);
  if(!t)return res.json({success:false,message:"用户不存在"});if(t.is_admin)return res.json({success:false,message:"不能删除管理员"});
  db.prepare("DELETE FROM users WHERE username=?").run(req.params.username);res.json({success:true});
});

app.get("/api/backup",authMiddleware,adminMiddleware,(req,res)=>{const{startDate,endDate}=req.query;let sql="SELECT m.*,u.username as user_username,u.nickname,u.avatar FROM messages m JOIN users u ON m.user_id=u.id";const p=[];if(startDate&&endDate){sql+=" WHERE DATE(m.created_at) BETWEEN ? AND ?";p.push(startDate,endDate)}sql+=" ORDER BY m.id";res.json({messages:db.prepare(sql).all(...p)})});
app.post("/api/restore",authMiddleware,adminMiddleware,(req,res)=>{const{messages}=req.body;if(!Array.isArray(messages))return res.json({success:false,message:"格式错误"});let count=0;const ins=db.prepare("INSERT INTO messages (user_id,username,content,type,file_name,file_path,file_size,created_at) VALUES (?,?,?,?,?,?,?,?)");try{db.transaction(ms=>{for(const m of ms){const u=db.prepare("SELECT id FROM users WHERE username=?").get(m.username);if(u){ins.run(u.id,m.username,m.content,m.type,m.file_name,m.file_path,m.file_size,m.created_at);count++}}})(messages);res.json({success:true,count})}catch(e){res.json({success:false,message:"恢复失败"})}});
app.delete("/api/messages",authMiddleware,adminMiddleware,(req,res)=>{const{startDate,endDate}=req.body;if(!startDate||!endDate)return res.json({success:false,message:"请提供日期"});res.json({success:true,deleted:db.prepare("DELETE FROM messages WHERE DATE(created_at) BETWEEN ? AND ?").run(startDate,endDate).changes})});

// ===== Socket.IO =====
const onlineUsers=new Map(),userSocketMap=new Map();
io.use((socket,next)=>{
  const token=socket.handshake.auth.token;if(!token)return next(new Error("未提供认证信息"));
  try{const d=jwt.verify(token,JWT_SECRET);const u=db.prepare("SELECT last_login_at FROM users WHERE id=?").get(d.userId);if(u&&u.last_login_at&&d.loginAt&&u.last_login_at!==d.loginAt)return next(new Error("认证失败"));socket.user=d;next()}catch(e){next(new Error("认证失败"))}
});

io.on("connection",(socket)=>{
  const userId=socket.user.userId;
  const oldSid=userSocketMap.get(userId);
  if(oldSid&&oldSid!==socket.id){const s=io.sockets.sockets.get(oldSid);if(s){s.emit("kicked",{message:"您的账号已在其他设备登录"});s.disconnect(true)}onlineUsers.delete(oldSid)}
  userSocketMap.set(userId,socket.id);
  const ui=db.prepare("SELECT nickname,avatar FROM users WHERE id=?").get(userId);
  onlineUsers.set(socket.id,{username:socket.user.username,userId,nickname:ui?ui.nickname:socket.user.username});
  broadcastOnlineUsers();

  socket.on("sendMessage",(data)=>{
    if(!data||typeof data!=="object")return;const{content,replyTo}=data;
    if(!content||typeof content!=="string"||content.trim().length===0)return;
    const trimmed=content.trim().substring(0,5000);
    const safeReplyTo=(Number.isInteger(replyTo)&&replyTo>0)?replyTo:null;
    const result=db.prepare("INSERT INTO messages (user_id,username,content,reply_to) VALUES (?,?,?,?)").run(socket.user.userId,socket.user.username,trimmed,safeReplyTo);
    const user=db.prepare("SELECT nickname,avatar FROM users WHERE id=?").get(socket.user.userId);
    const message={id:result.lastInsertRowid,username:socket.user.username,nickname:user?user.nickname:socket.user.username,avatar:user?user.avatar:null,content:trimmed,type:"text",reply_to:safeReplyTo,created_at:new Date().toISOString()};
    io.emit("newMessage",message);
    sendPushToOthers(socket.user.userId, user?user.nickname:socket.user.username, trimmed);
  });

  socket.on("disconnect",()=>{if(userSocketMap.get(userId)===socket.id)userSocketMap.delete(userId);onlineUsers.delete(socket.id);broadcastOnlineUsers()});
});

function broadcastOnlineUsers(){io.emit("onlineUsers",[...new Map(Array.from(onlineUsers.values()).map(u=>[u.username,u])).values()])}
process.on("SIGTERM",()=>{io.close();server.close(()=>{db.close();process.exit(0)});setTimeout(()=>process.exit(1),5000)});
server.listen(PORT,()=>{console.log("TeamChat 服务器运行在端口 "+PORT)});
SERVEREOF

    sed -i "s/__PORT_PLACEHOLDER__/${PORT}/" "$APP_DIR/server.js"
    chmod -R 755 "$APP_DIR"
    chmod 755 "$APP_DIR/uploads" "$APP_DIR/avatars" "$APP_DIR/backgrounds" 2>/dev/null || true

    echo -e "${GREEN}✅ 应用程序文件写入完成${NC}"
}

install_npm_deps() {
    echo -e "\n${YELLOW}阶段 4/6: 正在安装 Node.js 依赖...${NC}"
    cd "$APP_DIR"; npm install --production
    echo -e "${GREEN}✅ Node.js 依赖安装完成${NC}"
}

init_database() {
    echo -e "\n${YELLOW}阶段 5/6: 初始化数据库...${NC}"
    cd "$APP_DIR"
    ADMIN_USER_ENV="$ADMIN_USER" ADMIN_PASS_ENV="$ADMIN_PASS" node -e '
const Database=require("better-sqlite3"),bcrypt=require("bcryptjs"),crypto=require("crypto"),fs=require("fs"),path=require("path");
const DB_PATH=path.join(process.env.PWD,"database.sqlite"),SF=path.join(process.env.PWD,".jwt_secret");
if(!fs.existsSync(SF))fs.writeFileSync(SF,crypto.randomBytes(32).toString("hex"),{mode:0o600});
const db=new Database(DB_PATH);db.pragma("journal_mode=WAL");db.pragma("foreign_keys=ON");
db.exec(`CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY AUTOINCREMENT,username TEXT UNIQUE NOT NULL,password TEXT NOT NULL,nickname TEXT,avatar TEXT,is_admin INTEGER DEFAULT 0,last_login_at TEXT,created_at DATETIME DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE IF NOT EXISTS messages (id INTEGER PRIMARY KEY AUTOINCREMENT,user_id INTEGER NOT NULL,username TEXT NOT NULL,content TEXT,type TEXT DEFAULT "text",file_name TEXT,file_path TEXT,file_size INTEGER,reply_to INTEGER,created_at DATETIME DEFAULT CURRENT_TIMESTAMP,FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE);
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY,value TEXT NOT NULL,updated_at DATETIME DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE IF NOT EXISTS push_subscriptions (id INTEGER PRIMARY KEY AUTOINCREMENT,user_id INTEGER NOT NULL,endpoint TEXT UNIQUE NOT NULL,keys_p256dh TEXT NOT NULL,keys_auth TEXT NOT NULL,created_at DATETIME DEFAULT CURRENT_TIMESTAMP,FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE);`);
const defs={timezone:"Asia/Shanghai",login_title:"团队聊天室",chat_title:"团队聊天",send_text:"发送",send_color:"#667eea",bg_type:"color",bg_color:"#f5f5f5",bg_image:"",bg_mode:"cover",pinned_notice:"",pinned_notice_enabled:"0"};
const ins=db.prepare("INSERT OR IGNORE INTO settings (key,value) VALUES (?,?)");for(const[k,v] of Object.entries(defs))ins.run(k,v);
const au=process.env.ADMIN_USER_ENV,ap=process.env.ADMIN_PASS_ENV,h=bcrypt.hashSync(ap,10);
try{db.prepare("INSERT INTO users (username,password,is_admin) VALUES (?,?,1)").run(au,h);console.log("✅ 管理员已创建")}catch(e){db.prepare("UPDATE users SET password=?,is_admin=1 WHERE username=?").run(h,au);console.log("✅ 管理员密码已重置")}
db.close();
'
    chmod 600 "$APP_DIR/.jwt_secret" "$APP_DIR/.vapid_keys" 2>/dev/null || true
    chmod 600 "$APP_DIR/database.sqlite" 2>/dev/null || true
    echo -e "${GREEN}✅ 数据库初始化完成${NC}"
}

setup_service() {
    echo -e "\n${YELLOW}阶段 6/6: 配置并启动服务...${NC}"
    pm2 stop teamchat > /dev/null 2>&1 || true
    pm2 delete teamchat > /dev/null 2>&1 || true
    cd "$APP_DIR"; PORT=$PORT pm2 start server.js --name teamchat; pm2 save
    pm2 startup systemd -u root --hp /root > /dev/null 2>&1 || pm2 startup > /dev/null 2>&1 || true
    pm2 save
    echo -e "${GREEN}✅ 服务配置完成${NC}"
}

generate_nginx_config() {
    local domain="$1" use_ssl="$2" port
    port=$(get_current_port)
    [ -f /etc/nginx/sites-enabled/default ] && rm -f /etc/nginx/sites-enabled/default
    [ -f /etc/nginx/conf.d/default.conf ] && mv /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf.bak

    cat > /etc/nginx/conf.d/teamchat.conf <<EOF
server {
    listen 80;
    server_name $domain;
    client_max_body_size 50M;
    location / {
        proxy_pass http://127.0.0.1:$port;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
EOF
    if ! nginx -t 2>&1; then
        echo -e "${RED}Nginx 配置测试失败${NC}"
        echo -e "${YELLOW}提示: 可直接通过 http://${domain}:${port} 访问${NC}"; return 1
    fi
    systemctl enable nginx 2>/dev/null || true; systemctl restart nginx
    if [ "$use_ssl" = "yes" ]; then
        echo -e "${YELLOW}正在申请 SSL 证书...${NC}"
        certbot --nginx -d "$domain" --non-interactive --agree-tos --email admin@"$domain" 2>/dev/null || {
            echo -e "${YELLOW}SSL 申请失败，请手动运行: sudo certbot --nginx -d $domain${NC}"; return 0
        }
        systemctl enable certbot.timer 2>/dev/null || true; systemctl start certbot.timer 2>/dev/null || true
    fi
    echo -e "${GREEN}✅ Nginx 配置完成${NC}"
}

do_install() {
    print_header; DOMAIN=$(show_ip_menu)
    echo ""; echo -e "请配置以下参数:"
    while true; do printf "  管理员用户名 [admin]: "; read -r input; ADMIN_USER=${input:-admin}; validate_input "$ADMIN_USER" "用户名" && break; done
    while true; do printf "  管理员密码 [admin123]: "; read -r input; ADMIN_PASS=${input:-admin123}; [ ${#ADMIN_PASS} -ge 6 ] && break; echo -e "${RED}密码不能小于6位${NC}"; done
    while true; do printf "  服务端口 [3000]: "; read -r input; PORT=${input:-3000}; [[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] && break; echo -e "${RED}端口无效${NC}"; done

    echo ""; printf "是否配置 SSL/HTTPS? (y/n) [n]: "; read -r use_ssl
    local domain=""
    if [ "$use_ssl" = "y" ]||[ "$use_ssl" = "Y" ]; then
        echo -n "  请输入域名: "; read domain; while [ -z "$domain" ]; do echo -n "  域名不能为空: "; read domain; done
    else domain=$DOMAIN; fi

    echo ""
    echo "==========================================="
    echo "  域名/IP: $domain | 端口: $PORT | 管理员: $ADMIN_USER"
    echo "  HTTPS: $([ "$use_ssl" = "y" ]||[ "$use_ssl" = "Y" ] && echo 是 || echo 否)"
    echo "==========================================="
    printf "确认部署? (y/n): "; read -r confirm; [ "$confirm" != "y" ] && { echo "已取消"; return 0; }

    detect_os; install_dependencies; install_nodejs; write_app_files; install_npm_deps; init_database; setup_service
    if [ "$use_ssl" = "y" ]||[ "$use_ssl" = "Y" ]; then generate_nginx_config "$domain" "yes"; else generate_nginx_config "$domain" "no"; fi

    echo ""
    echo -e "${GREEN}================================================${NC}"
    echo -e "${GREEN}  🎉 部署完成！${NC}"
    echo -e "${GREEN}================================================${NC}"
    if [ "$use_ssl" = "y" ]||[ "$use_ssl" = "Y" ]; then echo -e "  访问: https://${domain}";
    else echo -e "  访问: http://${domain}:${PORT}"; fi
    echo -e "  管理员: $ADMIN_USER / $ADMIN_PASS"
    echo -e "${GREEN}================================================${NC}"
    echo ""
    echo -e "${YELLOW}📱 推送通知说明:${NC}"
    echo "  - Android Chrome: 打开网页后在设置中开启推送即可"
    echo "  - iOS Safari (16.4+): 先"添加到主屏幕"再从主屏幕打开"
    echo "  - 推送需要 HTTPS，使用 IP 直连时仅 localhost 可用"
    echo ""
}

do_start() { echo -e "${YELLOW}启动中...${NC}"; if pm2 describe teamchat >/dev/null 2>&1; then pm2 restart teamchat; else [ -f "$APP_DIR/server.js" ]&&{ cd "$APP_DIR";pm2 start server.js --name teamchat;pm2 save; }||{ echo -e "${RED}未找到应用${NC}";return 1; }; fi; echo -e "${GREEN}✅ 已启动${NC}"; }
do_stop() { echo -e "${YELLOW}停止中...${NC}"; pm2 stop teamchat; echo -e "${GREEN}✅ 已停止${NC}"; }
do_restart() { echo -e "${YELLOW}重启中...${NC}"; if pm2 describe teamchat >/dev/null 2>&1; then pm2 restart teamchat; else do_start; return; fi; echo -e "${GREEN}✅ 已重启${NC}"; }
do_logs() { echo -e "${YELLOW}运行日志:${NC}"; pm2 logs teamchat --lines 50 --nostream; }

do_modify() {
    echo -e "\n${YELLOW}========== 修改配置 ==========${NC}\n"
    local current_port current_admin; current_port=$(get_current_port); current_admin=$(get_admin_username)
    echo "  1. 修改管理员密码 (当前: $current_admin)"; echo "  2. 修改端口 (当前: $current_port)"; echo "  3. 修改管理员用户名"; echo "  0. 返回"
    printf "请选择: "; read -r choice
    case $choice in
        1) printf "新密码: "; read -r new_pass; [ -z "$new_pass" ]&&{ echo -e "${RED}不能为空${NC}";return; }; [ ${#new_pass} -lt 6 ]&&{ echo -e "${RED}至少6位${NC}";return; }
           cd "$APP_DIR"; NEW_PASS_ENV="$new_pass" ADMIN_USER_ENV="$current_admin" node -e 'const D=require("better-sqlite3"),b=require("bcryptjs");const d=new D("database.sqlite");d.prepare("UPDATE users SET password=? WHERE username=?").run(b.hashSync(process.env.NEW_PASS_ENV,10),process.env.ADMIN_USER_ENV);d.close();console.log("已更新")'
           echo -e "${GREEN}✅ 密码已修改${NC}"; pm2 restart teamchat 2>/dev/null||true ;;
        2) while true; do printf "新端口: "; read -r np; [[ "$np" =~ ^[0-9]+$ ]]&&[ "$np" -ge 1 ]&&[ "$np" -le 65535 ]&&break; echo -e "${RED}无效${NC}"; done
           sed -i "s/const PORT = process.env.PORT || [0-9]*/const PORT = process.env.PORT || $np/" "$APP_DIR/server.js"
           [ -f /etc/nginx/conf.d/teamchat.conf ]&&{ sed -i "s/proxy_pass http:\/\/127.0.0.1:[0-9]*/proxy_pass http:\/\/127.0.0.1:$np/" /etc/nginx/conf.d/teamchat.conf; nginx -t 2>/dev/null&&systemctl reload nginx; }
           pm2 restart teamchat 2>/dev/null||true; echo -e "${GREEN}✅ 端口已改为 $np${NC}" ;;
        3) while true; do printf "新用户名: "; read -r nu; [ -z "$nu" ]&&{ echo -e "${RED}不能为空${NC}";continue; }; validate_input "$nu" "用户名"&&break; done
           cd "$APP_DIR"; NEW_USER_ENV="$nu" OLD_USER_ENV="$current_admin" node -e 'const D=require("better-sqlite3");const d=new D("database.sqlite");try{d.prepare("UPDATE users SET username=? WHERE username=?").run(process.env.NEW_USER_ENV,process.env.OLD_USER_ENV);console.log("已更新")}catch(e){console.log("错误:"+e.message)}d.close()'
           echo -e "${GREEN}✅ 用户名已改为 $nu${NC}" ;;
        0) return ;; *) echo -e "${RED}无效${NC}" ;;
    esac
}

do_ssl() {
    echo -e "\n${YELLOW}配置 SSL${NC}\n"; detect_os; command -v certbot >/dev/null 2>&1||install_dependencies
    printf "域名: "; read -r domain; while [ -z "$domain" ]; do printf "不能为空: "; read -r domain; done
    command -v nginx >/dev/null 2>&1||{ if [ "$OS" = "ubuntu" ]||[ "$OS" = "debian" ]; then apt-get install -y nginx; else yum install -y nginx; fi; }
    local port; port=$(get_current_port)
    [ -f /etc/nginx/sites-enabled/default ]&&rm -f /etc/nginx/sites-enabled/default
    [ -f /etc/nginx/conf.d/default.conf ]&&mv /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf.bak
    cat > /etc/nginx/conf.d/teamchat.conf <<EOF
server { listen 80; server_name $domain; client_max_body_size 50M;
  location / { proxy_pass http://127.0.0.1:$port; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host \$host; proxy_set_header X-Real-IP \$remote_addr; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto \$scheme; proxy_read_timeout 3600s; proxy_send_timeout 3600s; } }
EOF
    nginx -t 2>&1||{ echo -e "${RED}Nginx 配置失败${NC}"; return 1; }
    systemctl enable nginx 2>/dev/null||true; systemctl restart nginx
    printf "邮箱 [admin@$domain]: "; read -r email; email=${email:-admin@$domain}
    certbot --nginx -d "$domain" --non-interactive --agree-tos --email "$email" 2>/dev/null||{ certbot --nginx -d "$domain" --agree-tos --email "$email"||{ echo -e "${RED}证书申请失败${NC}"; return 1; }; }
    systemctl enable certbot.timer 2>/dev/null||true; systemctl start certbot.timer 2>/dev/null||true
    echo -e "${GREEN}✅ SSL 完成！https://${domain}${NC}"
}

do_uninstall() {
    echo -e "\n${YELLOW}卸载${NC}\n"; echo "  1. 保留数据卸载"; echo "  2. 完全卸载"; echo "  3. 卸载SSL"; echo "  0. 返回"
    printf "选择: "; read -r c
    case $c in
        1) printf "确认? (y/n): "; read -r cf; [ "$cf" != "y" ]&&return; pm2 stop teamchat 2>/dev/null||true; pm2 delete teamchat 2>/dev/null||true; pm2 save 2>/dev/null||true; rm -f /etc/nginx/conf.d/teamchat.conf; nginx -t 2>/dev/null&&systemctl reload nginx; echo -e "${GREEN}✅ 已卸载，数据在 $APP_DIR${NC}" ;;
        2) echo -e "${RED}警告: 删除所有数据！${NC}"; printf "输入 DELETE 确认: "; read -r cf; [ "$cf" != "DELETE" ]&&return; pm2 stop teamchat 2>/dev/null||true; pm2 delete teamchat 2>/dev/null||true; pm2 save 2>/dev/null||true; rm -rf "$APP_DIR"; rm -f /etc/nginx/conf.d/teamchat.conf; nginx -t 2>/dev/null&&systemctl reload nginx; echo -e "${GREEN}✅ 完全卸载${NC}" ;;
        3) printf "域名: "; read -r sd; [ -z "$sd" ]&&return; printf "确认? (y/n): "; read -r cf; [ "$cf" != "y" ]&&return
           certbot delete --cert-name "$sd" --non-interactive 2>/dev/null||certbot delete --cert-name "$sd" 2>/dev/null||true
           local port; port=$(get_current_port)
           cat > /etc/nginx/conf.d/teamchat.conf <<EOF
server { listen 80; server_name _; client_max_body_size 50M;
  location / { proxy_pass http://127.0.0.1:$port; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host \$host; proxy_set_header X-Real-IP \$remote_addr; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto \$scheme; } }
EOF
           nginx -t 2>/dev/null&&systemctl reload nginx; echo -e "${GREEN}✅ SSL已卸载${NC}" ;;
        0) return ;; *) echo -e "${RED}无效${NC}" ;;
    esac
}

check_root

if [ $# -gt 0 ]; then
    case $1 in
        --install|-i) do_install; exit 0 ;; --ssl|-s) do_ssl; exit 0 ;; --uninstall|-u) do_uninstall; exit 0 ;;
        --uninstall-force) echo -e "${RED}警告: 删除所有数据！${NC}"; printf "输入 DELETE: "; read -r cf; [ "$cf" != "DELETE" ]&&exit 0
            pm2 stop teamchat 2>/dev/null||true; pm2 delete teamchat 2>/dev/null||true; pm2 save 2>/dev/null||true; rm -rf "$APP_DIR"; rm -f /etc/nginx/conf.d/teamchat.conf; nginx -t 2>/dev/null&&systemctl reload nginx 2>/dev/null||true; echo -e "${GREEN}✅ 完全卸载${NC}"; exit 0 ;;
        --help|-h) echo "用法: sudo $0 [--install|--ssl|--uninstall|--uninstall-force|--help]"; exit 0 ;;
        *) echo "未知选项: $1"; exit 1 ;;
    esac
fi

while true; do
    print_menu; read choice
    case $choice in 1) do_install;; 2) do_restart;; 3) do_stop;; 4) do_logs;; 5) do_modify;; 6) do_ssl;; 7) do_uninstall;; 0) echo -e "${GREEN}再见！${NC}"; exit 0;; *) echo -e "${RED}无效${NC}";; esac
    echo ""
done
