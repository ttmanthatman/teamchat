#!/bin/bash
#===============================================================================
# TeamChat 一键部署脚本 (全功能增强版 v8.2)
# 变更: 新增登录页背景定制(渐变/纯色/图片)，含实时预览
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
    echo -e "${CYAN}  TeamChat 一键部署脚本 v8.2${NC}"
    echo -e "${CYAN}================================================${NC}\n"
}

print_menu() {
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}  请选择操作:${NC}"
    echo -e "${BLUE}================================================${NC}"
    echo -e "  ${GREEN}1${NC}. 安装/更新程序"
    echo -e "  ${GREEN}2${NC}. 启动/重启服务"
    echo -e "  ${GREEN}3${NC}. 停止服务"
    echo -e "  ${GREEN}4${NC}. 查看运行日志"
    echo -e "  ${GREEN}5${NC}. 修改配置参数"
    echo -e "  ${GREEN}6${NC}. 配置 SSL/HTTPS"
    echo -e "  ${GREEN}7${NC}. 卸载程序"
    echo -e "  ${GREEN}8${NC}. 多实例管理"
    echo -e "  ${GREEN}0${NC}. 退出"
    echo -e "${BLUE}================================================${NC}"
    echo -n "请输入选项 [0-8]: "
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
  "id": "/",
  "start_url": "/",
  "scope": "/",
  "display": "standalone",
  "background_color": "#667eea",
  "theme_color": "#667eea",
  "icons": [
    {
      "src": "/images/icon-192.png",
      "sizes": "192x192",
      "type": "image/png",
      "purpose": "any"
    },
    {
      "src": "/images/icon-512.png",
      "sizes": "512x512",
      "type": "image/png",
      "purpose": "any"
    },
    {
      "src": "/images/icon-maskable-192.png",
      "sizes": "192x192",
      "type": "image/png",
      "purpose": "maskable"
    },
    {
      "src": "/images/icon-maskable-512.png",
      "sizes": "512x512",
      "type": "image/png",
      "purpose": "maskable"
    }
  ]
}
MANIFESTEOF

    # 生成简易 PWA 图标 (SVG 转 inline，浏览器兼容)
    cat > "$APP_DIR/public/images/icon-192.svg" <<'ICONEOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 192 192"><rect width="192" height="192" rx="40" fill="#667eea"/><text x="96" y="120" font-size="90" text-anchor="middle" fill="white" font-family="Arial">💬</text></svg>
ICONEOF
    cp "$APP_DIR/public/images/icon-192.svg" "$APP_DIR/public/images/icon-512.svg"

    # 生成正确尺寸的 PWA 图标 (使用 Node.js 生成真正的 PNG 文件)
    cd "$APP_DIR" && node -e '
const fs = require("fs");
const zlib = require("zlib");

function createPNG(width, height, bgR, bgG, bgB, hasCircle) {
  // 创建 RGBA raw pixel data
  const pixels = Buffer.alloc(width * height * 4);
  const cx = width / 2, cy = height / 2;
  const outerR = Math.min(width, height) * 0.42;
  const iconR = Math.min(width, height) * 0.22;

  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const idx = (y * width + x) * 4;
      const dx = x - cx, dy = y - cy;
      const dist = Math.sqrt(dx * dx + dy * dy);

      if (hasCircle && dist <= outerR) {
        // 白circle area for chat icon
        if (dist <= iconR) {
          pixels[idx] = 255; pixels[idx+1] = 255; pixels[idx+2] = 255; pixels[idx+3] = 255;
        } else {
          pixels[idx] = bgR; pixels[idx+1] = bgG; pixels[idx+2] = bgB; pixels[idx+3] = 255;
        }
      } else {
        pixels[idx] = bgR; pixels[idx+1] = bgG; pixels[idx+2] = bgB; pixels[idx+3] = 255;
      }
    }
  }

  // Draw a simple chat bubble shape in white
  const bubbleW = width * 0.5, bubbleH = height * 0.35;
  const bx1 = cx - bubbleW/2, by1 = cy - bubbleH/2 - height*0.05;
  const bx2 = cx + bubbleW/2, by2 = cy + bubbleH/2 - height*0.05;
  const cornerR = Math.min(bubbleW, bubbleH) * 0.25;

  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const idx = (y * width + x) * 4;
      let inside = false;
      // Rounded rectangle check
      if (x >= bx1 && x <= bx2 && y >= by1 && y <= by2) {
        const lx = Math.max(bx1 + cornerR - x, 0, x - (bx2 - cornerR));
        const ly = Math.max(by1 + cornerR - y, 0, y - (by2 - cornerR));
        inside = (lx * lx + ly * ly) <= cornerR * cornerR;
        if (x >= bx1 + cornerR && x <= bx2 - cornerR) inside = true;
        if (y >= by1 + cornerR && y <= by2 - cornerR) inside = true;
      }
      // Triangle tail
      const tailCx = cx + bubbleW * 0.1;
      const tailTy = by2;
      const tailBy = by2 + height * 0.1;
      const tailW = bubbleW * 0.15;
      if (y >= tailTy && y <= tailBy) {
        const frac = (y - tailTy) / (tailBy - tailTy);
        const tw = tailW * (1 - frac);
        if (x >= tailCx - tw/2 && x <= tailCx + tw/2) inside = true;
      }
      if (inside) {
        pixels[idx] = 255; pixels[idx+1] = 255; pixels[idx+2] = 255; pixels[idx+3] = 255;
      }
    }
  }

  // Encode as PNG
  // Filter: 0 (None) for each row
  const rawData = Buffer.alloc(height * (1 + width * 4));
  for (let y = 0; y < height; y++) {
    rawData[y * (1 + width * 4)] = 0; // filter byte
    pixels.copy(rawData, y * (1 + width * 4) + 1, y * width * 4, (y + 1) * width * 4);
  }

  const compressed = zlib.deflateSync(rawData, { level: 9 });

  function crc32(buf) {
    let crc = 0xFFFFFFFF;
    for (let i = 0; i < buf.length; i++) {
      crc ^= buf[i];
      for (let j = 0; j < 8; j++) crc = (crc >>> 1) ^ (crc & 1 ? 0xEDB88320 : 0);
    }
    return (crc ^ 0xFFFFFFFF) >>> 0;
  }

  function chunk(type, data) {
    const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
    const typeData = Buffer.concat([Buffer.from(type), data]);
    const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(typeData));
    return Buffer.concat([len, typeData, crc]);
  }

  const sig = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 6; // RGBA
  ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;

  return Buffer.concat([sig, chunk("IHDR", ihdr), chunk("IDAT", compressed), chunk("IEND", Buffer.alloc(0))]);
}

// 主色: #667eea -> RGB(102, 126, 234)
const sizes = [192, 512];
for (const s of sizes) {
  const png = createPNG(s, s, 102, 126, 234, false);
  fs.writeFileSync("public/images/icon-" + s + ".png", png);
  fs.writeFileSync("public/images/icon-maskable-" + s + ".png", png);
  console.log("✅ 已生成 " + s + "x" + s + " PNG 图标");
}
// 生成一个小尺寸通知图标
const notifIcon = createPNG(96, 96, 102, 126, 234, false);
fs.writeFileSync("public/images/icon-96.png", notifIcon);
console.log("✅ 已生成 96x96 通知图标");
' 2>/dev/null || echo -e "${YELLOW}PNG 图标生成失败，将使用 SVG 回退${NC}"

    # ===== Service Worker =====
    cat > "$APP_DIR/public/sw.js" <<'SWEOF'
// TeamChat Service Worker - PWA + 推送通知 (iOS/Android 双平台兼容)

// 缓存版本号 - 更新文件时递增
var CACHE_NAME = "teamchat-v4";
var OFFLINE_URLS = ["/", "/index.html", "/style.css", "/app.js", "/images/icon-192.png", "/images/icon-96.png", "/images/default-avatar.svg"];

// ===== 安装: 预缓存关键资源 (iOS 需要缓存才能正确识别 PWA) =====
self.addEventListener("install", function(event) {
  event.waitUntil(
    caches.open(CACHE_NAME).then(function(cache) {
      return cache.addAll(OFFLINE_URLS);
    }).then(function() {
      return self.skipWaiting();
    })
  );
});

// ===== 激活: 清理旧缓存 =====
self.addEventListener("activate", function(event) {
  event.waitUntil(
    caches.keys().then(function(names) {
      return Promise.all(
        names.filter(function(n) { return n !== CACHE_NAME; })
             .map(function(n) { return caches.delete(n); })
      );
    }).then(function() {
      return self.clients.claim();
    })
  );
});

// ===== Fetch: Network-first 策略 (iOS 必须有 fetch handler 才能正常注册 PWA) =====
self.addEventListener("fetch", function(event) {
  var req = event.request;
  // 只处理 GET 请求的同源资源
  if (req.method !== "GET") return;
  // 跳过 API 和 Socket.IO 请求
  if (req.url.indexOf("/api/") !== -1 || req.url.indexOf("/socket.io/") !== -1) return;
  // 跳过 chrome-extension 等非 http(s) 请求
  if (!req.url.startsWith("http")) return;

  event.respondWith(
    fetch(req).then(function(response) {
      // 成功获取网络响应，更新缓存
      if (response && response.status === 200 && response.type === "basic") {
        var clone = response.clone();
        caches.open(CACHE_NAME).then(function(cache) {
          cache.put(req, clone);
        });
      }
      return response;
    }).catch(function() {
      // 网络失败，从缓存返回
      return caches.match(req).then(function(cached) {
        if (cached) return cached;
        // 对导航请求返回离线首页
        if (req.mode === "navigate") return caches.match("/index.html");
        return new Response("Offline", { status: 503, statusText: "Offline" });
      });
    })
  );
});

// ===== Push: 接收推送消息并显示通知 =====
self.addEventListener("push", function(event) {
  var data = { title: "TeamChat", body: "您有新消息", icon: "/images/icon-192.png", badge: "/images/icon-96.png" };
  try {
    if (event.data) {
      var payload = event.data.json();
      data.title = payload.title || data.title;
      data.body = payload.body || data.body;
      if (payload.icon) data.icon = payload.icon;
      data.data = payload.data || {};
    }
  } catch(e) {
    if (event.data) data.body = event.data.text();
  }

  var options = {
    body: data.body,
    icon: data.icon,
    badge: data.badge,
    vibrate: [200, 100, 200],
    data: data.data || {},
    tag: "teamchat-" + Date.now(),
    renotify: true,
    requireInteraction: false
  };

  event.waitUntil(
    self.registration.showNotification(data.title, options)
  );
});

// ===== 通知点击 =====
self.addEventListener("notificationclick", function(event) {
  event.notification.close();
  var urlToOpen = (event.notification.data && event.notification.data.url) ? event.notification.data.url : "/";

  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then(function(clientList) {
      // 如果已有窗口打开，聚焦它
      for (var i = 0; i < clientList.length; i++) {
        var client = clientList[i];
        if (client.url.indexOf(self.location.origin) !== -1 && "focus" in client) {
          return client.focus();
        }
      }
      // 否则打开新窗口
      if (self.clients.openWindow) return self.clients.openWindow(urlToOpen);
    })
  );
});

// ===== 订阅变更: 当推送订阅过期或被浏览器更新时自动重新订阅 (iOS 重要) =====
self.addEventListener("pushsubscriptionchange", function(event) {
  event.waitUntil(
    self.registration.pushManager.subscribe(event.oldSubscription.options).then(function(newSub) {
      return fetch("/api/push/renew", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ subscription: newSub.toJSON(), oldEndpoint: event.oldSubscription ? event.oldSubscription.endpoint : null })
      });
    })
  );
});
SWEOF

    # ===== index.html =====
    cat > "$APP_DIR/public/index.html" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover">
  <meta name="apple-mobile-web-app-capable" content="yes">
  <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
  <meta name="apple-mobile-web-app-title" content="TeamChat">
  <meta name="theme-color" content="#667eea">
  <link rel="manifest" href="/manifest.json">
  <link rel="apple-touch-icon" href="/images/icon-192.png">
  <link rel="icon" type="image/png" sizes="192x192" href="/images/icon-192.png">
  <link rel="icon" type="image/png" sizes="96x96" href="/images/icon-96.png">
  <title>团队聊天室</title>
  <link rel="stylesheet" href="style.css?v=20260331">
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
      <form id="registerForm" class="hidden">
        <input type="text" id="regUsername" placeholder="用户名 (字母数字下划线)" required>
        <input type="text" id="regNickname" placeholder="昵称 (选填)">
        <input type="password" id="regPassword" placeholder="密码 (至少6位)" required>
        <input type="password" id="regPassword2" placeholder="确认密码" required>
        <button type="submit">注册</button>
      </form>
      <p id="loginError" class="error"></p>
      <p id="regToggle" class="reg-toggle hidden"><a href="#" id="toggleRegLink">还没有账号？注册一个</a></p>
    </div>
  </div>

  <div id="chatPage" class="page hidden">
    <header class="chat-header">
      <div class="header-left">
        <h2 id="chatTitle">团队聊天</h2>
        <span id="onlineCount">0 人在线</span>
        <span id="tzIndicator" class="tz-indicator" title="消息显示时区"></span>
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
    <div id="messagesWrapper" class="messages-wrapper">
      <div id="messages" class="messages"><div class="load-more" onclick="loadMoreMessages()">加载更多</div></div>
    </div>
    <div class="input-area">
      <button id="attachBtn" class="attach-btn" title="添加附件">📎</button>
      <input type="file" id="fileInput" hidden onchange="handleFileUpload(this)">
      <textarea id="messageInput" class="text-input" placeholder="输入消息... (Shift+Enter 换行)" rows="1" enterkeyhint="send" onkeydown="handleKeyDown(event)"></textarea>
      <button id="newlineBtn" class="newline-btn" title="换行" onmousedown="event.preventDefault()" onclick="insertNewline()">⏎</button>
      <button id="chainBtn" class="chain-btn-inline" onclick="showChainDialog()" title="发起接龙">🚂</button>
      <button onmousedown="event.preventDefault()" onclick="sendMessage()" class="send-btn" id="sendBtn">发送</button>
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
            📱 iOS 用户：请先点击 Safari 底部的"分享"按钮 → "添加到主屏幕"，然后从主屏幕图标打开本应用，再来此处开启推送通知。需要 iOS 16.4 或更高版本。
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
        <button onclick="toggleRegistration()" class="admin-btn" id="regToggleBtn">📝 开放注册</button>
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
        <textarea id="noticeContentInput" placeholder="输入置顶通知内容..." rows="5" style="width:100%;padding:12px;border:1px solid #ddd;border-radius:8px;font-size:16px;resize:vertical;font-family:inherit"></textarea>
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
        <h4>登录页背景</h4>
        <label class="field-label">背景类型</label>
        <div class="radio-group">
          <label><input type="radio" name="loginBgType" value="gradient" checked onchange="toggleLoginBgType()"> 渐变</label>
          <label><input type="radio" name="loginBgType" value="color" onchange="toggleLoginBgType()"> 纯色</label>
          <label><input type="radio" name="loginBgType" value="image" onchange="toggleLoginBgType()"> 图片</label>
        </div>
        <div id="loginBgGradientSection">
          <label class="field-label">渐变色 1</label>
          <div class="color-row">
            <input type="color" id="appLoginBgColor1" value="#667eea">
            <span id="appLoginBgColor1Hex" class="color-hex">#667eea</span>
          </div>
          <label class="field-label">渐变色 2</label>
          <div class="color-row">
            <input type="color" id="appLoginBgColor2" value="#764ba2">
            <span id="appLoginBgColor2Hex" class="color-hex">#764ba2</span>
          </div>
        </div>
        <div id="loginBgColorSection" class="hidden">
          <label class="field-label">背景颜色</label>
          <div class="color-row">
            <input type="color" id="appLoginBgSolid" value="#667eea">
            <span id="appLoginBgSolidHex" class="color-hex">#667eea</span>
          </div>
        </div>
        <div id="loginBgImageSection" class="hidden">
          <label class="field-label">背景图片</label>
          <div class="bg-preview-area">
            <img id="loginBgPreview" src="" alt="预览" class="bg-preview hidden">
            <span id="loginBgFileName" class="bg-filename">未选择图片</span>
          </div>
          <input type="file" id="loginBgImageInput" accept="image/*" style="display:none" onchange="handleLoginBgUpload(this)">
          <button onclick="document.getElementById('loginBgImageInput').click()" class="admin-btn" style="margin-top:8px">选择图片</button>
          <label class="field-label" style="margin-top:12px">显示方式</label>
          <select id="appLoginBgMode">
            <option value="cover">填充 (cover)</option>
            <option value="contain">适应 (contain)</option>
            <option value="stretch">拉伸 (stretch)</option>
            <option value="tile">平铺 (tile)</option>
          </select>
        </div>
        <div id="loginBgLivePreview" class="live-preview" style="margin-top:12px">
          <div class="preview-label">登录页预览</div>
          <div id="loginPreviewArea" style="border-radius:8px;padding:20px;min-height:80px;display:flex;align-items:center;justify-content:center;background:linear-gradient(135deg,#667eea 0%,#764ba2 100%)">
            <div style="background:#fff;padding:16px 24px;border-radius:12px;box-shadow:0 4px 16px rgba(0,0,0,.15);text-align:center;font-size:14px;color:#333">登录预览</div>
          </div>
        </div>
      </div>
      <div class="settings-section">
        <h4>聊天背景</h4>
        <label class="field-label">背景类型</label>
        <div class="radio-group">
          <label><input type="radio" name="bgType" value="color" checked onchange="toggleBgType()"> 纯色</label>
          <label><input type="radio" name="bgType" value="image" onchange="toggleBgType()"> 图片</label>
          <label><input type="radio" name="bgType" value="video" onchange="toggleBgType()"> 视频</label>
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
        <div id="bgVideoSection" class="hidden">
          <label class="field-label">YouTube 视频链接</label>
          <input type="text" id="appBgVideoUrl" placeholder="https://www.youtube.com/watch?v=..." oninput="updateLivePreview()">
          <div style="text-align:center;color:#999;font-size:13px;margin:10px 0">— 或 —</div>
          <label class="field-label">上传本地视频</label>
          <div class="bg-preview-area">
            <span id="bgVideoFileName" class="bg-filename">未选择视频</span>
          </div>
          <input type="file" id="bgVideoInput" accept="video/mp4,video/quicktime,video/webm,video/x-m4v" style="display:none" onchange="handleBgVideoUpload(this)">
          <button onclick="document.getElementById('bgVideoInput').click()" class="admin-btn" style="margin-top:8px">选择视频</button>
          <label class="field-label" style="margin-top:12px">视频铺满方式</label>
          <select id="appBgVideoMode">
            <option value="cover">填充裁剪 (cover)</option>
            <option value="contain">完整显示 (contain)</option>
            <option value="stretch">拉伸铺满 (stretch)</option>
          </select>
          <p style="font-size:12px;color:#999;margin-top:8px">支持 mp4/mov/webm 格式，最大 100MB。YouTube 视频自动静音循环播放。</p>
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
      <div id="resetPwdSection" class="settings-section hidden" style="margin-top:16px">
        <h4>🔑 重置用户密码</h4>
        <p id="resetPwdTarget" style="font-size:13px;color:#666;margin-bottom:8px"></p>
        <input type="password" id="resetPwdInput" placeholder="新密码 (至少6位)">
        <button onclick="doResetPassword()">确认重置</button>
        <button onclick="cancelResetPassword()" class="close-btn" style="margin-top:4px">取消</button>
        <p id="resetPwdMsg" style="font-size:13px;margin-top:8px"></p>
      </div>
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

  <!-- 接龙发起弹窗 -->
  <div id="chainModal" class="modal hidden">
    <div class="modal-content" style="max-width:400px">
      <h3>🚂 发起接龙</h3>
      <div style="margin:12px 0">
        <label style="font-size:14px;color:#555;display:block;margin-bottom:6px">接龙话题</label>
        <input type="text" id="chainTopic" placeholder="例如：明天团建午餐吃什么？" style="width:100%;padding:10px 12px;border:1px solid #ddd;border-radius:8px;font-size:15px;box-sizing:border-box">
      </div>
      <div style="margin:12px 0">
        <label style="font-size:14px;color:#555;display:block;margin-bottom:6px">补充说明（可选）</label>
        <textarea id="chainDesc" placeholder="可填写规则、选项等补充信息..." rows="3" style="width:100%;padding:10px 12px;border:1px solid #ddd;border-radius:8px;font-size:14px;resize:vertical;box-sizing:border-box"></textarea>
      </div>
      <div style="margin:12px 0">
        <label style="font-size:14px;color:#555;display:block;margin-bottom:6px">你的昵称</label>
        <input type="text" id="chainNickname" placeholder="显示在接龙列表中的名字" style="width:100%;padding:10px 12px;border:1px solid #ddd;border-radius:8px;font-size:15px;box-sizing:border-box">
      </div>
      <div class="chain-modal-actions">
        <button onclick="closeChainDialog()" class="chain-cancel-btn">取消</button>
        <button onclick="sendChainMessage()" class="chain-submit-btn">发起</button>
      </div>
    </div>
  </div>

  <script src="https://cdn.socket.io/4.7.2/socket.io.min.js"></script>
  <script src="app.js?v=20260331"></script>
</body>
</html>
HTMLEOF

    # ===== style.css =====
    cat > "$APP_DIR/public/style.css" <<'CSSEOF'
*{margin:0;padding:0;box-sizing:border-box}
html{touch-action:manipulation;-webkit-text-size-adjust:100%;text-size-adjust:100%}
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;background:#f5f5f5;height:100vh;overflow:hidden;-webkit-overflow-scrolling:touch}
.page{width:100%;height:100vh;display:flex;flex-direction:column}
.hidden{display:none!important}
#loginPage{justify-content:center;align-items:center;background:linear-gradient(135deg,#667eea 0%,#764ba2 100%);background-size:cover;background-position:center;background-repeat:no-repeat}
.login-card{background:#fff;padding:40px;border-radius:16px;box-shadow:0 10px 40px rgba(0,0,0,.2);width:90%;max-width:400px}
.login-card h1{text-align:center;margin-bottom:30px;color:#333}
.login-card input{width:100%;padding:14px;margin-bottom:16px;border:1px solid #ddd;border-radius:8px;font-size:16px}
.login-card button{width:100%;padding:14px;background:#667eea;color:#fff;border:none;border-radius:8px;font-size:16px;cursor:pointer;margin-bottom:10px}
.reg-toggle{text-align:center;margin-top:12px;font-size:14px}.reg-toggle a{color:#667eea;text-decoration:none}.reg-toggle a:hover{text-decoration:underline}
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
.messages-wrapper{flex:1;min-height:0;position:relative;overflow:hidden;display:flex;flex-direction:column}
.messages-wrapper>.bg-video-layer,.preview-messages>.bg-video-layer{position:absolute;top:0;left:0;width:100%;height:100%;z-index:0;pointer-events:none;overflow:hidden}
.bg-video-layer>video{width:100%;height:100%;object-fit:cover;display:block}
.bg-video-layer>iframe{border:none}
.bg-video-layer.fit-cover>iframe{position:absolute;top:50%;left:50%;width:300%;height:300%;transform:translate(-50%,-50%);min-width:100%;min-height:100%}
.bg-video-layer.fit-contain>iframe{width:100%;height:100%}
.bg-video-layer.fit-contain>video{object-fit:contain}
.bg-video-layer.fit-stretch>iframe{width:100%;height:100%}
.bg-video-layer.fit-stretch>video{object-fit:fill}
.messages{flex:1;overflow-y:auto;padding:16px;display:flex;flex-direction:column;gap:12px;min-height:0;background-color:#f5f5f5;background-position:center;transition:background-color .3s;position:relative;z-index:1}
.messages>*{position:relative;z-index:1}
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
.message .content{white-space:pre-wrap;word-break:break-word;line-height:1.5}
.message .content b,.message .content strong{font-weight:700}
.message .content i,.message .content em{font-style:italic}
.message .content u{text-decoration:underline}
.message .content s,.message .content strike{text-decoration:line-through}
.input-area{background:#fff;padding:12px 16px;display:flex;gap:10px;align-items:flex-end;box-shadow:0 -2px 8px rgba(0,0,0,.05);flex-shrink:0}
.input-area input[type="text"]{flex:1;padding:12px 16px;border:1px solid #ddd;border-radius:24px;font-size:16px;outline:none}
/* Textarea input */
.text-input{flex:1;min-height:24px;max-height:120px;padding:10px 16px;border:1px solid #ddd;border-radius:16px;font-size:16px;outline:none;overflow-y:auto;resize:none;line-height:1.5;font-family:inherit;-webkit-appearance:none;background:#fff}
.text-input:focus{border-color:#667eea;box-shadow:0 0 0 2px rgba(102,126,234,.15)}
.attach-btn,.send-btn{height:44px;border-radius:22px;border:none;font-size:15px;cursor:pointer;display:flex;align-items:center;justify-content:center;flex-shrink:0}
.attach-btn{width:44px;background:#f0f0f0;font-size:20px}.send-btn{min-width:44px;padding:0 18px;background:#667eea;color:#fff;font-weight:500;white-space:nowrap}
.chain-btn-inline{width:44px;height:44px;border-radius:22px;border:none;background:#f0f0f0;font-size:20px;cursor:pointer;display:flex;align-items:center;justify-content:center;flex-shrink:0;transition:background .15s}
.chain-btn-inline:hover{background:#e0e4f8}
.newline-btn{width:44px;height:44px;border-radius:22px;border:none;background:#f0f0f0;font-size:18px;cursor:pointer;display:none;align-items:center;justify-content:center;flex-shrink:0;transition:background .15s;color:#666;font-weight:700}
.newline-btn:hover{background:#e0e4f8}
@media screen and (max-width:768px){.newline-btn{display:flex}}
.reply-box{background:#f0f2ff;padding:8px 16px;display:flex;align-items:center;gap:8px;font-size:13px;color:#555;border-left:3px solid #667eea}
.reply-box .reply-label{font-weight:600;color:#667eea;white-space:nowrap}
.reply-box .reply-content{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.reply-box .reply-cancel{background:none;border:none;font-size:16px;cursor:pointer;color:#999;padding:0 4px;width:auto;min-width:24px}
.reply-preview{background:rgba(0,0,0,.06);padding:4px 8px;border-radius:6px;margin-bottom:4px;font-size:12px;border-left:2px solid #667eea;color:#666;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.reply-preview .reply-name{font-weight:600}
.message-menu{background:#fff;border-radius:8px;box-shadow:0 4px 16px rgba(0,0,0,.15);z-index:2000;overflow:hidden;min-width:140px}
.message-menu .menu-item{padding:10px 16px;cursor:pointer;font-size:14px;transition:background .15s}
.message-menu .menu-item:hover{background:#f0f2ff}
/* 接龙 (Chain) styles */
.chain-card{background:linear-gradient(135deg,#f0f4ff 0%,#e8eeff 100%);border:1px solid #c7d2fe;border-radius:12px;padding:12px;margin-top:4px}
.chain-card .chain-header{display:flex;align-items:center;gap:6px;font-size:13px;font-weight:700;color:#4f46e5;margin-bottom:8px}
.chain-card .chain-topic{font-size:15px;font-weight:600;color:#1e1b4b;margin-bottom:4px}
.chain-card .chain-desc{font-size:13px;color:#555;margin-bottom:8px;line-height:1.4}
.chain-card .chain-list{font-size:14px;line-height:1.8;color:#333}
.chain-card .chain-list .chain-item{padding:2px 0}
.chain-card .chain-list .chain-seq{display:inline-block;min-width:22px;height:22px;line-height:22px;text-align:center;background:#667eea;color:#fff;border-radius:50%;font-size:11px;font-weight:700;margin-right:6px;vertical-align:middle}
.chain-card .chain-list .chain-name{font-weight:600;color:#4338ca}
.chain-join-btn{display:inline-flex;align-items:center;gap:4px;margin-top:10px;padding:6px 14px;background:#667eea;color:#fff;border:none;border-radius:20px;font-size:13px;font-weight:600;cursor:pointer;transition:all .2s;box-shadow:0 2px 6px rgba(102,126,234,.3)}
.chain-join-btn:hover{background:#5567d8;transform:translateY(-1px)}
.chain-join-btn:active{transform:translateY(0)}
.chain-join-btn.joined{background:#10b981}
.message.my .chain-card{background:linear-gradient(135deg,rgba(255,255,255,.2) 0%,rgba(255,255,255,.1) 100%);border-color:rgba(255,255,255,.3)}
.message.my .chain-card .chain-header{color:rgba(255,255,255,.9)}
.message.my .chain-card .chain-topic{color:#fff}
.message.my .chain-card .chain-desc{color:rgba(255,255,255,.8)}
.message.my .chain-card .chain-list{color:rgba(255,255,255,.95)}
.message.my .chain-card .chain-list .chain-seq{background:rgba(255,255,255,.3);color:#fff}
.message.my .chain-card .chain-list .chain-name{color:rgba(255,255,255,.95)}
.message.my .chain-join-btn{background:rgba(255,255,255,.25);color:#fff}
.message.my .chain-join-btn:hover{background:rgba(255,255,255,.35)}
.chain-modal-actions{display:flex;gap:10px;justify-content:flex-end;margin-top:16px}
.chain-modal-actions button{width:auto!important;margin-bottom:0!important;padding:8px 24px!important;font-size:14px}
.chain-cancel-btn{background:#fff!important;color:#333!important;border:1px solid #ddd!important;border-radius:8px}
.chain-cancel-btn:hover{background:#f5f5f5!important}
.chain-submit-btn{background:#667eea!important;color:#fff!important;border:none!important;border-radius:8px;font-weight:600}
.modal{position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,.5);display:flex;justify-content:center;align-items:center;z-index:1000}
.modal-content{background:#fff;padding:24px;border-radius:16px;width:90%;max-width:450px;max-height:80vh;overflow-y:auto}
.modal-wide{max-width:520px}
.modal-content h3{margin-bottom:20px;text-align:center}
.modal-content h4{margin:16px 0 10px;font-size:14px;color:#666}
.modal-content input[type="text"],.modal-content input[type="password"],.modal-content input[type="date"],.modal-content select{width:100%;padding:12px;margin-bottom:10px;border:1px solid #ddd;border-radius:8px;font-size:16px}
.modal-content button{width:100%;padding:12px;background:#667eea;color:#fff;border:none;border-radius:8px;font-size:14px;cursor:pointer;margin-bottom:10px}
.modal-content button.danger{background:#dc2626}.modal-content button.admin-btn{background:#10b981}
.close-btn{background:#f0f0f0!important;color:#333!important}
.danger-btn{width:100%;padding:12px;background:#dc2626;color:#fff;border:none;border-radius:8px;font-size:14px;cursor:pointer;margin-bottom:10px}
.danger-text{color:#dc2626;text-align:center;margin-bottom:16px}
.settings-section{margin-bottom:20px;padding-bottom:20px;border-bottom:1px solid #eee}
.field-label{display:block;font-size:13px;color:#555;margin-bottom:6px;font-weight:500}
.timezone-setting{margin-bottom:14px}.timezone-setting label{display:block;font-size:13px;color:#555;margin-bottom:6px}
.timezone-setting select{width:100%;padding:10px;border:1px solid #ddd;border-radius:8px;font-size:16px;background:#fff}
.tz-indicator{font-size:11px;color:rgba(255,255,255,.7);background:rgba(0,0,0,.15);padding:2px 8px;border-radius:10px;white-space:nowrap}
.add-user{display:flex;flex-direction:column;gap:8px;margin-bottom:16px}
.user-list{max-height:200px;overflow-y:auto}
.user-item{display:flex;justify-content:space-between;align-items:center;padding:10px;background:#f9f9f9;border-radius:8px;margin-bottom:8px}
.user-item .username{font-weight:600}.user-item .nickname{font-size:12px;color:#666}
.user-item .delete-btn{background:#dc2626;color:#fff;border:none;padding:6px 12px;border-radius:6px;cursor:pointer;font-size:12px}
.user-item .reset-pwd-btn{background:#f59e0b;color:#fff;border:none;padding:6px 12px;border-radius:6px;cursor:pointer;font-size:12px}
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
.preview-messages{padding:16px;min-height:100px;display:flex;flex-direction:column;gap:10px;background-color:#f5f5f5;background-position:center;transition:background-color .3s;position:relative;overflow:hidden}
.preview-messages>*{position:relative;z-index:1}
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
function sanitizeIncoming(html){
  if(!html)return '';
  // If content has no HTML tags, treat as plain text (backward compat)
  if(!/<[a-zA-Z]/.test(html)){
    const s=escapeHtml(html);
    return s.replace(/(https?:\/\/[^\s&lt;]+)/g,'<a href="$1" target="_blank" rel="noopener">$1</a>');
  }
  const tmp=document.createElement('div');tmp.innerHTML=html;
  tmp.querySelectorAll('script,style,link,meta,iframe,object,embed').forEach(el=>el.remove());
  const allowed={'B':1,'STRONG':1,'I':1,'EM':1,'U':1,'S':1,'STRIKE':1,'SPAN':1,'FONT':1,'BR':1,'A':1};
  const allowedAttrs={'style':1,'color':1,'href':1,'target':1,'rel':1};
  function walk(node){
    [...node.childNodes].forEach(ch=>{
      if(ch.nodeType===1){
        if(!allowed[ch.tagName]){while(ch.firstChild)ch.parentNode.insertBefore(ch.firstChild,ch);ch.remove()}
        else{
          [...ch.attributes].forEach(a=>{if(!allowedAttrs[a.name])ch.removeAttribute(a.name)});
          if(ch.style){
            const s=ch.style;const safe={};
            if(s.color)safe.color=s.color;if(s.backgroundColor)safe['background-color']=s.backgroundColor;
            if(s.fontWeight)safe['font-weight']=s.fontWeight;if(s.fontStyle)safe['font-style']=s.fontStyle;
            if(s.textDecoration||s.textDecorationLine)safe['text-decoration']=s.textDecoration||s.textDecorationLine;
            ch.removeAttribute('style');
            const ss=Object.entries(safe).map(([k,v])=>k+':'+v).join(';');
            if(ss)ch.setAttribute('style',ss);
          }
          // For <a> tags, ensure safe attributes
          if(ch.tagName==='A'){ch.setAttribute('target','_blank');ch.setAttribute('rel','noopener')}
          walk(ch);
        }
      }
    });
  }
  walk(tmp);
  // Auto-link bare URLs in text nodes
  const tw=document.createTreeWalker(tmp,NodeFilter.SHOW_TEXT,null,false);
  const textNodes=[];while(tw.nextNode())textNodes.push(tw.currentNode);
  textNodes.forEach(tn=>{
    if(tn.parentNode&&tn.parentNode.tagName==='A')return;
    const urlRe=/(https?:\/\/[^\s<]+)/g;
    if(urlRe.test(tn.textContent)){
      const frag=document.createDocumentFragment();
      let lastIdx=0;tn.textContent.replace(urlRe,(m,_,offset)=>{
        if(offset>lastIdx)frag.appendChild(document.createTextNode(tn.textContent.slice(lastIdx,offset)));
        const a=document.createElement('a');a.href=m;a.target='_blank';a.rel='noopener';a.textContent=m;frag.appendChild(a);
        lastIdx=offset+m.length;
      });
      if(lastIdx<tn.textContent.length)frag.appendChild(document.createTextNode(tn.textContent.slice(lastIdx)));
      tn.parentNode.replaceChild(frag,tn);
    }
  });
  return tmp.innerHTML;
}
function authHeaders(x){const h={'Authorization':'Bearer '+(currentUser?currentUser.token:'')};return Object.assign(h,x||{})}

// 确保时间戳被当作 UTC 解析 (SQLite CURRENT_TIMESTAMP 无时区后缀)
function parseUTC(ts){
  if(!ts)return new Date();
  if(ts.endsWith('Z')||/[+-]\d{2}:\d{2}$/.test(ts))return new Date(ts);
  return new Date(ts.replace(' ','T')+'Z');
}
function formatTime(ts){return parseUTC(ts).toLocaleString('zh-CN',{timeZone:chatTimezone,year:'numeric',month:'long',day:'numeric',hour:'2-digit',minute:'2-digit',second:'2-digit'})}

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
    swRegistration=await navigator.serviceWorker.register('/sw.js',{updateViaCache:'none'});
    // 强制检查 SW 更新
    swRegistration.update().catch(function(){});
    // 等待 SW 激活 (iOS 首次安装后需要)
    if(swRegistration.installing){
      await new Promise(function(resolve){
        swRegistration.installing.addEventListener('statechange',function(e){
          if(e.target.state==='activated')resolve();
        });
        setTimeout(resolve,5000);// 超时保护
      });
    }else if(swRegistration.waiting){
      // 如果有等待中的 SW，通知它立即接管
      swRegistration.waiting.postMessage({type:'SKIP_WAITING'});
    }
    // 确保我们有一个 active SW
    if(!swRegistration.active){
      await navigator.serviceWorker.ready;
      swRegistration=await navigator.serviceWorker.getRegistration();
    }
    console.log('Service Worker registered and active');
  }catch(e){console.error('SW registration failed:',e)}
}

function detectPushSupport(){
  const statusEl=document.getElementById('pushStatus');
  const btnEl=document.getElementById('pushToggleBtn');
  const iosHint=document.getElementById('pushIosHint');
  const isIos=/iPad|iPhone|iPod/.test(navigator.userAgent)&&!window.MSStream;
  const isStandalone=window.matchMedia('(display-mode: standalone)').matches||navigator.standalone===true;

  // 检查基本能力
  if(!('serviceWorker' in navigator)){
    statusEl.textContent='您的浏览器不支持 Service Worker';
    if(isIos)iosHint.classList.remove('hidden');
    return;
  }

  if(!('PushManager' in window)){
    if(isIos&&!isStandalone){
      statusEl.textContent='请先将此页面"添加到主屏幕"，再从主屏图标打开';
      iosHint.classList.remove('hidden');
    }else if(isIos&&isStandalone){
      statusEl.textContent='当前 iOS 版本不支持推送，需要 iOS 16.4 或更高';
      iosHint.classList.remove('hidden');
    }else{
      statusEl.textContent='您的浏览器不支持推送通知';
    }
    return;
  }

  // iOS 在 Safari 浏览器中（非 standalone）不支持 push
  if(isIos&&!isStandalone){
    statusEl.textContent='iOS 需要添加到主屏幕后才能推送';
    iosHint.classList.remove('hidden');
    // 不显示按钮，避免误操作
    return;
  }

  // 检查通知权限状态
  if('Notification' in window&&Notification.permission==='denied'){
    statusEl.textContent='通知权限已被拒绝，请在系统设置中允许本站通知';
    return;
  }

  checkCurrentSubscription();
}

async function checkCurrentSubscription(){
  const statusEl=document.getElementById('pushStatus');
  const btnEl=document.getElementById('pushToggleBtn');
  if(!swRegistration){await initServiceWorker()}
  if(!swRegistration){statusEl.textContent='Service Worker 未就绪';return}
  try{
    // 确保 SW 已激活
    const reg=await navigator.serviceWorker.ready;
    if(reg)swRegistration=reg;
    const sub=await swRegistration.pushManager.getSubscription();
    if(sub){
      pushSubscription=sub;
      // 每次检查时同步订阅到服务器 (确保重启后服务器仍有记录)
      if(currentUser&&currentUser.token){
        fetch(API_BASE+'/api/push/subscribe',{
          method:'POST',
          headers:authHeaders({'Content-Type':'application/json'}),
          body:JSON.stringify({subscription:sub.toJSON()})
        }).catch(function(){});
      }
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
  }catch(e){
    console.error('checkCurrentSubscription error:',e);
    statusEl.textContent='检测推送状态失败: '+e.message;
  }
}

async function togglePushNotification(){
  const statusEl=document.getElementById('pushStatus');
  if(pushSubscription){
    try{
      const endpoint=pushSubscription.endpoint;
      await pushSubscription.unsubscribe();
      await fetch(API_BASE+'/api/push/unsubscribe',{
        method:'POST',
        headers:authHeaders({'Content-Type':'application/json'}),
        body:JSON.stringify({endpoint:endpoint})
      });
      pushSubscription=null;
      checkCurrentSubscription();
    }catch(e){alert('取消推送失败: '+e.message)}
  }else{
    try{
      statusEl.textContent='正在配置推送...';
      const keyRes=await fetch(API_BASE+'/api/push/vapid-key');
      const keyData=await keyRes.json();
      if(!keyData.publicKey){alert('服务器推送未配置');statusEl.textContent='服务器推送未配置';return}

      // 请求通知权限
      const permission=await Notification.requestPermission();
      if(permission!=='granted'){
        statusEl.textContent='通知权限被拒绝，请在系统设置 → 通知中允许本站';
        return;
      }

      // 确保 SW 完全激活
      if(!swRegistration)await initServiceWorker();
      const reg=await navigator.serviceWorker.ready;
      if(reg)swRegistration=reg;

      const sub=await swRegistration.pushManager.subscribe({
        userVisibleOnly:true,
        applicationServerKey:urlBase64ToUint8Array(keyData.publicKey)
      });

      const res=await fetch(API_BASE+'/api/push/subscribe',{
        method:'POST',
        headers:authHeaders({'Content-Type':'application/json'}),
        body:JSON.stringify({subscription:sub.toJSON()})
      });
      const result=await res.json();
      if(!result.success){
        statusEl.textContent='订阅保存失败: '+(result.message||'');
        return;
      }

      pushSubscription=sub;
      checkCurrentSubscription();
    }catch(e){
      console.error('Push subscribe error:',e);
      statusEl.textContent='开启推送失败: '+e.message;
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
// iOS PWA 键盘收起后视口归位修复
(function(){
  var isIos=/iPad|iPhone|iPod/.test(navigator.userAgent);
  if(!isIos)return;
  document.addEventListener('focusout',function(e){
    var related=e.relatedTarget;
    if(related){
      var inputArea=document.querySelector('.input-area');
      if(inputArea&&inputArea.contains(related))return;
    }
    setTimeout(function(){window.scrollTo(0,0)},100);
  });
  if(window.visualViewport){
    var lastHeight=window.visualViewport.height;
    window.visualViewport.addEventListener('resize',function(){
      var newHeight=window.visualViewport.height;
      if(newHeight>lastHeight){
        var ae=document.activeElement;
        var inputArea=document.querySelector('.input-area');
        if(ae&&(inputArea&&inputArea.contains(ae))){
          lastHeight=newHeight;return;
        }
        setTimeout(function(){window.scrollTo(0,0)},50);
        document.body.style.height='100vh';
        setTimeout(function(){document.body.style.height=''},100);
      }
      lastHeight=newHeight;
    });
  }
})();

document.addEventListener('DOMContentLoaded',async()=>{
  // 附件按钮: 直接绑定事件，确保移动端可用
  (function(){
    var attachBtn=document.getElementById('attachBtn');
    var fileInput=document.getElementById('fileInput');
    if(attachBtn&&fileInput){
      attachBtn.addEventListener('click',function(e){e.preventDefault();fileInput.click()});
    }
    // 对发送按钮阻止焦点抢夺(保持键盘不收起)，并在触摸结束时发送
    var sendBtn=document.getElementById('sendBtn');
    if(sendBtn){
      sendBtn.addEventListener('mousedown',function(e){e.preventDefault()});
      sendBtn.addEventListener('touchstart',function(e){e.preventDefault()},{passive:false});
      sendBtn.addEventListener('touchend',function(e){e.preventDefault();sendMessage()},{passive:false});
    }
    // 接龙按钮也阻止焦点抢夺
    var chainBtn=document.getElementById('chainBtn');
    if(chainBtn){
      chainBtn.addEventListener('mousedown',function(e){e.preventDefault()});
    }
    // 换行按钮阻止焦点抢夺
    var newlineBtn=document.getElementById('newlineBtn');
    if(newlineBtn){
      newlineBtn.addEventListener('touchstart',function(e){e.preventDefault()},{passive:false});
      newlineBtn.addEventListener('touchend',function(e){e.preventDefault();insertNewline()},{passive:false});
    }
  })();
  // textarea 自动调整高度
  (function(){
    var ta=document.getElementById('messageInput');
    if(ta){
      ta.addEventListener('input',function(){
        this.style.height='auto';
        this.style.height=Math.min(this.scrollHeight,120)+'px';
      });
    }
  })();
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
  var sendBtn=document.getElementById('sendBtn');
  if(d.send_text)sendBtn.textContent=d.send_text;
  if(d.send_color)sendBtn.style.background=d.send_color;
  var msgEl=document.getElementById('messages');
  clearVideoBg(msgEl);
  if(d.bg_type==='video'){
    applyBgToElement(msgEl,'color','transparent','','');
    applyVideoBg(msgEl,d);
  }else if(d.bg_type==='image'&&d.bg_image){
    applyBgToElement(msgEl,'image',d.bg_color,API_BASE+'/backgrounds/'+encodeURIComponent(d.bg_image),d.bg_mode);
  }else{applyBgToElement(msgEl,'color',d.bg_color||'#f5f5f5','','')}
  // 登录页背景
  var lp=document.getElementById('loginPage');
  var lbt=d.login_bg_type||'gradient';
  if(lbt==='image'&&d.login_bg_image){
    lp.style.background='none';
    applyBgToElement(lp,'image',d.login_bg_color1||'#667eea',API_BASE+'/backgrounds/'+encodeURIComponent(d.login_bg_image),d.login_bg_mode||'cover');
  }else if(lbt==='color'){
    lp.style.backgroundImage='none';lp.style.backgroundColor=d.login_bg_color1||'#667eea';
  }else{
    lp.style.backgroundImage='linear-gradient(135deg,'+(d.login_bg_color1||'#667eea')+' 0%,'+(d.login_bg_color2||'#764ba2')+' 100%)';
  }
  if(d.timezone){chatTimezone=d.timezone;var sel=document.getElementById('timezoneSelect');if(sel)sel.value=chatTimezone;updateTzIndicator()}
}

function applyBgToElement(el,type,color,url,mode){
  if(type==='image'&&url){
    el.style.backgroundColor=color||'#f5f5f5';el.style.backgroundImage='url('+url+')';el.style.backgroundPosition='center';
    switch(mode){case 'tile':el.style.backgroundSize='auto';el.style.backgroundRepeat='repeat';break;case 'stretch':el.style.backgroundSize='100% 100%';el.style.backgroundRepeat='no-repeat';break;case 'contain':el.style.backgroundSize='contain';el.style.backgroundRepeat='no-repeat';break;default:el.style.backgroundSize='cover';el.style.backgroundRepeat='no-repeat'}
  }else{el.style.backgroundImage='none';el.style.backgroundColor=color||'#f5f5f5'}
}

function extractYoutubeId(url){
  if(!url)return null;
  var m=url.match(/(?:youtube\.com\/(?:watch\?v=|embed\/|v\/|shorts\/)|youtu\.be\/)([a-zA-Z0-9_-]{11})/);
  return m?m[1]:null;
}

function clearVideoBg(container){
  if(!container)return;
  var wrapper=container.id==='messages'?document.getElementById('messagesWrapper'):container;
  var els=wrapper.querySelectorAll('.bg-video-layer');
  for(var i=0;i<els.length;i++){els[i].remove()}
  // also clean legacy .bg-video inside container
  var old=container.querySelectorAll('.bg-video');
  for(var j=0;j<old.length;j++){old[j].remove()}
}
function applyVideoBg(container,d){
  clearVideoBg(container);
  if(!container||!d)return;
  var wrapper=container.id==='messages'?document.getElementById('messagesWrapper'):container;
  var fitMode=d.bg_video_mode||'cover';
  var layer=document.createElement('div');
  layer.className='bg-video-layer fit-'+fitMode;
  if(d.bg_video_url){
    var vid=extractYoutubeId(d.bg_video_url);
    if(vid){
      var iframe=document.createElement('iframe');
      iframe.allow='autoplay';
      iframe.setAttribute('frameborder','0');
      iframe.src='https://www.youtube.com/embed/'+vid+'?autoplay=1&mute=1&loop=1&playlist='+vid+'&controls=0&showinfo=0&rel=0&modestbranding=1&playsinline=1&vq=hd720';
      layer.appendChild(iframe);
      wrapper.insertBefore(layer,wrapper.firstChild);
    }
  }else if(d.bg_video){
    var video=document.createElement('video');
    video.src=API_BASE+'/backgrounds/'+encodeURIComponent(d.bg_video);
    video.autoplay=true;video.loop=true;video.muted=true;video.playsInline=true;
    video.setAttribute('playsinline','');
    video.setAttribute('webkit-playsinline','');
    layer.appendChild(video);
    wrapper.insertBefore(layer,wrapper.firstChild);
  }
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

// ===== 注册功能 =====
let regOpen=false;
async function checkRegistration(){
  try{const r=await fetch(API_BASE+'/api/settings/registration');const d=await r.json();regOpen=d.open;
    document.getElementById('regToggle').classList.toggle('hidden',!regOpen);
  }catch(e){}
}
checkRegistration();

document.getElementById('toggleRegLink').addEventListener('click',(e)=>{
  e.preventDefault();const lf=document.getElementById('loginForm'),rf=document.getElementById('registerForm'),el=document.getElementById('loginError');
  el.textContent='';
  if(rf.classList.contains('hidden')){lf.classList.add('hidden');rf.classList.remove('hidden');e.target.textContent='已有账号？去登录'}
  else{rf.classList.add('hidden');lf.classList.remove('hidden');e.target.textContent='还没有账号？注册一个'}
});

document.getElementById('registerForm').addEventListener('submit',async(e)=>{
  e.preventDefault();const el=document.getElementById('loginError');el.textContent='';
  const u=document.getElementById('regUsername').value.trim(),n=document.getElementById('regNickname').value.trim(),
    p=document.getElementById('regPassword').value,p2=document.getElementById('regPassword2').value;
  if(!u||!p)return el.textContent='请填写用户名和密码';
  if(p!==p2)return el.textContent='两次密码不一致';
  if(p.length<6)return el.textContent='密码至少6个字符';
  try{const r=await fetch(API_BASE+'/api/public-register',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username:u,password:p,nickname:n||u})});
    const d=await r.json();
    if(d.success){el.style.color='#10b981';el.textContent='注册成功！请登录';
      document.getElementById('registerForm').classList.add('hidden');document.getElementById('loginForm').classList.remove('hidden');
      document.getElementById('loginUsername').value=u;document.getElementById('toggleRegLink').textContent='还没有账号？注册一个';
      setTimeout(()=>{el.style.color='';el.textContent=''},3000);
    }else{el.textContent=d.message||'注册失败'}
  }catch(err){el.textContent='注册失败，请重试'}
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
  if(currentUser.isAdmin)loadRegStatus();
  detectPushSupport();

  socket=io({auth:{token:currentUser.token}});
  socket.on('connect_error',(err)=>{if(err.message==='认证失败'||err.message==='未提供认证信息'){alert('登录已过期');logout()}});
  socket.on('newMessage',(msg)=>appendMessage(msg));
  socket.on('onlineUsers',(users)=>{
    document.getElementById('onlineCount').textContent=users.length+' 人在线: '+users.map(u=>u.nickname||u.username).join(', ');
    onlineUsernames=new Set(users.map(u=>u.username));updateOnlineDots();
  });
  socket.on('kicked',(d)=>showKickedOverlay(d.message||'您的账号已在其他设备登录'));
  socket.on('timezoneChanged',(d)=>{if(d.timezone){chatTimezone=d.timezone;const s=document.getElementById('timezoneSelect');if(s)s.value=chatTimezone;updateTzIndicator();refreshMessageTimes()}});
  socket.on('appearanceChanged',(d)=>{appearanceData=d;applyAppearance(d)});
  socket.on('registrationChanged',(d)=>{regOpen=d.open;if(currentUser.isAdmin)updateRegBtn(d.open)});
  socket.on('noticeChanged',(d)=>{applyNotice(d)});
  socket.on('chainUpdated',(data)=>{
    // 更新本地缓存中的消息内容并重新渲染该消息气泡
    const msg=messageCache.get(data.messageId);
    if(msg){
      msg.content=data.content;
      messageCache.set(data.messageId,msg);
      const el=document.querySelector('[data-message-id="'+data.messageId+'"]');
      if(el){
        const contentEl=el.querySelector('.content');
        if(contentEl)contentEl.innerHTML=renderChainContent(msg);
      }
    }
  });
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
  const time=formatTime(message.created_at);
  const displayName=escapeHtml(message.nickname||message.username);
  const avatarUrl=getAvatarUrl(message.avatar);
  const isOnline=onlineUsernames.has(message.username);
  let content='';
  const isChain=message.type==='text'&&message.content&&message.content.startsWith('[CHAIN]');
  if(isChain){content=renderChainContent(message)}
  else if(message.type==='text'){content=sanitizeIncoming(message.content)}
  else if(message.type==='image'){const src=API_BASE+'/uploads/'+encodeURIComponent(message.file_path);content='<img class="chat-image" src="'+escapeAttr(src)+'" onclick="showImagePreview(this.src)" alt="'+escapeAttr(message.file_name)+'">'}
  else if(message.type==='file'){const src=API_BASE+'/uploads/'+encodeURIComponent(message.file_path);content='<div class="file" data-url="'+escapeAttr(src)+'" data-filename="'+escapeAttr(message.file_name)+'" onclick="downloadFile(this.dataset.url,this.dataset.filename)"><span>📄</span><div><span>'+escapeHtml(message.file_name)+'</span><span> ('+formatFileSize(message.file_size)+')</span></div></div>'}
  let replyHtml='';
  if(message.reply_to){const rm=messageCache.get(message.reply_to);if(rm){const rn=escapeHtml(rm.nickname||rm.username);let rc;if(rm.type==='image')rc='[图片]';else if(rm.type==='file')rc='[文件]';else if(rm.content&&rm.content.startsWith('[CHAIN]')){const cd=parseChainData(rm.content);rc=cd?'[接龙] '+escapeHtml(cd.topic):'[接龙]'}else rc=escapeHtml(rm.content.replace(/<[^>]*>/g,'').substring(0,50));replyHtml='<div class="reply-preview"><span class="reply-name">'+rn+':</span> '+rc+'</div>'}}
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
  const rn=escapeHtml(msg.nickname||msg.username);let rc;
  if(msg.type==='image')rc='[图片]';else if(msg.type==='file')rc='[文件]';
  else if(msg.content&&msg.content.startsWith('[CHAIN]')){const cd=parseChainData(msg.content);rc=cd?'[接龙] '+escapeHtml(cd.topic):'[接龙]'}
  else rc=escapeHtml(msg.content.replace(/<[^>]*>/g,'').substring(0,30));
  rb.innerHTML='<span class="reply-label">引用 '+rn+':</span><span class="reply-content">'+rc+'</span><button class="reply-cancel" onclick="cancelReply()">✕</button>';
  document.getElementById('messageInput').focus();
}
function cancelReply(){replyingToMsg=null;const rb=document.getElementById('replyBox');if(rb)rb.remove()}

// ===== 接龙功能 =====
function showChainDialog(){document.getElementById('chainTopic').value='';document.getElementById('chainDesc').value='';document.getElementById('chainNickname').value=currentUser.nickname||currentUser.username;document.getElementById('chainModal').classList.remove('hidden')}
function closeChainDialog(){document.getElementById('chainModal').classList.add('hidden')}
function sendChainMessage(){
  const topic=document.getElementById('chainTopic').value.trim();
  if(!topic){alert('请输入接龙话题');return}
  const desc=document.getElementById('chainDesc').value.trim();
  const nickInput=document.getElementById('chainNickname').value.trim();
  const myName=nickInput||(currentUser.nickname||currentUser.username);
  // 构造接龙特殊消息内容，使用特殊前缀标识
  const chainData={type:'chain',topic:topic,desc:desc,participants:[{seq:1,username:currentUser.username,name:myName,text:''}]};
  const content='[CHAIN]'+JSON.stringify(chainData);
  socket.emit('sendMessage',{content:content});
  closeChainDialog();
}
function joinChain(messageId){
  const msg=messageCache.get(messageId);if(!msg)return;
  const chainData=parseChainData(msg.content);if(!chainData)return;
  const myName=currentUser.nickname||currentUser.username;
  // 检查是否已参与
  if(chainData.participants.some(p=>p.username===currentUser.username)){alert('你已经参与过此接龙了');return}
  const newSeq=chainData.participants.length+1;
  chainData.participants.push({seq:newSeq,username:currentUser.username,name:myName,text:''});
  const newContent='[CHAIN]'+JSON.stringify(chainData);
  socket.emit('updateChain',{messageId:messageId,content:newContent});
}
function parseChainData(content){
  if(!content||typeof content!=='string')return null;
  if(!content.startsWith('[CHAIN]'))return null;
  try{return JSON.parse(content.substring(7))}catch(e){return null}
}
function renderChainContent(message){
  const data=parseChainData(message.content);if(!data)return '';
  let html='<div class="chain-card">';
  html+='<div class="chain-header">🚂 接龙</div>';
  html+='<div class="chain-topic">'+escapeHtml(data.topic)+'</div>';
  if(data.desc)html+='<div class="chain-desc">'+escapeHtml(data.desc)+'</div>';
  if(data.participants&&data.participants.length>0){
    html+='<div class="chain-list">';
    data.participants.forEach(function(p){
      html+='<div class="chain-item"><span class="chain-seq">'+p.seq+'</span><span class="chain-name">'+escapeHtml(p.name)+'</span>'+(p.text?' '+escapeHtml(p.text):'')+'</div>';
    });
    html+='</div>';
  }
  // 判断当前用户是否已参与
  const alreadyJoined=data.participants&&data.participants.some(function(p){return p.username===currentUser.username});
  if(alreadyJoined){
    html+='<button class="chain-join-btn joined" disabled>✅ 已参与</button>';
  }else{
    html+='<button class="chain-join-btn" onclick="event.stopPropagation();joinChain('+message.id+')">🙋 参与接龙</button>';
  }
  html+='</div>';
  return html;
}

function sendMessage(){
  const input=document.getElementById('messageInput');const text=input.value.trim();
  if(!text||!socket)return;
  const d={content:escapeHtml(text)};if(replyingToMsg)d.replyTo=replyingToMsg.id;
  socket.emit('sendMessage',d);cancelReply();input.value='';input.style.height='auto';input.focus();
}
function insertNewline(){
  const ta=document.getElementById('messageInput');if(!ta)return;
  const start=ta.selectionStart,end=ta.selectionEnd;
  ta.value=ta.value.substring(0,start)+'\n'+ta.value.substring(end);
  ta.selectionStart=ta.selectionEnd=start+1;
  ta.style.height='auto';ta.style.height=Math.min(ta.scrollHeight,120)+'px';
  ta.focus();
}
function handleKeyDown(e){
  if(e.key==='Enter'&&!e.shiftKey){e.preventDefault();sendMessage()}
}

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
const TZ_LABELS={'Asia/Shanghai':'北京时间','Asia/Tokyo':'东京时间','Asia/Singapore':'新加坡时间','Asia/Kolkata':'印度时间','Asia/Dubai':'海湾时间','Europe/London':'伦敦时间','Europe/Paris':'中欧时间','Europe/Moscow':'莫斯科时间','America/New_York':'美东时间','America/Chicago':'美中时间','America/Denver':'山地时间','America/Los_Angeles':'美西时间','Pacific/Auckland':'新西兰时间','Australia/Sydney':'悉尼时间'};
function updateTzIndicator(){const el=document.getElementById('tzIndicator');if(el)el.textContent='🕐 '+(TZ_LABELS[chatTimezone]||chatTimezone)}
async function loadTimezone(){try{const r=await fetch(API_BASE+'/api/settings/timezone',{headers:authHeaders()});if(r.ok){const d=await r.json();if(d.timezone){chatTimezone=d.timezone;const s=document.getElementById('timezoneSelect');if(s)s.value=chatTimezone;updateTzIndicator()}if(d.serverTimezone){const m=document.getElementById('timezoneMsg');if(m)m.textContent='服务器系统时区: '+d.serverTimezone}}}catch(e){}}
async function saveTimezone(){
  const tz=document.getElementById('timezoneSelect').value,m=document.getElementById('timezoneMsg');
  try{const r=await fetch(API_BASE+'/api/settings/timezone',{method:'POST',headers:authHeaders({'Content-Type':'application/json'}),body:JSON.stringify({timezone:tz})});const d=await r.json();if(d.success){chatTimezone=tz;refreshMessageTimes();updateTzIndicator();m.textContent='时区已更新';setTimeout(()=>{m.textContent=''},3000)}else m.textContent=d.message||'保存失败'}catch(e){m.textContent='保存失败'}
}
function refreshMessageTimes(){
  document.getElementById('messages').querySelectorAll('.message[data-message-id]').forEach(div=>{
    const msg=messageCache.get(parseInt(div.dataset.messageId));if(!msg)return;const t=div.querySelector('.time');if(!t)return;
    t.textContent=formatTime(msg.created_at);
  });
}

// ===== 外观定制 =====
let pendingBgFilename='';
let pendingBgVideoFilename='';
function showAppearance(){
  var d=appearanceData;
  document.getElementById('appLoginTitle').value=d.login_title||'';document.getElementById('appChatTitle').value=d.chat_title||'';
  document.getElementById('appSendText').value=d.send_text||'';document.getElementById('appSendColor').value=d.send_color||'#667eea';
  document.getElementById('appSendColorHex').textContent=d.send_color||'#667eea';
  document.getElementById('appBgColor').value=d.bg_color||'#f5f5f5';document.getElementById('appBgColorHex').textContent=d.bg_color||'#f5f5f5';
  document.querySelectorAll('input[name="bgType"]').forEach(function(r){r.checked=(r.value===(d.bg_type||'color'))});toggleBgType();
  if(d.bg_image){pendingBgFilename=d.bg_image;document.getElementById('bgFileName').textContent=d.bg_image;var p=document.getElementById('bgPreview');p.src=API_BASE+'/backgrounds/'+encodeURIComponent(d.bg_image);p.classList.remove('hidden')}
  else{pendingBgFilename='';document.getElementById('bgFileName').textContent='未选择图片';document.getElementById('bgPreview').classList.add('hidden')}
  document.getElementById('appBgMode').value=d.bg_mode||'cover';
  document.getElementById('appBgVideoUrl').value=d.bg_video_url||'';
  document.getElementById('appBgVideoMode').value=d.bg_video_mode||'cover';
  if(d.bg_video){pendingBgVideoFilename=d.bg_video;document.getElementById('bgVideoFileName').textContent=d.bg_video}
  else{pendingBgVideoFilename='';document.getElementById('bgVideoFileName').textContent='未选择视频'}
  // 登录页背景
  document.getElementById('appLoginBgColor1').value=d.login_bg_color1||'#667eea';document.getElementById('appLoginBgColor1Hex').textContent=d.login_bg_color1||'#667eea';
  document.getElementById('appLoginBgColor2').value=d.login_bg_color2||'#764ba2';document.getElementById('appLoginBgColor2Hex').textContent=d.login_bg_color2||'#764ba2';
  document.getElementById('appLoginBgSolid').value=d.login_bg_color1||'#667eea';document.getElementById('appLoginBgSolidHex').textContent=d.login_bg_color1||'#667eea';
  document.querySelectorAll('input[name="loginBgType"]').forEach(function(r){r.checked=(r.value===(d.login_bg_type||'gradient'))});toggleLoginBgType();
  if(d.login_bg_image){pendingLoginBgFilename=d.login_bg_image;document.getElementById('loginBgFileName').textContent=d.login_bg_image;var lp=document.getElementById('loginBgPreview');lp.src=API_BASE+'/backgrounds/'+encodeURIComponent(d.login_bg_image);lp.classList.remove('hidden')}
  else{pendingLoginBgFilename='';document.getElementById('loginBgFileName').textContent='未选择图片';document.getElementById('loginBgPreview').classList.add('hidden')}
  document.getElementById('appLoginBgMode').value=d.login_bg_mode||'cover';
  updateLivePreview();updateLoginPreview();
  document.getElementById('appearanceModal').classList.remove('hidden');
}
function closeAppearance(){document.getElementById('appearanceModal').classList.add('hidden')}
function toggleBgType(){var v=document.querySelector('input[name="bgType"]:checked').value;document.getElementById('bgColorSection').classList.toggle('hidden',v!=='color');document.getElementById('bgImageSection').classList.toggle('hidden',v!=='image');document.getElementById('bgVideoSection').classList.toggle('hidden',v!=='video');updateLivePreview()}
document.addEventListener('input',function(e){if(e.target.id==='appSendColor'){document.getElementById('appSendColorHex').textContent=e.target.value;updateLivePreview()}if(e.target.id==='appBgColor'){document.getElementById('appBgColorHex').textContent=e.target.value;updateLivePreview()}if(e.target.id==='appLoginBgColor1'){document.getElementById('appLoginBgColor1Hex').textContent=e.target.value;updateLoginPreview()}if(e.target.id==='appLoginBgColor2'){document.getElementById('appLoginBgColor2Hex').textContent=e.target.value;updateLoginPreview()}if(e.target.id==='appLoginBgSolid'){document.getElementById('appLoginBgSolidHex').textContent=e.target.value;updateLoginPreview()}});
document.addEventListener('change',function(e){if(e.target.id==='appBgMode'||e.target.id==='appBgVideoMode')updateLivePreview();if(e.target.id==='appLoginBgMode')updateLoginPreview()});
function updateLivePreview(){
  var p=document.getElementById('previewArea');if(!p)return;
  clearVideoBg(p);
  var bt=document.querySelector('input[name="bgType"]:checked');bt=bt?bt.value:'color';
  var bc=document.getElementById('appBgColor');bc=bc?bc.value:'#f5f5f5';
  var bm=document.getElementById('appBgMode');bm=bm?bm.value:'cover';
  if(bt==='video'){
    applyBgToElement(p,'color','transparent','','');
    var vurl=document.getElementById('appBgVideoUrl');vurl=vurl?vurl.value:'';
    var vmode=document.getElementById('appBgVideoMode');vmode=vmode?vmode.value:'cover';
    applyVideoBg(p,{bg_video_url:vurl,bg_video:pendingBgVideoFilename,bg_video_mode:vmode});
  }else if(bt==='image'&&pendingBgFilename){applyBgToElement(p,'image',bc,API_BASE+'/backgrounds/'+encodeURIComponent(pendingBgFilename),bm)}
  else{applyBgToElement(p,'color',bc,'','')}
  var rb=p.querySelector('.preview-bubble.right');var sc=document.getElementById('appSendColor');sc=sc?sc.value:'#667eea';if(rb)rb.style.background=sc;
}
async function handleBgImageUpload(input){
  var file=input.files[0];if(!file)return;var fd=new FormData();fd.append('bg',file);
  try{var r=await fetch(API_BASE+'/api/upload-bg',{method:'POST',headers:{'Authorization':'Bearer '+currentUser.token},body:fd});var d=await r.json();if(d.success){pendingBgFilename=d.filename;document.getElementById('bgFileName').textContent=file.name;var p=document.getElementById('bgPreview');p.src=API_BASE+'/backgrounds/'+encodeURIComponent(d.filename);p.classList.remove('hidden');updateLivePreview()}else alert(d.message||'上传失败')}catch(e){alert('上传失败')}
  input.value='';
}
async function handleBgVideoUpload(input){
  var file=input.files[0];if(!file)return;
  if(file.size>100*1024*1024){alert('视频文件不能超过 100MB');input.value='';return}
  var fd=new FormData();fd.append('bg',file);
  document.getElementById('bgVideoFileName').textContent='上传中...';
  try{var r=await fetch(API_BASE+'/api/upload-bg',{method:'POST',headers:{'Authorization':'Bearer '+currentUser.token},body:fd});var d=await r.json();if(d.success){pendingBgVideoFilename=d.filename;document.getElementById('bgVideoFileName').textContent=file.name;document.getElementById('appBgVideoUrl').value='';updateLivePreview()}else{alert(d.message||'上传失败');document.getElementById('bgVideoFileName').textContent='上传失败'}}catch(e){alert('上传失败');document.getElementById('bgVideoFileName').textContent='上传失败'}
  input.value='';
}
async function saveAppearance(){
  var m=document.getElementById('appearanceMsg');var bt=document.querySelector('input[name="bgType"]:checked').value;
  var lbt=document.querySelector('input[name="loginBgType"]:checked').value;
  var videoUrl=document.getElementById('appBgVideoUrl');videoUrl=videoUrl?videoUrl.value.trim():'';
  var loginColor1=lbt==='color'?(document.getElementById('appLoginBgSolid').value||'#667eea'):(document.getElementById('appLoginBgColor1').value||'#667eea');
  var loginColor2=document.getElementById('appLoginBgColor2').value||'#764ba2';
  var payload={login_title:document.getElementById('appLoginTitle').value.trim()||'团队聊天室',chat_title:document.getElementById('appChatTitle').value.trim()||'团队聊天',send_text:document.getElementById('appSendText').value.trim()||'发送',send_color:document.getElementById('appSendColor').value||'#667eea',bg_type:bt,bg_color:document.getElementById('appBgColor').value||'#f5f5f5',bg_image:bt==='image'?pendingBgFilename:'',bg_mode:document.getElementById('appBgMode').value||'cover',bg_video:bt==='video'?pendingBgVideoFilename:'',bg_video_url:bt==='video'?videoUrl:'',bg_video_mode:bt==='video'?(document.getElementById('appBgVideoMode').value||'cover'):'cover',login_bg_type:lbt,login_bg_color1:loginColor1,login_bg_color2:loginColor2,login_bg_image:lbt==='image'?pendingLoginBgFilename:'',login_bg_mode:document.getElementById('appLoginBgMode').value||'cover'};
  if(bt==='video'&&videoUrl&&!extractYoutubeId(videoUrl)&&!pendingBgVideoFilename){m.textContent='YouTube 链接格式不正确';m.style.color='#dc2626';return}
  if(bt==='video'&&!videoUrl&&!pendingBgVideoFilename){m.textContent='请填写 YouTube 链接或上传视频文件';m.style.color='#dc2626';return}
  try{var r=await fetch(API_BASE+'/api/settings/appearance',{method:'POST',headers:authHeaders({'Content-Type':'application/json'}),body:JSON.stringify(payload)});var d=await r.json();if(d.success){appearanceData=payload;applyAppearance(payload);m.textContent='✅ 外观已保存';m.style.color='#10b981';setTimeout(function(){m.textContent=''},3000)}else{m.textContent=d.message||'保存失败';m.style.color='#dc2626'}}catch(e){m.textContent='保存失败';m.style.color='#dc2626'}
}

// ===== 登录页背景 =====
var pendingLoginBgFilename='';
function toggleLoginBgType(){var v=document.querySelector('input[name="loginBgType"]:checked').value;document.getElementById('loginBgGradientSection').classList.toggle('hidden',v!=='gradient');document.getElementById('loginBgColorSection').classList.toggle('hidden',v!=='color');document.getElementById('loginBgImageSection').classList.toggle('hidden',v!=='image');updateLoginPreview()}
function updateLoginPreview(){
  var p=document.getElementById('loginPreviewArea');if(!p)return;
  var lbt=document.querySelector('input[name="loginBgType"]:checked');lbt=lbt?lbt.value:'gradient';
  if(lbt==='image'&&pendingLoginBgFilename){
    var lbm=document.getElementById('appLoginBgMode');lbm=lbm?lbm.value:'cover';
    applyBgToElement(p,'image','#667eea',API_BASE+'/backgrounds/'+encodeURIComponent(pendingLoginBgFilename),lbm);
  }else if(lbt==='color'){
    var sc=document.getElementById('appLoginBgSolid');sc=sc?sc.value:'#667eea';
    p.style.backgroundImage='none';p.style.backgroundColor=sc;
  }else{
    var c1=document.getElementById('appLoginBgColor1');c1=c1?c1.value:'#667eea';
    var c2=document.getElementById('appLoginBgColor2');c2=c2?c2.value:'#764ba2';
    p.style.backgroundImage='linear-gradient(135deg,'+c1+' 0%,'+c2+' 100%)';p.style.backgroundColor='';
  }
}
async function handleLoginBgUpload(input){
  var file=input.files[0];if(!file)return;var fd=new FormData();fd.append('bg',file);
  try{var r=await fetch(API_BASE+'/api/upload-bg',{method:'POST',headers:{'Authorization':'Bearer '+currentUser.token},body:fd});var d=await r.json();if(d.success){pendingLoginBgFilename=d.filename;document.getElementById('loginBgFileName').textContent=file.name;var p=document.getElementById('loginBgPreview');p.src=API_BASE+'/backgrounds/'+encodeURIComponent(d.filename);p.classList.remove('hidden');updateLoginPreview()}else alert(d.message||'上传失败')}catch(e){alert('上传失败')}
  input.value='';
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
    const btns=document.createElement('div');btns.style.cssText='display:flex;gap:6px;align-items:center';
    const rp=document.createElement('button');rp.className='reset-pwd-btn';rp.textContent='改密';rp.addEventListener('click',()=>showResetPassword(u.username));btns.appendChild(rp);
    if(u.is_admin){const a=document.createElement('span');a.style.cssText='color:#667eea;font-size:12px';a.textContent='管理员';btns.appendChild(a)}
    else{const b=document.createElement('button');b.className='delete-btn';b.textContent='删除';b.addEventListener('click',()=>deleteUser(u.username));btns.appendChild(b)}
    item.appendChild(btns);list.appendChild(item)});
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

// ===== 管理员开关注册 =====
async function toggleRegistration(){
  try{const r=await fetch(API_BASE+'/api/settings/registration');const d=await r.json();const newState=!d.open;
    const r2=await fetch(API_BASE+'/api/settings/registration',{method:'POST',headers:authHeaders({'Content-Type':'application/json'}),body:JSON.stringify({open:newState})});
    const d2=await r2.json();if(d2.success){updateRegBtn(d2.open);alert(d2.open?'已开放注册，用户可在登录页自助注册':'已关闭注册')}else alert(d2.message||'操作失败');
  }catch(e){alert('操作失败')}
}
function updateRegBtn(isOpen){const btn=document.getElementById('regToggleBtn');if(btn)btn.textContent=isOpen?'🔒 关闭注册':'📝 开放注册'}
async function loadRegStatus(){try{const r=await fetch(API_BASE+'/api/settings/registration');const d=await r.json();updateRegBtn(d.open)}catch(e){}}

// ===== 管理员重置密码 =====
let resetPwdUsername='';
function showResetPassword(username){resetPwdUsername=username;document.getElementById('resetPwdSection').classList.remove('hidden');document.getElementById('resetPwdTarget').textContent='正在为用户 "'+username+'" 重置密码';document.getElementById('resetPwdInput').value='';document.getElementById('resetPwdMsg').textContent=''}
function cancelResetPassword(){document.getElementById('resetPwdSection').classList.add('hidden');resetPwdUsername=''}
async function doResetPassword(){const np=document.getElementById('resetPwdInput').value;const msg=document.getElementById('resetPwdMsg');if(!np||np.length<6)return msg.textContent='新密码至少6个字符';try{const r=await fetch(API_BASE+'/api/admin/reset-password',{method:'POST',headers:authHeaders({'Content-Type':'application/json'}),body:JSON.stringify({username:resetPwdUsername,newPassword:np})});const d=await r.json();if(d.success){msg.style.color='#10b981';msg.textContent='密码已重置成功';document.getElementById('resetPwdInput').value='';setTimeout(()=>{msg.style.color='';cancelResetPassword()},2000)}else{msg.style.color='#dc2626';msg.textContent=d.message||'重置失败'}}catch(e){msg.style.color='#dc2626';msg.textContent='重置失败'}}

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
  "version": "2.5.0",
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

// 迁移: 将已有消息的 created_at 统一为 UTC ISO 格式 (带 Z 后缀)
try {
  const needFix = db.prepare("SELECT COUNT(*) as cnt FROM messages WHERE created_at NOT LIKE '%Z' AND created_at NOT LIKE '%+%' AND created_at NOT LIKE '%-__:__'").get();
  if (needFix && needFix.cnt > 0) {
    db.exec("UPDATE messages SET created_at = REPLACE(created_at, ' ', 'T') || 'Z' WHERE created_at NOT LIKE '%Z' AND created_at NOT LIKE '%+%' AND created_at NOT LIKE '%-__:__'");
    console.log("✅ 已将 " + needFix.cnt + " 条消息时间戳迁移为 UTC 格式");
  }
} catch(e) { console.log("时间戳迁移跳过:", e.message); }

db.exec(`
  CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP);
  CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT UNIQUE NOT NULL, password TEXT NOT NULL, nickname TEXT, avatar TEXT, is_admin INTEGER DEFAULT 0, last_login_at TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP);
  CREATE TABLE IF NOT EXISTS messages (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL, username TEXT NOT NULL, content TEXT, type TEXT DEFAULT 'text', file_name TEXT, file_path TEXT, file_size INTEGER, reply_to INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE);
  CREATE TABLE IF NOT EXISTS push_subscriptions (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL, endpoint TEXT UNIQUE NOT NULL, keys_p256dh TEXT NOT NULL, keys_auth TEXT NOT NULL, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE);
`);

const defaultSettings = { timezone:"Asia/Shanghai", login_title:"团队聊天室", chat_title:"团队聊天", send_text:"发送", send_color:"#667eea", bg_type:"color", bg_color:"#f5f5f5", bg_image:"", bg_mode:"cover", bg_video:"", bg_video_url:"", bg_video_mode:"cover", pinned_notice:"", pinned_notice_enabled:"0", registration_open:"0", login_bg_type:"gradient", login_bg_color1:"#667eea", login_bg_color2:"#764ba2", login_bg_image:"", login_bg_mode:"cover" };
const insSetting = db.prepare("INSERT OR IGNORE INTO settings (key, value) VALUES (?, ?)");
for (const [k, v] of Object.entries(defaultSettings)) insSetting.run(k, v);

app.use(cors());
app.use(express.json({ limit: "5mb" }));

// Service Worker 必须不被缓存，否则更新后 iOS 无法获取新版本
app.get("/sw.js", (req, res) => {
  res.setHeader("Cache-Control", "no-cache, no-store, must-revalidate");
  res.setHeader("Content-Type", "application/javascript");
  res.sendFile(path.join(__dirname, "public", "sw.js"));
});
// manifest.json 也不应被长期缓存
app.get("/manifest.json", (req, res) => {
  res.setHeader("Cache-Control", "no-cache");
  res.setHeader("Content-Type", "application/manifest+json");
  res.sendFile(path.join(__dirname, "public", "manifest.json"));
});

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
const uploadBg = multer({storage:bgStorage,limits:{fileSize:100*1024*1024},fileFilter:(r,f,cb)=>{fixFilename(f);const ext=path.extname(f.originalname).toLowerCase();const ok=[".jpg",".jpeg",".png",".gif",".webp",".bmp",".svg",".mp4",".mov",".webm",".m4v"].includes(ext);cb(ok?null:new Error("背景只支持图片或视频"),ok)},defParamCharset:"utf8"});

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

// 将 SQLite 的 CURRENT_TIMESTAMP 格式 (无时区) 统一为 UTC ISO 格式
function normalizeToUTC(ts){
  if(!ts)return ts;
  if(ts.endsWith("Z")||/[+-]\d{2}:\d{2}$/.test(ts))return ts;
  // SQLite CURRENT_TIMESTAMP 格式: "2025-03-16 12:30:00" (本身就是 UTC)
  return ts.replace(" ","T")+"Z";
}

// ===== Push Notification 相关 =====
app.get("/api/push/vapid-key",(req,res)=>{
  res.json({publicKey:vapidKeys.publicKey});
});

app.post("/api/push/subscribe",authMiddleware,(req,res)=>{
  const {subscription,oldEndpoint}=req.body;
  if(!subscription||!subscription.endpoint||!subscription.keys)return res.json({success:false,message:"无效的订阅数据"});
  try{
    // 如果提供了旧 endpoint，先删除它
    if(oldEndpoint){
      db.prepare("DELETE FROM push_subscriptions WHERE endpoint=?").run(oldEndpoint);
    }
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

// SW pushsubscriptionchange 触发的续订 (无 auth token，通过旧 endpoint 识别用户)
app.post("/api/push/renew",(req,res)=>{
  const {subscription,oldEndpoint}=req.body;
  if(!subscription||!subscription.endpoint||!subscription.keys||!oldEndpoint)return res.json({success:false,message:"参数不完整"});
  try{
    const old=db.prepare("SELECT user_id FROM push_subscriptions WHERE endpoint=?").get(oldEndpoint);
    if(!old)return res.json({success:false,message:"原订阅不存在"});
    db.prepare("DELETE FROM push_subscriptions WHERE endpoint=?").run(oldEndpoint);
    db.prepare("INSERT OR REPLACE INTO push_subscriptions (user_id,endpoint,keys_p256dh,keys_auth) VALUES (?,?,?,?)")
      .run(old.user_id,subscription.endpoint,subscription.keys.p256dh,subscription.keys.auth);
    res.json({success:true});
  }catch(e){res.json({success:false,message:"续订失败"})}
});

function sendPushToOthers(senderUserId, senderName, messageText){
  const subs=db.prepare("SELECT * FROM push_subscriptions WHERE user_id != ?").all(senderUserId);
  const chatTitle=getSetting("chat_title")||"TeamChat";
  const body=messageText.replace(/<[^>]*>/g,'');
  const trimBody=body.length>100?body.substring(0,100)+"...":body;
  const payload=JSON.stringify({
    title:chatTitle,
    body:senderName+": "+trimBody,
    icon:"/images/icon-192.png",
    data:{url:"/"}
  });
  // TTL=86400 (24小时): 推送服务会尝试在24小时内送达 (iOS 离线时尤其重要)
  // urgency=high: 告诉推送服务这是高优先级消息，应立即送达
  const pushOptions = { TTL: 86400, urgency: "high", topic: "teamchat-msg" };
  for(const sub of subs){
    const pushSub={endpoint:sub.endpoint,keys:{p256dh:sub.keys_p256dh,auth:sub.keys_auth}};
    webpush.sendNotification(pushSub,payload,pushOptions).catch(err=>{
      console.log("Push failed for sub "+sub.id+": "+(err.statusCode||err.message));
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
  res.json(db.prepare(sql).all(...params).reverse().map(m=>{m.created_at=normalizeToUTC(m.created_at);return m}));
});

app.post("/api/upload",authMiddleware,upload.single("file"),(req,res)=>{
  if(!req.file)return res.json({success:false,message:"上传失败"});
  const type=req.file.mimetype.startsWith("image/")?"image":"file";
  const user=db.prepare("SELECT username,nickname,avatar FROM users WHERE id=?").get(req.user.userId);
  if(!user)return res.json({success:false,message:"用户不存在"});
  const nowUtc=new Date().toISOString();
  const result=db.prepare("INSERT INTO messages (user_id,username,content,type,file_name,file_path,file_size,created_at) VALUES (?,?,?,?,?,?,?,?)").run(req.user.userId,user.username,req.body.content||"",type,req.file.originalname,req.file.filename,req.file.size,nowUtc);
  const message={id:result.lastInsertRowid,username:user.username,nickname:user.nickname,avatar:user.avatar,content:req.body.content||"",type,file_name:req.file.originalname,file_path:req.file.filename,file_size:req.file.size,created_at:nowUtc};
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

// ===== 开放注册 =====
app.get("/api/settings/registration",(req,res)=>{res.json({open:getSetting("registration_open")==="1"})});
app.post("/api/settings/registration",authMiddleware,adminMiddleware,(req,res)=>{
  const{open}=req.body;setSetting("registration_open",open?"1":"0");
  io.emit("registrationChanged",{open:!!open});
  res.json({success:true,open:!!open});
});
app.post("/api/public-register",async(req,res)=>{
  if(getSetting("registration_open")!=="1")return res.json({success:false,message:"注册通道已关闭"});
  const{username,password,nickname}=req.body;
  if(!username||!password)return res.json({success:false,message:"缺少参数"});
  if(!/^[a-zA-Z0-9_.\-]+$/.test(username))return res.json({success:false,message:"用户名只允许字母数字下划线"});
  if(username.length<2||username.length>20)return res.json({success:false,message:"用户名需 2-20 个字符"});
  if(password.length<6)return res.json({success:false,message:"密码不能小于6位"});
  const hashed=await bcrypt.hash(password,10);
  try{db.prepare("INSERT INTO users (username,password,nickname) VALUES (?,?,?)").run(username,hashed,nickname||username);res.json({success:true})}
  catch(e){res.json({success:false,message:"用户名已存在"})}
});

// ===== 管理员重置密码 =====
app.post("/api/admin/reset-password",authMiddleware,adminMiddleware,async(req,res)=>{
  const{username,newPassword}=req.body;
  if(!username||!newPassword)return res.json({success:false,message:"缺少参数"});
  if(newPassword.length<6)return res.json({success:false,message:"新密码不能小于6位"});
  const user=db.prepare("SELECT id,is_admin FROM users WHERE username=?").get(username);
  if(!user)return res.json({success:false,message:"用户不存在"});
  if(user.is_admin&&user.id!==req.user.userId)return res.json({success:false,message:"不能修改其他管理员密码"});
  db.prepare("UPDATE users SET password=? WHERE username=?").run(await bcrypt.hash(newPassword,10),username);
  res.json({success:true});
});

// ===== Settings =====
const VALID_TZ=["Asia/Shanghai","Asia/Tokyo","Asia/Singapore","Asia/Kolkata","Asia/Dubai","Europe/London","Europe/Paris","Europe/Moscow","America/New_York","America/Chicago","America/Denver","America/Los_Angeles","Pacific/Auckland","Australia/Sydney"];
app.get("/api/settings/timezone",authMiddleware,(req,res)=>{res.json({timezone:getSetting("timezone"),serverTimezone:Intl.DateTimeFormat().resolvedOptions().timeZone})});
app.post("/api/settings/timezone",authMiddleware,adminMiddleware,(req,res)=>{const{timezone}=req.body;if(!timezone||!VALID_TZ.includes(timezone))return res.json({success:false,message:"不支持的时区"});setSetting("timezone",timezone);io.emit("timezoneChanged",{timezone});res.json({success:true})});

app.get("/api/settings/appearance",(req,res)=>{
  const keys=["login_title","chat_title","send_text","send_color","bg_type","bg_color","bg_image","bg_mode","bg_video","bg_video_url","bg_video_mode","timezone","login_bg_type","login_bg_color1","login_bg_color2","login_bg_image","login_bg_mode"];
  const r={};keys.forEach(k=>{r[k]=getSetting(k)});res.json(r);
});
app.post("/api/settings/appearance",authMiddleware,adminMiddleware,(req,res)=>{
  const body=req.body;const allowed=["login_title","chat_title","send_text","send_color","bg_type","bg_color","bg_image","bg_mode","bg_video","bg_video_url","bg_video_mode","login_bg_type","login_bg_color1","login_bg_color2","login_bg_image","login_bg_mode"];
  if(body.send_color&&!/^#[0-9a-fA-F]{6}$/.test(body.send_color))return res.json({success:false,message:"颜色格式错误"});
  if(body.bg_color&&!/^#[0-9a-fA-F]{6}$/.test(body.bg_color))return res.json({success:false,message:"颜色格式错误"});
  if(body.login_bg_color1&&!/^#[0-9a-fA-F]{6}$/.test(body.login_bg_color1))return res.json({success:false,message:"颜色格式错误"});
  if(body.login_bg_color2&&!/^#[0-9a-fA-F]{6}$/.test(body.login_bg_color2))return res.json({success:false,message:"颜色格式错误"});
  if(body.bg_type&&!["color","image","video"].includes(body.bg_type))return res.json({success:false,message:"类型错误"});
  if(body.login_bg_type&&!["gradient","color","image"].includes(body.login_bg_type))return res.json({success:false,message:"登录背景类型错误"});
  if(body.bg_mode&&!["cover","contain","stretch","tile"].includes(body.bg_mode))return res.json({success:false,message:"显示方式错误"});
  if(body.login_bg_mode&&!["cover","contain","stretch","tile"].includes(body.login_bg_mode))body.login_bg_mode="cover";
  if(body.bg_video_url&&body.bg_video_url.length>500)body.bg_video_url=body.bg_video_url.substring(0,500);
  if(body.bg_video_mode&&!["cover","contain","stretch"].includes(body.bg_video_mode))body.bg_video_mode="cover";
  if(body.login_title&&body.login_title.length>30)body.login_title=body.login_title.substring(0,30);
  if(body.chat_title&&body.chat_title.length>30)body.chat_title=body.chat_title.substring(0,30);
  if(body.send_text&&body.send_text.length>10)body.send_text=body.send_text.substring(0,10);
  const upd=db.prepare("INSERT OR REPLACE INTO settings (key,value,updated_at) VALUES (?,?,datetime('now'))");
  db.transaction(()=>{for(const k of allowed){if(body[k]!==undefined)upd.run(k,String(body[k]))}})();
  const bd={};["login_title","chat_title","send_text","send_color","bg_type","bg_color","bg_image","bg_mode","bg_video","bg_video_url","bg_video_mode","timezone","login_bg_type","login_bg_color1","login_bg_color2","login_bg_image","login_bg_mode"].forEach(k=>{bd[k]=getSetting(k)});
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

app.get("/api/backup",authMiddleware,adminMiddleware,(req,res)=>{const{startDate,endDate}=req.query;let sql="SELECT m.*,u.username as user_username,u.nickname,u.avatar FROM messages m JOIN users u ON m.user_id=u.id";const p=[];if(startDate&&endDate){sql+=" WHERE DATE(m.created_at) BETWEEN ? AND ?";p.push(startDate,endDate)}sql+=" ORDER BY m.id";res.json({messages:db.prepare(sql).all(...p).map(m=>{m.created_at=normalizeToUTC(m.created_at);return m})})});
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
    // Server-side HTML sanitization
    let trimmed=content.trim().substring(0,10000);
    // 接龙消息跳过 HTML 清理（内容是 JSON，前端负责安全渲染）
    const isChain=trimmed.startsWith("[CHAIN]");
    if(isChain){
      // 验证 JSON 格式有效性
      try{const cd=JSON.parse(trimmed.substring(7));if(!cd.type||cd.type!=="chain"||!cd.topic)return}catch(e){return}
    }else{
      // Remove script/style/iframe/object/embed tags and their content
      trimmed=trimmed.replace(/<(script|style|iframe|object|embed|link|meta)[^>]*>[\s\S]*?<\/\1>/gi,'');
      trimmed=trimmed.replace(/<(script|style|iframe|object|embed|link|meta)[^>]*\/?>/gi,'');
      // Remove event handlers (onclick, onerror, etc.)
      trimmed=trimmed.replace(/\s+on[a-z]+\s*=\s*["'][^"']*["']/gi,'');
      trimmed=trimmed.replace(/\s+on[a-z]+\s*=\s*[^\s>]+/gi,'');
      // Remove javascript: URLs
      trimmed=trimmed.replace(/href\s*=\s*["']javascript:[^"']*["']/gi,'href="#"');
      if(!trimmed.replace(/<[^>]*>/g,'').trim()&&!/<br\s*\/?>/i.test(trimmed))return;
    }
    const safeReplyTo=(Number.isInteger(replyTo)&&replyTo>0)?replyTo:null;
    const nowUtc=new Date().toISOString();
    const result=db.prepare("INSERT INTO messages (user_id,username,content,reply_to,created_at) VALUES (?,?,?,?,?)").run(socket.user.userId,socket.user.username,trimmed,safeReplyTo,nowUtc);
    const user=db.prepare("SELECT nickname,avatar FROM users WHERE id=?").get(socket.user.userId);
    const message={id:result.lastInsertRowid,username:socket.user.username,nickname:user?user.nickname:socket.user.username,avatar:user?user.avatar:null,content:trimmed,type:"text",reply_to:safeReplyTo,created_at:nowUtc};
    io.emit("newMessage",message);
    // Strip HTML for push notification text
    let pushText;
    if(isChain){try{const cd=JSON.parse(trimmed.substring(7));pushText="[接龙] "+cd.topic}catch(e){pushText="[接龙]"}}
    else{pushText=trimmed.replace(/<[^>]*>/g,'').substring(0,200)}
    sendPushToOthers(socket.user.userId, user?user.nickname:socket.user.username, pushText);
  });

  // 接龙: 参与接龙更新消息
  socket.on("updateChain",(data)=>{
    if(!data||typeof data!=="object")return;
    const{messageId,content}=data;
    if(!messageId||!content||typeof content!=="string")return;
    if(!content.startsWith("[CHAIN]"))return;
    // 验证 JSON
    let chainData;
    try{chainData=JSON.parse(content.substring(7));if(!chainData.type||chainData.type!=="chain")return}catch(e){return}
    // 查找原始消息
    const origMsg=db.prepare("SELECT id,content FROM messages WHERE id=?").get(messageId);
    if(!origMsg||!origMsg.content.startsWith("[CHAIN]"))return;
    // 验证用户未重复参与
    let origData;
    try{origData=JSON.parse(origMsg.content.substring(7))}catch(e){return}
    const username=socket.user.username;
    if(origData.participants&&origData.participants.some(function(p){return p.username===username}))return;
    // 服务端自行追加参与者（防篡改）
    const user=db.prepare("SELECT nickname FROM users WHERE id=?").get(socket.user.userId);
    const myName=user?user.nickname:username;
    const newSeq=(origData.participants?origData.participants.length:0)+1;
    if(!origData.participants)origData.participants=[];
    origData.participants.push({seq:newSeq,username:username,name:myName,text:""});
    const newContent="[CHAIN]"+JSON.stringify(origData);
    // 更新数据库
    db.prepare("UPDATE messages SET content=? WHERE id=?").run(newContent,messageId);
    // 广播更新给所有客户端
    io.emit("chainUpdated",{messageId:messageId,content:newContent});
    // 推送通知
    sendPushToOthers(socket.user.userId, myName, "[接龙] "+myName+" 参与了: "+origData.topic);
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
    cd "$APP_DIR"
    # 检测已有 node_modules 是否与当前 Node.js 版本不匹配，若不匹配则清除重装
    if [ -d "node_modules/better-sqlite3/build" ]; then
        local need_rebuild=false
        node -e 'require("better-sqlite3")' 2>/dev/null || need_rebuild=true
        if [ "$need_rebuild" = true ]; then
            echo -e "${YELLOW}检测到原生模块与当前 Node.js 版本不匹配，正在重新编译...${NC}"
            rm -rf node_modules/better-sqlite3/build node_modules/better-sqlite3/prebuilds
            npm rebuild better-sqlite3
        fi
    fi
    npm install --production
    # 确保原生模块已针对当前 Node.js 版本编译
    npm rebuild 2>/dev/null || true
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
const defs={timezone:"Asia/Shanghai",login_title:"团队聊天室",chat_title:"团队聊天",send_text:"发送",send_color:"#667eea",bg_type:"color",bg_color:"#f5f5f5",bg_image:"",bg_mode:"cover",bg_video:"",bg_video_url:"",bg_video_mode:"cover",pinned_notice:"",pinned_notice_enabled:"0",registration_open:"0",login_bg_type:"gradient",login_bg_color1:"#667eea",login_bg_color2:"#764ba2",login_bg_image:"",login_bg_mode:"cover"};
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
    local pm2name="${1:-teamchat}"
    echo -e "\n${YELLOW}阶段 6/6: 配置并启动服务 ($pm2name)...${NC}"
    pm2 stop "$pm2name" > /dev/null 2>&1 || true
    pm2 delete "$pm2name" > /dev/null 2>&1 || true
    cd "$APP_DIR"; PORT=$PORT pm2 start server.js --name "$pm2name"; pm2 save
    pm2 startup systemd -u root --hp /root > /dev/null 2>&1 || pm2 startup > /dev/null 2>&1 || true
    pm2 save
    echo -e "${GREEN}✅ 服务配置完成${NC}"
}

detect_existing_ssl() {
    local domain="$1"
    # 检查是否存在 Let's Encrypt 证书
    if [ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ] && [ -f "/etc/letsencrypt/live/${domain}/privkey.pem" ]; then
        return 0
    fi
    # 检查通配符或其他证书名
    if [ -f /etc/nginx/conf.d/teamchat.conf ] && grep -q "ssl_certificate" /etc/nginx/conf.d/teamchat.conf 2>/dev/null; then
        return 0
    fi
    return 1
}

get_existing_ssl_domain() {
    # 从现有 nginx 配置中提取 SSL 域名
    if [ -f /etc/nginx/conf.d/teamchat.conf ]; then
        local d
        d=$(grep -oP 'ssl_certificate\s+/etc/letsencrypt/live/\K[^/]+' /etc/nginx/conf.d/teamchat.conf 2>/dev/null | head -1)
        if [ -n "$d" ]; then echo "$d"; return 0; fi
        d=$(grep -oP 'server_name\s+\K[^;]+' /etc/nginx/conf.d/teamchat.conf 2>/dev/null | head -1 | awk '{print $1}')
        if [ -n "$d" ] && [ "$d" != "_" ]; then echo "$d"; return 0; fi
    fi
    return 1
}

generate_nginx_config() {
    local domain="$1" use_ssl="$2" port
    port=$(get_current_port)
    [ -f /etc/nginx/sites-enabled/default ] && rm -f /etc/nginx/sites-enabled/default
    [ -f /etc/nginx/conf.d/default.conf ] && mv /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf.bak

    # 检查是否有现有 SSL 证书可复用
    if [ "$use_ssl" = "yes" ] && detect_existing_ssl "$domain"; then
        echo -e "${GREEN}✅ 检测到域名 ${domain} 的现有 SSL 证书，直接复用${NC}"
        # 只更新 proxy_pass 端口，保留 SSL 配置
        if [ -f /etc/nginx/conf.d/teamchat.conf ] && grep -q "ssl_certificate" /etc/nginx/conf.d/teamchat.conf 2>/dev/null; then
            sed -i "s|proxy_pass http://127.0.0.1:[0-9]*|proxy_pass http://127.0.0.1:$port|g" /etc/nginx/conf.d/teamchat.conf
            sed -i "s|server_name .*;|server_name $domain;|g" /etc/nginx/conf.d/teamchat.conf
            if nginx -t 2>&1; then
                systemctl enable nginx 2>/dev/null || true; systemctl reload nginx
                echo -e "${GREEN}✅ Nginx SSL 配置已更新（复用现有证书）${NC}"
                return 0
            else
                echo -e "${YELLOW}现有配置更新失败，将重新生成...${NC}"
            fi
        fi
        # 现有配置文件格式异常，用证书路径重新生成完整 SSL 配置
        if [ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]; then
            cat > /etc/nginx/conf.d/teamchat.conf <<EOF
server {
    listen 80;
    server_name $domain;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    server_name $domain;
    client_max_body_size 120M;
    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
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
            if nginx -t 2>&1; then
                systemctl enable nginx 2>/dev/null || true; systemctl restart nginx
                systemctl enable certbot.timer 2>/dev/null || true; systemctl start certbot.timer 2>/dev/null || true
                echo -e "${GREEN}✅ Nginx SSL 配置已重新生成（复用现有证书）${NC}"
                return 0
            fi
        fi
    fi

    # 没有现有证书，写入基础 HTTP 配置
    cat > /etc/nginx/conf.d/teamchat.conf <<EOF
server {
    listen 80;
    server_name $domain;
    client_max_body_size 120M;
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

#===============================================================================
# 多实例管理
#===============================================================================

INSTANCES_DIR="/var/www"
INSTANCES_PREFIX="teamchat"

get_instance_domain() {
    # 从 nginx 配置文件中提取 server_name
    local conf_file="$1"
    if [ -f "$conf_file" ]; then
        local d
        d=$(grep -oP 'server_name\s+\K[^;]+' "$conf_file" 2>/dev/null | head -1 | awk '{print $1}')
        if [ -n "$d" ] && [ "$d" != "_" ]; then echo "$d"; return 0; fi
    fi
    echo "-"
}

get_instance_ssl_status() {
    # 检查 nginx 配置是否启用了 SSL
    local conf_file="$1"
    if [ -f "$conf_file" ] && grep -q "ssl_certificate" "$conf_file" 2>/dev/null; then
        echo "HTTPS"
    else
        echo "HTTP"
    fi
}

list_instances() {
    local found=0
    echo ""
    echo -e "${CYAN}  当前已部署的实例:${NC}"
    echo -e "${CYAN}  ────────────────────────────────────────────────────────────${NC}"
    printf "  ${CYAN}%-18s %-28s %-6s %-7s %-7s${NC}\n" "实例名" "域名/IP" "端口" "协议" "状态"
    echo -e "${CYAN}  ────────────────────────────────────────────────────────────${NC}"
    # 默认实例
    if [ -d "$APP_DIR/node_modules" ] && [ -f "$APP_DIR/server.js" ]; then
        local dport ddomain dssl dstatus
        dport=$(grep -oP 'const PORT = process\.env\.PORT \|\| \K\d+' "$APP_DIR/server.js" 2>/dev/null || echo "3000")
        ddomain=$(get_instance_domain "/etc/nginx/conf.d/teamchat.conf")
        dssl=$(get_instance_ssl_status "/etc/nginx/conf.d/teamchat.conf")
        dstatus="stopped"
        pm2 describe teamchat >/dev/null 2>&1 && dstatus="running"
        printf "  ${GREEN}%-18s${NC} %-28s %-6s %-7s %-7s\n" "teamchat (默认)" "$ddomain" "$dport" "$dssl" "$dstatus"
        found=1
    fi
    # 额外实例
    for dir in "$INSTANCES_DIR"/${INSTANCES_PREFIX}-*; do
        [ -d "$dir" ] || continue
        [ -f "$dir/server.js" ] || continue
        local name=$(basename "$dir")
        local pm2name="$name"
        local iport idomain issl istatus
        iport=$(grep -oP 'const PORT = process\.env\.PORT \|\| \K\d+' "$dir/server.js" 2>/dev/null || echo "?")
        idomain=$(get_instance_domain "/etc/nginx/conf.d/${pm2name}.conf")
        issl=$(get_instance_ssl_status "/etc/nginx/conf.d/${pm2name}.conf")
        istatus="stopped"
        pm2 describe "$pm2name" >/dev/null 2>&1 && istatus="running"
        printf "  ${GREEN}%-18s${NC} %-28s %-6s %-7s %-7s\n" "$pm2name" "$idomain" "$iport" "$issl" "$istatus"
        found=1
    done
    if [ "$found" -eq 0 ]; then
        echo -e "  ${YELLOW}暂无已部署的实例${NC}"
    fi
    echo -e "${CYAN}  ────────────────────────────────────────────────────────────${NC}"
    echo ""
}

do_multi_instance() {
    echo -e "\n${YELLOW}========== 多实例管理 ==========${NC}"
    list_instances
    echo -e "  ${GREEN}1${NC}. 部署新实例"
    echo -e "  ${GREEN}2${NC}. 更新指定实例"
    echo -e "  ${GREEN}3${NC}. 启动/重启指定实例"
    echo -e "  ${GREEN}4${NC}. 停止指定实例"
    echo -e "  ${GREEN}5${NC}. 查看指定实例日志"
    echo -e "  ${GREEN}6${NC}. 删除指定实例"
    echo -e "  ${GREEN}0${NC}. 返回主菜单"
    printf "请选择: "; read -r mi_choice
    case $mi_choice in
        1) do_new_instance ;;
        2) do_update_selected_instance ;;
        3) do_instance_action "restart" ;;
        4) do_instance_action "stop" ;;
        5) do_instance_action "logs" ;;
        6) do_instance_action "delete" ;;
        0) return ;;
        *) echo -e "${RED}无效${NC}" ;;
    esac
}

do_update_selected_instance() {
    echo ""
    select_instance "更新" || return
    echo ""
    echo -e "${CYAN}  → 将更新实例: ${SELECTED_PM2NAME}${NC}"
    echo -e "${CYAN}  → 路径: ${SELECTED_DIR}${NC}"
    printf "确认更新? (y/n): "; read -r confirm; [ "$confirm" != "y" ] && { echo "已取消"; return 0; }

    local ORIG_APP_DIR="$APP_DIR"
    APP_DIR="$SELECTED_DIR"
    PORT=$(grep -oP 'const PORT = process\.env\.PORT \|\| \K\d+' "$APP_DIR/server.js" 2>/dev/null || echo "3000")

    detect_os; install_dependencies; install_nodejs; write_app_files; install_npm_deps; update_database
    setup_service "$SELECTED_PM2NAME"
    APP_DIR="$ORIG_APP_DIR"

    echo ""
    echo -e "${GREEN}================================================${NC}"
    echo -e "${GREEN}  🎉 实例 ${SELECTED_PM2NAME} 更新完成！${NC}"
    echo -e "${GREEN}  ✅ 所有用户数据、聊天记录和设置已保留${NC}"
    echo -e "${GREEN}================================================${NC}"
    echo -e "${YELLOW}建议用户清除浏览器缓存以获取最新界面${NC}"
    echo ""
}

do_new_instance() {
    echo -e "\n${CYAN}>>> 部署新实例 <<<${NC}\n"
    # 实例名称
    local inst_name=""
    while true; do
        printf "  实例名称 (英文，如 team2, sales): "; read -r inst_name
        if [ -z "$inst_name" ]; then echo -e "${RED}名称不能为空${NC}"; continue; fi
        if [[ ! "$inst_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then echo -e "${RED}只允许英文字母、数字、下划线和短横线${NC}"; continue; fi
        if [ "$inst_name" = "teamchat" ]; then echo -e "${RED}此名称已被默认实例使用${NC}"; continue; fi
        local inst_dir="$INSTANCES_DIR/${INSTANCES_PREFIX}-${inst_name}"
        if [ -d "$inst_dir" ] && [ -f "$inst_dir/server.js" ]; then echo -e "${RED}实例 ${inst_name} 已存在${NC}"; continue; fi
        break
    done

    local inst_dir="$INSTANCES_DIR/${INSTANCES_PREFIX}-${inst_name}"
    local pm2name="${INSTANCES_PREFIX}-${inst_name}"

    # 域名/IP 选择 —— 支持独立域名
    local INST_DOMAIN="" inst_use_ssl=""
    echo ""
    echo -e "${YELLOW}请选择此实例的访问方式:${NC}"
    echo "  1. 使用独立域名 (推荐，可配置 HTTPS)"
    echo "  2. 使用 IP 地址访问"
    printf "请选择 [1]: "; read -r domain_choice
    domain_choice=${domain_choice:-1}

    if [ "$domain_choice" = "1" ]; then
        # 域名模式
        while true; do
            printf "  请输入此实例的域名 (如 chat2.example.com): "; read -r INST_DOMAIN
            if [ -z "$INST_DOMAIN" ]; then echo -e "${RED}域名不能为空${NC}"; continue; fi
            if [[ "$INST_DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo -e "${YELLOW}这看起来是 IP 地址，如需使用 IP 请选择选项 2${NC}"; continue
            fi
            # 检查域名是否已被其他实例使用
            local domain_conflict=0
            for conf in /etc/nginx/conf.d/*.conf; do
                [ -f "$conf" ] || continue
                if grep -qP "server_name\s+.*\b${INST_DOMAIN}\b" "$conf" 2>/dev/null; then
                    echo -e "${RED}域名 ${INST_DOMAIN} 已被 $(basename "$conf" .conf) 使用${NC}"
                    domain_conflict=1; break
                fi
            done
            [ "$domain_conflict" -eq 1 ] && continue
            break
        done

        # SSL 配置
        local existing_cert=0
        if [ -f "/etc/letsencrypt/live/${INST_DOMAIN}/fullchain.pem" ] && \
           [ -f "/etc/letsencrypt/live/${INST_DOMAIN}/privkey.pem" ]; then
            existing_cert=1
            echo -e "${GREEN}✅ 检测到域名 ${INST_DOMAIN} 的现有 SSL 证书${NC}"
            printf "是否启用 HTTPS (复用现有证书)? (y/n) [y]: "; read -r inst_use_ssl
            inst_use_ssl=${inst_use_ssl:-y}
        else
            printf "是否配置 SSL/HTTPS? (y/n) [n]: "; read -r inst_use_ssl
            inst_use_ssl=${inst_use_ssl:-n}
        fi
    else
        # IP 模式
        INST_DOMAIN=$(show_ip_menu)
        inst_use_ssl="n"
    fi

    echo ""
    while true; do printf "  管理员用户名 [admin]: "; read -r input; ADMIN_USER=${input:-admin}; validate_input "$ADMIN_USER" "用户名" && break; done
    while true; do printf "  管理员密码 [admin123]: "; read -r input; ADMIN_PASS=${input:-admin123}; [ ${#ADMIN_PASS} -ge 6 ] && break; echo -e "${RED}密码不能小于6位${NC}"; done
    while true; do printf "  服务端口 (不能与其他实例重复): "; read -r input
        if [ -z "$input" ]; then echo -e "${RED}端口不能为空${NC}"; continue; fi
        PORT="$input"
        [[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] && break
        echo -e "${RED}端口无效${NC}"
    done

    echo ""
    echo "==========================================="
    echo "  实例名: $pm2name"
    echo "  域名/IP: $INST_DOMAIN | 端口: $PORT"
    echo "  管理员: $ADMIN_USER | 路径: $inst_dir"
    echo "  HTTPS: $([ "$inst_use_ssl" = "y" ] || [ "$inst_use_ssl" = "Y" ] && echo 是 || echo 否)"
    echo "==========================================="
    printf "确认部署? (y/n): "; read -r confirm; [ "$confirm" != "y" ] && { echo "已取消"; return 0; }

    # 保存原 APP_DIR，临时切换
    local ORIG_APP_DIR="$APP_DIR"
    APP_DIR="$inst_dir"

    detect_os
    # 依赖只装一次（检查 node 是否可用）
    command -v node >/dev/null 2>&1 || { install_dependencies; install_nodejs; }
    command -v pm2 >/dev/null 2>&1 || npm install -g pm2

    write_app_files
    install_npm_deps
    init_database

    # 启动实例（使用自定义 pm2 名称）
    echo -e "\n${YELLOW}启动实例 $pm2name ...${NC}"
    pm2 stop "$pm2name" > /dev/null 2>&1 || true
    pm2 delete "$pm2name" > /dev/null 2>&1 || true
    cd "$inst_dir"; PORT=$PORT pm2 start server.js --name "$pm2name"; pm2 save
    pm2 startup systemd -u root --hp /root > /dev/null 2>&1 || pm2 startup > /dev/null 2>&1 || true
    pm2 save

    # 生成独立 nginx 配置
    local nginx_conf="/etc/nginx/conf.d/${pm2name}.conf"

    if [ "$inst_use_ssl" = "y" ] || [ "$inst_use_ssl" = "Y" ]; then
        # 检查是否有现有证书可复用
        if [ -f "/etc/letsencrypt/live/${INST_DOMAIN}/fullchain.pem" ] && \
           [ -f "/etc/letsencrypt/live/${INST_DOMAIN}/privkey.pem" ]; then
            echo -e "${GREEN}✅ 复用域名 ${INST_DOMAIN} 的现有 SSL 证书${NC}"
            cat > "$nginx_conf" <<EOF
server {
    listen 80;
    server_name $INST_DOMAIN;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    server_name $INST_DOMAIN;
    client_max_body_size 120M;
    ssl_certificate /etc/letsencrypt/live/$INST_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$INST_DOMAIN/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
    location / {
        proxy_pass http://127.0.0.1:$PORT;
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
        else
            # 先写 HTTP 配置，用于 certbot 验证
            cat > "$nginx_conf" <<EOF
server {
    listen 80;
    server_name $INST_DOMAIN;
    client_max_body_size 120M;
    location / {
        proxy_pass http://127.0.0.1:$PORT;
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
            if nginx -t 2>&1; then
                systemctl enable nginx 2>/dev/null || true; systemctl reload nginx
            else
                echo -e "${YELLOW}Nginx 配置测试失败，跳过 SSL 申请${NC}"
                inst_use_ssl="n"
            fi

            if [ "$inst_use_ssl" = "y" ] || [ "$inst_use_ssl" = "Y" ]; then
                echo -e "${YELLOW}正在为 ${INST_DOMAIN} 申请 SSL 证书...${NC}"
                printf "  邮箱 [admin@${INST_DOMAIN}]: "; read -r ssl_email
                ssl_email=${ssl_email:-admin@${INST_DOMAIN}}
                if certbot --nginx -d "$INST_DOMAIN" --non-interactive --agree-tos --email "$ssl_email" 2>/dev/null || \
                   certbot --nginx -d "$INST_DOMAIN" --agree-tos --email "$ssl_email"; then
                    systemctl enable certbot.timer 2>/dev/null || true
                    systemctl start certbot.timer 2>/dev/null || true
                    echo -e "${GREEN}✅ SSL 证书申请成功${NC}"
                else
                    echo -e "${YELLOW}SSL 证书申请失败，可稍后手动运行: sudo certbot --nginx -d $INST_DOMAIN${NC}"
                    echo -e "${YELLOW}实例将以 HTTP 模式运行${NC}"
                    inst_use_ssl="n"
                fi
            fi
        fi
    else
        # 纯 HTTP 模式
        cat > "$nginx_conf" <<EOF
server {
    listen 80;
    server_name $INST_DOMAIN;
    client_max_body_size 120M;
    location / {
        proxy_pass http://127.0.0.1:$PORT;
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
    fi

    if nginx -t 2>&1; then
        systemctl enable nginx 2>/dev/null || true; systemctl reload nginx
        echo -e "${GREEN}✅ Nginx 配置完成${NC}"
    else
        echo -e "${YELLOW}Nginx 配置测试失败，请手动检查 $nginx_conf${NC}"
    fi

    # 恢复 APP_DIR
    APP_DIR="$ORIG_APP_DIR"

    echo ""
    echo -e "${GREEN}================================================${NC}"
    echo -e "${GREEN}  🎉 实例 $pm2name 部署完成！${NC}"
    echo -e "${GREEN}================================================${NC}"
    if [ "$inst_use_ssl" = "y" ] || [ "$inst_use_ssl" = "Y" ]; then
        echo -e "  访问: https://${INST_DOMAIN}"
    else
        echo -e "  访问: http://${INST_DOMAIN}:${PORT}"
    fi
    echo -e "  管理员: $ADMIN_USER / $ADMIN_PASS"
    echo -e "  PM2 名称: $pm2name"
    echo -e "  数据路径: $inst_dir"
    echo -e "${GREEN}================================================${NC}"
    echo ""
    echo -e "${YELLOW}📱 推送通知说明:${NC}"
    echo "  - Android Chrome: 打开网页 → 设置 → 开启推送通知即可"
    echo "  - iOS Safari (16.4+): 先点'分享'→'添加到主屏幕'→从主屏图标打开→设置→开启推送"
    echo "  - 推送需要 HTTPS 或 localhost"
    echo ""
}

select_instance() {
    local action_name="$1"
    local instances=()
    local idx=0

    # 默认实例
    if [ -d "$APP_DIR/node_modules" ] && [ -f "$APP_DIR/server.js" ]; then
        instances+=("teamchat|$APP_DIR")
        idx=$((idx+1))
        echo "  $idx. teamchat (默认)"
    fi
    # 额外实例
    for dir in "$INSTANCES_DIR"/${INSTANCES_PREFIX}-*; do
        [ -d "$dir" ] || continue
        [ -f "$dir/server.js" ] || continue
        local name=$(basename "$dir")
        instances+=("$name|$dir")
        idx=$((idx+1))
        echo "  $idx. $name"
    done
    if [ "$idx" -eq 0 ]; then echo -e "${YELLOW}暂无可用实例${NC}"; return 1; fi
    printf "请选择要${action_name}的实例 [1]: "; read -r sel
    sel=${sel:-1}
    if [[ ! "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt "$idx" ]; then
        echo -e "${RED}无效选择${NC}"; return 1
    fi
    SELECTED_INSTANCE="${instances[$((sel-1))]}"
    SELECTED_PM2NAME="${SELECTED_INSTANCE%%|*}"
    SELECTED_DIR="${SELECTED_INSTANCE##*|}"
    return 0
}

do_instance_action() {
    local action="$1"
    echo ""
    local action_label=""
    case $action in
        restart) action_label="启动/重启" ;;
        stop) action_label="停止" ;;
        logs) action_label="查看日志" ;;
        delete) action_label="删除" ;;
    esac
    select_instance "$action_label" || return
    case $action in
        restart)
            if pm2 describe "$SELECTED_PM2NAME" >/dev/null 2>&1; then
                pm2 restart "$SELECTED_PM2NAME"
            else
                cd "$SELECTED_DIR"; pm2 start server.js --name "$SELECTED_PM2NAME"; pm2 save
            fi
            echo -e "${GREEN}✅ 实例 $SELECTED_PM2NAME 已启动/重启${NC}" ;;
        stop)
            pm2 stop "$SELECTED_PM2NAME" 2>/dev/null || true
            echo -e "${GREEN}✅ 实例 $SELECTED_PM2NAME 已停止${NC}" ;;
        logs)
            pm2 logs "$SELECTED_PM2NAME" --lines 50 --nostream ;;
        delete)
            if [ "$SELECTED_PM2NAME" = "teamchat" ]; then
                echo -e "${YELLOW}默认实例请使用主菜单「卸载程序」功能${NC}"; return
            fi
            echo -e "${RED}警告: 将删除实例 $SELECTED_PM2NAME 的所有数据！${NC}"
            printf "输入实例名 '${SELECTED_PM2NAME}' 确认删除: "; read -r confirm_del
            if [ "$confirm_del" != "$SELECTED_PM2NAME" ]; then echo "已取消"; return; fi
            pm2 stop "$SELECTED_PM2NAME" 2>/dev/null || true
            pm2 delete "$SELECTED_PM2NAME" 2>/dev/null || true
            pm2 save 2>/dev/null || true
            rm -rf "$SELECTED_DIR"
            rm -f "/etc/nginx/conf.d/${SELECTED_PM2NAME}.conf"
            nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
            echo -e "${GREEN}✅ 实例 $SELECTED_PM2NAME 已完全删除${NC}" ;;
    esac
}

#===============================================================================

update_database() {
    echo -e "\n${YELLOW}更新数据库结构...${NC}"
    cd "$APP_DIR"
    node -e '
const Database=require("better-sqlite3"),fs=require("fs"),path=require("path"),crypto=require("crypto");
const DB_PATH=path.join(process.env.PWD,"database.sqlite"),SF=path.join(process.env.PWD,".jwt_secret");
if(!fs.existsSync(SF))fs.writeFileSync(SF,crypto.randomBytes(32).toString("hex"),{mode:0o600});
const db=new Database(DB_PATH);db.pragma("journal_mode=WAL");db.pragma("foreign_keys=ON");
db.exec(`CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY AUTOINCREMENT,username TEXT UNIQUE NOT NULL,password TEXT NOT NULL,nickname TEXT,avatar TEXT,is_admin INTEGER DEFAULT 0,last_login_at TEXT,created_at DATETIME DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE IF NOT EXISTS messages (id INTEGER PRIMARY KEY AUTOINCREMENT,user_id INTEGER NOT NULL,username TEXT NOT NULL,content TEXT,type TEXT DEFAULT "text",file_name TEXT,file_path TEXT,file_size INTEGER,reply_to INTEGER,created_at DATETIME DEFAULT CURRENT_TIMESTAMP,FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE);
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY,value TEXT NOT NULL,updated_at DATETIME DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE IF NOT EXISTS push_subscriptions (id INTEGER PRIMARY KEY AUTOINCREMENT,user_id INTEGER NOT NULL,endpoint TEXT UNIQUE NOT NULL,keys_p256dh TEXT NOT NULL,keys_auth TEXT NOT NULL,created_at DATETIME DEFAULT CURRENT_TIMESTAMP,FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE);`);
try{db.exec("ALTER TABLE users ADD COLUMN is_admin INTEGER DEFAULT 0")}catch(e){}
try{db.exec("ALTER TABLE messages ADD COLUMN reply_to INTEGER")}catch(e){}
try{db.exec("ALTER TABLE users ADD COLUMN last_login_at TEXT")}catch(e){}
const defs={timezone:"Asia/Shanghai",login_title:"团队聊天室",chat_title:"团队聊天",send_text:"发送",send_color:"#667eea",bg_type:"color",bg_color:"#f5f5f5",bg_image:"",bg_mode:"cover",bg_video:"",bg_video_url:"",bg_video_mode:"cover",pinned_notice:"",pinned_notice_enabled:"0",registration_open:"0",login_bg_type:"gradient",login_bg_color1:"#667eea",login_bg_color2:"#764ba2",login_bg_image:"",login_bg_mode:"cover"};
const ins=db.prepare("INSERT OR IGNORE INTO settings (key,value) VALUES (?,?)");for(const[k,v] of Object.entries(defs))ins.run(k,v);
const cnt=db.prepare("SELECT COUNT(*) as c FROM users WHERE is_admin=1").get();
if(!cnt||cnt.c===0){console.log("⚠️  未找到管理员，可通过菜单选项5修改配置来设置管理员")}
else{console.log("✅ 数据库结构已更新，保留所有用户数据和设置")}
db.close();
'
    chmod 600 "$APP_DIR/.jwt_secret" "$APP_DIR/.vapid_keys" 2>/dev/null || true
    chmod 600 "$APP_DIR/database.sqlite" 2>/dev/null || true
    echo -e "${GREEN}✅ 数据库更新完成${NC}"
}

do_install() {
    print_header

    # ===== 扫描所有已有实例 =====
    local all_instances=()
    local inst_idx=0

    # 默认实例
    if [ -f "$APP_DIR/database.sqlite" ] && [ -f "$APP_DIR/server.js" ]; then
        local dport dadmin
        dport=$(grep -oP 'const PORT = process\.env\.PORT \|\| \K\d+' "$APP_DIR/server.js" 2>/dev/null || echo "3000")
        dadmin=$(cd "$APP_DIR" && node -e "const D=require('better-sqlite3');try{const d=new D('database.sqlite');const u=d.prepare('SELECT username FROM users WHERE is_admin=1 LIMIT 1').get();if(u)process.stdout.write(u.username)}catch(e){}" 2>/dev/null || echo "admin")
        all_instances+=("teamchat|$APP_DIR|$dport|$dadmin|teamchat.conf")
        inst_idx=$((inst_idx+1))
    fi
    # 多实例
    for dir in "$INSTANCES_DIR"/${INSTANCES_PREFIX}-*; do
        [ -d "$dir" ] || continue
        [ -f "$dir/server.js" ] || continue
        local iname=$(basename "$dir")
        local iport iadmin
        iport=$(grep -oP 'const PORT = process\.env\.PORT \|\| \K\d+' "$dir/server.js" 2>/dev/null || echo "?")
        iadmin=$(cd "$dir" && node -e "const D=require('better-sqlite3');try{const d=new D('database.sqlite');const u=d.prepare('SELECT username FROM users WHERE is_admin=1 LIMIT 1').get();if(u)process.stdout.write(u.username)}catch(e){}" 2>/dev/null || echo "?")
        all_instances+=("$iname|$dir|$iport|$iadmin|${iname}.conf")
        inst_idx=$((inst_idx+1))
    done

    local IS_UPDATE="false"
    local UPDATE_PM2NAME="teamchat"
    local UPDATE_DIR="$APP_DIR"
    local UPDATE_NGINX_CONF="teamchat.conf"

    if [ "$inst_idx" -gt 0 ]; then
        echo ""
        echo -e "${GREEN}================================================${NC}"
        echo -e "${GREEN}  ✅ 检测到已有实例 (共 ${inst_idx} 个)${NC}"
        echo -e "${GREEN}================================================${NC}"
        echo ""
        local i=0
        for entry in "${all_instances[@]}"; do
            i=$((i+1))
            local ename eport eadmin
            ename="${entry%%|*}"
            eport=$(echo "$entry" | cut -d'|' -f3)
            eadmin=$(echo "$entry" | cut -d'|' -f4)
            if [ "$ename" = "teamchat" ]; then
                echo -e "  ${GREEN}${i}${NC}. 更新 ${CYAN}$ename (默认)${NC}  端口:$eport  管理员:$eadmin"
            else
                echo -e "  ${GREEN}${i}${NC}. 更新 ${CYAN}$ename${NC}  端口:$eport  管理员:$eadmin"
            fi
        done
        if [ "$inst_idx" -gt 1 ]; then
            echo -e "  ${GREEN}A${NC}. 更新全部实例"
        fi
        echo -e "  ${GREEN}N${NC}. 全新安装 (新建默认实例)"
        echo -e "  ${GREEN}0${NC}. 返回主菜单"
        echo ""
        printf "请选择 [1]: "; read -r install_mode
        install_mode=${install_mode:-1}

        case $install_mode in
            0) return 0 ;;
            [Nn]) IS_UPDATE="false" ;;
            [Aa])
                # 更新全部实例
                echo ""
                echo -e "${CYAN}将更新全部 ${inst_idx} 个实例...${NC}"
                detect_os; install_dependencies; install_nodejs
                local ORIG_APP_DIR="$APP_DIR"
                for entry in "${all_instances[@]}"; do
                    local ename edir eport eadmin enginx
                    ename=$(echo "$entry" | cut -d'|' -f1)
                    edir=$(echo "$entry" | cut -d'|' -f2)
                    eport=$(echo "$entry" | cut -d'|' -f3)
                    eadmin=$(echo "$entry" | cut -d'|' -f4)
                    enginx=$(echo "$entry" | cut -d'|' -f5)
                    echo ""
                    echo -e "${YELLOW}━━━ 正在更新 $ename (端口:$eport) ━━━${NC}"
                    APP_DIR="$edir"
                    PORT="$eport"
                    write_app_files; install_npm_deps; update_database
                    setup_service "$ename"
                    echo -e "${GREEN}✅ $ename 更新完成${NC}"
                done
                APP_DIR="$ORIG_APP_DIR"
                echo ""
                echo -e "${GREEN}================================================${NC}"
                echo -e "${GREEN}  🎉 全部 ${inst_idx} 个实例已更新！${NC}"
                echo -e "${GREEN}  ✅ 所有用户数据、聊天记录和设置已保留${NC}"
                echo -e "${GREEN}================================================${NC}"
                echo ""
                echo -e "${YELLOW}更新提示: 建议用户清除浏览器缓存以获取最新界面${NC}"
                echo ""
                return 0
                ;;
            *)
                # 更新指定实例
                if [[ "$install_mode" =~ ^[0-9]+$ ]] && [ "$install_mode" -ge 1 ] && [ "$install_mode" -le "$inst_idx" ]; then
                    local sel_entry="${all_instances[$((install_mode-1))]}"
                    UPDATE_PM2NAME=$(echo "$sel_entry" | cut -d'|' -f1)
                    UPDATE_DIR=$(echo "$sel_entry" | cut -d'|' -f2)
                    UPDATE_NGINX_CONF=$(echo "$sel_entry" | cut -d'|' -f5)
                    IS_UPDATE="true"
                else
                    echo -e "${RED}无效选择${NC}"; return 0
                fi
                ;;
        esac
    fi

    if [ "$IS_UPDATE" = "true" ]; then
        # 临时切换到目标实例目录
        local ORIG_APP_DIR="$APP_DIR"
        APP_DIR="$UPDATE_DIR"
        PORT=$(grep -oP 'const PORT = process\.env\.PORT \|\| \K\d+' "$APP_DIR/server.js" 2>/dev/null || echo "3000")
        ADMIN_USER=$(cd "$APP_DIR" && node -e "const D=require('better-sqlite3');try{const d=new D('database.sqlite');const u=d.prepare('SELECT username FROM users WHERE is_admin=1 LIMIT 1').get();if(u)process.stdout.write(u.username)}catch(e){}" 2>/dev/null || echo "admin")

        echo ""
        echo -e "${CYAN}  → 更新实例: ${UPDATE_PM2NAME}${NC}"
        echo -e "${CYAN}  → 保留端口 ${PORT}、管理员 ${ADMIN_USER} 及所有数据${NC}"
        echo ""
        echo "==========================================="
        echo "  模式: 🔄 更新 $UPDATE_PM2NAME | 端口: $PORT | 管理员: $ADMIN_USER"
        echo "==========================================="
        printf "确认更新? (y/n): "; read -r confirm; [ "$confirm" != "y" ] && { APP_DIR="$ORIG_APP_DIR"; echo "已取消"; return 0; }

        detect_os; install_dependencies; install_nodejs; write_app_files; install_npm_deps; update_database
        setup_service "$UPDATE_PM2NAME"
        APP_DIR="$ORIG_APP_DIR"

        echo ""
        echo -e "${GREEN}================================================${NC}"
        echo -e "${GREEN}  🎉 实例 ${UPDATE_PM2NAME} 更新完成！${NC}"
        echo -e "${GREEN}  ✅ 所有用户数据、聊天记录和设置已保留${NC}"
        echo -e "${GREEN}================================================${NC}"
        echo ""
        echo -e "${YELLOW}更新提示: 建议用户清除浏览器缓存以获取最新界面${NC}"
        echo ""
        return 0
    fi

    # ===== 全新安装流程 =====
    DOMAIN=$(show_ip_menu)

    echo ""; echo -e "请配置以下参数:"
    while true; do printf "  管理员用户名 [admin]: "; read -r input; ADMIN_USER=${input:-admin}; validate_input "$ADMIN_USER" "用户名" && break; done
    while true; do printf "  管理员密码 [admin123]: "; read -r input; ADMIN_PASS=${input:-admin123}; [ ${#ADMIN_PASS} -ge 6 ] && break; echo -e "${RED}密码不能小于6位${NC}"; done
    while true; do printf "  服务端口 [3000]: "; read -r input; PORT=${input:-3000}; [[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] && break; echo -e "${RED}端口无效${NC}"; done

    # 检测现有 SSL 配置
    local existing_ssl_domain="" use_ssl="" domain=""
    existing_ssl_domain=$(get_existing_ssl_domain 2>/dev/null) || true

    if [ -n "$existing_ssl_domain" ] && detect_existing_ssl "$existing_ssl_domain"; then
        echo ""
        echo -e "${GREEN}✅ 检测到现有 SSL 证书: ${existing_ssl_domain}${NC}"
        printf "是否沿用此 HTTPS 配置? (y/n) [y]: "; read -r reuse_ssl
        if [ "$reuse_ssl" != "n" ] && [ "$reuse_ssl" != "N" ]; then
            use_ssl="y"; domain="$existing_ssl_domain"
            echo -e "${GREEN}  → 将复用现有证书，无需重新申请${NC}"
        else
            echo ""; printf "是否配置新的 SSL/HTTPS? (y/n) [n]: "; read -r use_ssl
            if [ "$use_ssl" = "y" ]||[ "$use_ssl" = "Y" ]; then
                echo -n "  请输入域名: "; read domain; while [ -z "$domain" ]; do echo -n "  域名不能为空: "; read domain; done
            else domain=$DOMAIN; fi
        fi
    else
        echo ""; printf "是否配置 SSL/HTTPS? (y/n) [n]: "; read -r use_ssl
        if [ "$use_ssl" = "y" ]||[ "$use_ssl" = "Y" ]; then
            echo -n "  请输入域名: "; read domain; while [ -z "$domain" ]; do echo -n "  域名不能为空: "; read domain; done
        else domain=$DOMAIN; fi
    fi

    echo ""
    echo "==========================================="
    echo "  模式: 🆕 全新安装 | 端口: $PORT | 管理员: $ADMIN_USER"
    echo "  域名/IP: $domain | HTTPS: $([ "$use_ssl" = "y" ]||[ "$use_ssl" = "Y" ] && echo 是 || echo 否)"
    echo "==========================================="
    printf "确认部署? (y/n): "; read -r confirm; [ "$confirm" != "y" ] && { echo "已取消"; return 0; }

    detect_os; install_dependencies; install_nodejs; write_app_files; install_npm_deps; init_database
    setup_service "teamchat"
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
    echo "  - Android Chrome: 打开网页 → 设置 → 开启推送通知即可"
    echo "  - iOS Safari (16.4+): 先点'分享'→'添加到主屏幕'→从主屏图标打开→设置→开启推送"
    echo "  - iOS 需要 16.4 或更高版本才支持 PWA 推送"
    echo "  - 推送需要 HTTPS（已配置 SSL）或 localhost"
    echo "  - 升级提示: 如从旧版升级，请在设置中先关闭再重新开启推送通知"
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

    # 检查是否已有该域名的证书
    if detect_existing_ssl "$domain"; then
        echo -e "${GREEN}✅ 检测到域名 ${domain} 的现有 SSL 证书${NC}"
        printf "是否复用现有证书? (y/n) [y]: "; read -r reuse
        if [ "$reuse" != "n" ]&&[ "$reuse" != "N" ]; then
            generate_nginx_config "$domain" "yes"
            echo -e "${GREEN}✅ SSL 配置完成（复用现有证书）！https://${domain}${NC}"
            return 0
        fi
        echo -e "${YELLOW}将重新申请证书...${NC}"
    fi

    cat > /etc/nginx/conf.d/teamchat.conf <<EOF
server { listen 80; server_name $domain; client_max_body_size 120M;
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
server { listen 80; server_name _; client_max_body_size 120M;
  location / { proxy_pass http://127.0.0.1:$port; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host \$host; proxy_set_header X-Real-IP \$remote_addr; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto \$scheme; } }
EOF
           nginx -t 2>/dev/null&&systemctl reload nginx; echo -e "${GREEN}✅ SSL已卸载${NC}" ;;
        0) return ;; *) echo -e "${RED}无效${NC}" ;;
    esac
}

check_root

if [ $# -gt 0 ]; then
    case $1 in
        --install|-i) do_install; exit 0 ;; --ssl|-s) do_ssl; exit 0 ;; --multi|-m) do_multi_instance; exit 0 ;; --uninstall|-u) do_uninstall; exit 0 ;;
        --uninstall-force) echo -e "${RED}警告: 删除所有数据！${NC}"; printf "输入 DELETE: "; read -r cf; [ "$cf" != "DELETE" ]&&exit 0
            pm2 stop teamchat 2>/dev/null||true; pm2 delete teamchat 2>/dev/null||true; pm2 save 2>/dev/null||true; rm -rf "$APP_DIR"; rm -f /etc/nginx/conf.d/teamchat.conf; nginx -t 2>/dev/null&&systemctl reload nginx 2>/dev/null||true; echo -e "${GREEN}✅ 完全卸载${NC}"; exit 0 ;;
        --help|-h) echo "用法: sudo $0 [--install|--ssl|--uninstall|--uninstall-force|--multi|--help]"; exit 0 ;;
        *) echo "未知选项: $1"; exit 1 ;;
    esac
fi

while true; do
    print_menu; read choice
    case $choice in 1) do_install;; 2) do_restart;; 3) do_stop;; 4) do_logs;; 5) do_modify;; 6) do_ssl;; 7) do_uninstall;; 8) do_multi_instance;; 0) echo -e "${GREEN}再见！${NC}"; exit 0;; *) echo -e "${RED}无效${NC}";; esac
    echo ""
done
