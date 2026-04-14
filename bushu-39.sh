#!/bin/bash
#===============================================================================
# TeamChat 一键部署脚本 (多频道增强版 v9.0.0)
# 基于 Vue 3 + Vite 前端 + Express 模块化后端
# 新增: 多频道支持、频道级权限控制 (RBAC)、响应式三栏布局
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
    echo -e "${CYAN}  TeamChat 一键部署脚本 v9.0.0 (多频道版)${NC}"
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
} catch(e) {}" 2>/dev/null)
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
# 写入应用程序文件 (Vue 3 SPA 前端 + 模块化 Express 后端)
#===============================================================================

write_app_files() {
    echo -e "\n${YELLOW}阶段 3/6: 正在写入应用程序文件...${NC}"

    mkdir -p "$APP_DIR"/{public/images,uploads,avatars,backgrounds}

    # ===== default-avatar.svg =====
    cat > "$APP_DIR/public/images/default-avatar.svg" <<'SVGEOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><circle cx="50" cy="50" r="50" fill="#667eea"/><circle cx="50" cy="38" r="16" fill="white"/><ellipse cx="50" cy="75" rx="28" ry="20" fill="white"/></svg>
SVGEOF

    # ===== PWA: manifest.json =====
    cat > "$APP_DIR/public/manifest.json" <<'MANIFESTEOF'
{
  "name": "TeamChat",
  "short_name": "TeamChat",
  "description": "多频道团队聊天室",
  "id": "/",
  "start_url": "/",
  "scope": "/",
  "display": "standalone",
  "background_color": "#667eea",
  "theme_color": "#667eea",
  "icons": [
    { "src": "/images/icon-192.png", "sizes": "192x192", "type": "image/png", "purpose": "any" },
    { "src": "/images/icon-512.png", "sizes": "512x512", "type": "image/png", "purpose": "any" },
    { "src": "/images/icon-maskable-192.png", "sizes": "192x192", "type": "image/png", "purpose": "maskable" },
    { "src": "/images/icon-maskable-512.png", "sizes": "512x512", "type": "image/png", "purpose": "maskable" }
  ]
}
MANIFESTEOF

    # ===== 生成 PWA 图标 =====
    cd "$APP_DIR" && node -e '
const fs = require("fs"), zlib = require("zlib");
function createPNG(w, h, r, g, b) {
  const px = Buffer.alloc(w * h * 4);
  const cx = w/2, cy = h/2, bW = w*0.5, bH = h*0.35;
  const bx1 = cx-bW/2, by1 = cy-bH/2-h*0.05, bx2 = cx+bW/2, by2 = cy+bH/2-h*0.05;
  const cR = Math.min(bW,bH)*0.25;
  for (let y=0;y<h;y++) for (let x=0;x<w;x++) {
    const i=(y*w+x)*4; px[i]=r;px[i+1]=g;px[i+2]=b;px[i+3]=255;
    let ins=false;
    if(x>=bx1&&x<=bx2&&y>=by1&&y<=by2){
      const lx=Math.max(bx1+cR-x,0,x-(bx2-cR)),ly=Math.max(by1+cR-y,0,y-(by2-cR));
      ins=(lx*lx+ly*ly)<=cR*cR;if(x>=bx1+cR&&x<=bx2-cR)ins=true;if(y>=by1+cR&&y<=by2-cR)ins=true;
    }
    const tC=cx+bW*0.1,tT=by2,tB=by2+h*0.1,tW=bW*0.15;
    if(y>=tT&&y<=tB){const f=(y-tT)/(tB-tT),tw=tW*(1-f);if(x>=tC-tw/2&&x<=tC+tw/2)ins=true;}
    if(ins){px[i]=255;px[i+1]=255;px[i+2]=255;px[i+3]=255;}
  }
  const raw=Buffer.alloc(h*(1+w*4));
  for(let y=0;y<h;y++){raw[y*(1+w*4)]=0;px.copy(raw,y*(1+w*4)+1,y*w*4,(y+1)*w*4);}
  const comp=zlib.deflateSync(raw,{level:9});
  function crc32(buf){let c=0xFFFFFFFF;for(let i=0;i<buf.length;i++){c^=buf[i];for(let j=0;j<8;j++)c=(c>>>1)^(c&1?0xEDB88320:0);}return(c^0xFFFFFFFF)>>>0;}
  function chunk(t,d){const l=Buffer.alloc(4);l.writeUInt32BE(d.length);const td=Buffer.concat([Buffer.from(t),d]);const cr=Buffer.alloc(4);cr.writeUInt32BE(crc32(td));return Buffer.concat([l,td,cr]);}
  const sig=Buffer.from([137,80,78,71,13,10,26,10]),ihdr=Buffer.alloc(13);
  ihdr.writeUInt32BE(w,0);ihdr.writeUInt32BE(h,4);ihdr[8]=8;ihdr[9]=6;
  return Buffer.concat([sig,chunk("IHDR",ihdr),chunk("IDAT",comp),chunk("IEND",Buffer.alloc(0))]);
}
for(const s of[192,512]){const p=createPNG(s,s,102,126,234);fs.writeFileSync("public/images/icon-"+s+".png",p);fs.writeFileSync("public/images/icon-maskable-"+s+".png",p);}
fs.writeFileSync("public/images/icon-96.png",createPNG(96,96,102,126,234));
console.log("✅ PWA 图标已生成");
' 2>/dev/null || echo -e "${YELLOW}PNG 图标生成失败，将使用 SVG 回退${NC}"

    # ===== Service Worker =====
    cat > "$APP_DIR/public/sw.js" <<'SWEOF'
var CACHE_NAME = "teamchat-v9";
var OFFLINE_URLS = ["/", "/index.html", "/images/icon-192.png", "/images/icon-96.png", "/images/default-avatar.svg"];
self.addEventListener("install", function(e) { e.waitUntil(caches.open(CACHE_NAME).then(function(c) { return c.addAll(OFFLINE_URLS); }).then(function() { return self.skipWaiting(); })); });
self.addEventListener("activate", function(e) { e.waitUntil(caches.keys().then(function(n) { return Promise.all(n.filter(function(k) { return k !== CACHE_NAME; }).map(function(k) { return caches.delete(k); })); }).then(function() { return self.clients.claim(); })); });
self.addEventListener("fetch", function(e) {
  var r = e.request; if (r.method !== "GET") return;
  if (r.url.indexOf("/api/") !== -1 || r.url.indexOf("/socket.io/") !== -1) return;
  if (!r.url.startsWith("http")) return;
  e.respondWith(fetch(r).then(function(res) { if (res && res.status === 200 && res.type === "basic") { var cl = res.clone(); caches.open(CACHE_NAME).then(function(c) { c.put(r, cl); }); } return res; }).catch(function() { return caches.match(r).then(function(c) { if (c) return c; if (r.mode === "navigate") return caches.match("/index.html"); return new Response("Offline", { status: 503 }); }); }));
});
self.addEventListener("push", function(e) {
  var d = { title: "TeamChat", body: "您有新消息", icon: "/images/icon-192.png", badge: "/images/icon-96.png" };
  try { if (e.data) { var p = e.data.json(); d.title = p.title || d.title; d.body = p.body || d.body; if (p.icon) d.icon = p.icon; d.data = p.data || {}; } } catch(err) { if (e.data) d.body = e.data.text(); }
  e.waitUntil(self.registration.showNotification(d.title, { body: d.body, icon: d.icon, badge: d.badge, vibrate: [200, 100, 200], data: d.data || {}, tag: "teamchat-" + Date.now(), renotify: true }));
});
self.addEventListener("notificationclick", function(e) { e.notification.close(); var u = (e.notification.data && e.notification.data.url) ? e.notification.data.url : "/"; e.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then(function(cl) { for (var i = 0; i < cl.length; i++) { if (cl[i].url.indexOf(self.location.origin) !== -1 && "focus" in cl[i]) return cl[i].focus(); } if (self.clients.openWindow) return self.clients.openWindow(u); })); });
self.addEventListener("pushsubscriptionchange", function(e) { e.waitUntil(self.registration.pushManager.subscribe(e.oldSubscription.options).then(function(s) { return fetch("/api/push/renew", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ subscription: s.toJSON(), oldEndpoint: e.oldSubscription ? e.oldSubscription.endpoint : null }) }); })); });
SWEOF


    # ===== Vue 3 SPA: index.html (单入口) =====
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
  <title>团队聊天室</title>
  <style>
*{margin:0;padding:0;box-sizing:border-box}
html{touch-action:manipulation;-webkit-text-size-adjust:100%}
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;background:#f0f2f5;height:100dvh;overflow:hidden}
#app{height:100dvh;display:flex;flex-direction:column}
.hidden{display:none!important}

/* ===== Login ===== */
.login-page{width:100%;height:100dvh;display:flex;justify-content:center;align-items:center;background:linear-gradient(135deg,#667eea 0%,#764ba2 100%);position:relative;overflow:hidden}
.login-card{background:#fff;padding:40px;border-radius:16px;box-shadow:0 10px 40px rgba(0,0,0,.2);width:90%;max-width:400px;position:relative;z-index:1}
.login-card h1{text-align:center;margin-bottom:30px;color:#333}
.login-card input{width:100%;padding:14px;margin-bottom:16px;border:1px solid #ddd;border-radius:8px;font-size:16px}
.login-card button{width:100%;padding:14px;background:#667eea;color:#fff;border:none;border-radius:8px;font-size:16px;cursor:pointer;margin-bottom:10px}
.login-card button:hover{background:#5a6fd6}
.error{color:#dc2626;text-align:center;margin-top:10px;font-size:14px}
.reg-toggle{text-align:center;margin-top:12px;font-size:14px}
.reg-toggle a{color:#667eea;text-decoration:none}

/* ===== App Layout (三栏) ===== */
.app-layout{display:flex;height:100dvh;overflow:hidden}

/* Sidebar - 频道列表 */
.sidebar{width:260px;background:#1e1f2e;color:#fff;display:flex;flex-direction:column;flex-shrink:0;transition:transform .3s ease;z-index:100}
.sidebar-header{padding:16px;border-bottom:1px solid rgba(255,255,255,.1);display:flex;justify-content:space-between;align-items:center}
.sidebar-header h2{font-size:16px;font-weight:600}
.sidebar-header .btn-icon{background:none;border:none;color:rgba(255,255,255,.6);font-size:18px;cursor:pointer;padding:4px 8px;border-radius:6px}
.sidebar-header .btn-icon:hover{background:rgba(255,255,255,.1);color:#fff}
.channel-list{flex:1;overflow-y:auto;padding:8px}
.channel-item{padding:10px 12px;border-radius:8px;cursor:pointer;display:flex;align-items:center;gap:10px;margin-bottom:2px;transition:background .15s;position:relative}
.channel-item:hover{background:rgba(255,255,255,.08)}
.channel-item.active{background:rgba(102,126,234,.3)}
.channel-item .ch-icon{font-size:18px;opacity:.7;flex-shrink:0}
.channel-item .ch-name{flex:1;font-size:14px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.channel-item .ch-badge{background:#dc2626;color:#fff;font-size:11px;min-width:18px;height:18px;border-radius:9px;display:flex;align-items:center;justify-content:center;padding:0 5px;font-weight:600}
.sidebar-footer{padding:12px 16px;border-top:1px solid rgba(255,255,255,.1);display:flex;align-items:center;gap:10px}
.sidebar-footer img{width:32px;height:32px;border-radius:50%;object-fit:cover}
.sidebar-footer .user-name{flex:1;font-size:13px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.sidebar-footer .btn-icon{background:none;border:none;color:rgba(255,255,255,.5);font-size:16px;cursor:pointer;padding:4px;border-radius:4px}
.sidebar-footer .btn-icon:hover{color:#fff}

/* Main Chat Area */
.main-area{flex:1;display:flex;flex-direction:column;min-width:0;background:#f0f2f5}
.chat-header{background:#fff;padding:12px 16px;display:flex;justify-content:space-between;align-items:center;box-shadow:0 1px 4px rgba(0,0,0,.06);flex-shrink:0;z-index:10}
.chat-header-left{display:flex;align-items:center;gap:10px;min-width:0}
.chat-header-left .menu-btn{display:none;background:none;border:none;font-size:22px;cursor:pointer;padding:4px;color:#333}
.chat-header-left h3{font-size:16px;color:#333;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.chat-header-left .ch-desc{font-size:12px;color:#999;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.chat-header-right{display:flex;align-items:center;gap:6px}
.chat-header-right .online-tag{font-size:12px;color:#667eea;background:rgba(102,126,234,.1);padding:2px 8px;border-radius:10px;white-space:nowrap}
.chat-header-right .btn-icon{background:none;border:none;font-size:18px;cursor:pointer;padding:4px;border-radius:4px;color:#666}
.chat-header-right .btn-icon:hover{background:#f0f0f0;color:#333}

/* Notice bar */
.notice-bar{flex-shrink:0;background:linear-gradient(135deg,#fff8e1 0%,#fff3c4 100%);border-bottom:1px solid #f0d060;padding:10px 16px;display:flex;align-items:center;gap:8px;cursor:pointer}
.notice-bar .notice-icon{font-size:16px;flex-shrink:0}
.notice-bar .notice-text{flex:1;font-size:13px;color:#8b6914;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-weight:500}
.notice-expanded{padding:8px 16px 12px 40px;font-size:14px;color:#5d4e14;line-height:1.7;white-space:pre-wrap;word-break:break-word;max-height:200px;overflow-y:auto;background:rgba(255,248,225,.6)}

/* Messages */
.messages-wrapper{flex:1;min-height:0;overflow:hidden;display:flex;flex-direction:column;position:relative}
.messages{flex:1;overflow-y:auto;padding:16px;display:flex;flex-direction:column;gap:8px;position:relative;z-index:1}
.load-more{text-align:center;padding:10px;color:#667eea;cursor:pointer;background:rgba(255,255,255,.85);border-radius:8px;margin-bottom:8px;font-size:13px}
.msg{display:flex;gap:10px;align-items:flex-start;max-width:80%;padding:2px 0}
.msg.my{align-self:flex-end;flex-direction:row-reverse}
.msg-avatar{width:36px;height:36px;border-radius:50%;object-fit:cover;flex-shrink:0;cursor:pointer}
.msg-body{min-width:0}
.msg-sender{font-size:12px;font-weight:600;color:#667eea;margin-bottom:2px}
.msg.my .msg-sender{text-align:right;color:rgba(255,255,255,.8)}
.msg-bubble{padding:10px 14px;border-radius:16px;word-wrap:break-word;line-height:1.5;position:relative}
.msg.other .msg-bubble{background:#fff;color:#333;border-bottom-left-radius:4px;box-shadow:0 1px 2px rgba(0,0,0,.06)}
.msg.my .msg-bubble{background:#667eea;color:#fff;border-bottom-right-radius:4px}
.msg-time{font-size:10px;opacity:.5;text-align:right;margin-top:4px}
.msg-bubble img.chat-image{max-width:240px;max-height:240px;border-radius:8px;cursor:pointer;display:block;margin-top:6px}
.msg-bubble .file-card{display:flex;align-items:center;gap:8px;padding:8px 12px;background:rgba(0,0,0,.05);border-radius:8px;margin-top:6px;cursor:pointer;font-size:13px}
.msg-bubble .reply-ref{background:rgba(0,0,0,.06);padding:4px 8px;border-radius:6px;margin-bottom:6px;font-size:12px;border-left:2px solid #667eea;color:#666;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.msg.my .msg-bubble .reply-ref{border-left-color:rgba(255,255,255,.5);color:rgba(255,255,255,.7);background:rgba(255,255,255,.15)}
.msg-content{white-space:pre-wrap;word-break:break-word}
.msg-content a{color:inherit;text-decoration:underline}

/* Chain card */
.chain-card{background:linear-gradient(135deg,#f0f4ff 0%,#e8eeff 100%);border:1px solid #c7d2fe;border-radius:12px;padding:12px;margin-top:4px}
.msg.my .chain-card{background:linear-gradient(135deg,rgba(255,255,255,.2) 0%,rgba(255,255,255,.1) 100%);border-color:rgba(255,255,255,.3)}
.chain-header{display:flex;align-items:center;gap:6px;font-size:13px;font-weight:700;color:#4f46e5;margin-bottom:6px}
.msg.my .chain-header{color:rgba(255,255,255,.9)}
.chain-topic{font-size:15px;font-weight:600;color:#1e1b4b;margin-bottom:4px}
.msg.my .chain-topic{color:#fff}
.chain-desc{font-size:13px;color:#555;margin-bottom:8px;line-height:1.4}
.msg.my .chain-desc{color:rgba(255,255,255,.8)}
.chain-list{font-size:14px;line-height:1.8;color:#333}
.msg.my .chain-list{color:rgba(255,255,255,.95)}
.chain-seq{display:inline-block;min-width:22px;height:22px;line-height:22px;text-align:center;background:#667eea;color:#fff;border-radius:50%;font-size:11px;font-weight:700;margin-right:6px;vertical-align:middle}
.msg.my .chain-seq{background:rgba(255,255,255,.3)}
.chain-name{font-weight:600;color:#4338ca}
.msg.my .chain-name{color:rgba(255,255,255,.95)}
.chain-join-btn{display:inline-flex;align-items:center;gap:4px;margin-top:10px;padding:6px 14px;background:#667eea;color:#fff;border:none;border-radius:20px;font-size:13px;font-weight:600;cursor:pointer}
.chain-join-btn:hover{background:#5567d8}
.chain-join-btn.joined{background:#10b981;cursor:default}
.msg.my .chain-join-btn{background:rgba(255,255,255,.25)}

/* Input area */
.reply-bar{background:#f0f2ff;padding:8px 16px;display:flex;align-items:center;gap:8px;font-size:13px;color:#555;border-left:3px solid #667eea;flex-shrink:0}
.reply-bar .reply-text{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.reply-bar button{background:none;border:none;font-size:16px;cursor:pointer;color:#999;padding:0 4px}
.input-area{background:#fff;padding:12px 16px;display:flex;gap:8px;align-items:flex-end;box-shadow:0 -1px 4px rgba(0,0,0,.04);flex-shrink:0}
.input-area .attach-btn,.input-area .chain-btn{width:40px;height:40px;border-radius:20px;border:none;background:#f0f0f0;font-size:18px;cursor:pointer;display:flex;align-items:center;justify-content:center;flex-shrink:0}
.input-area .attach-btn:hover,.input-area .chain-btn:hover{background:#e0e4f8}
.input-area textarea{flex:1;min-height:24px;max-height:120px;padding:10px 14px;border:1px solid #ddd;border-radius:16px;font-size:15px;outline:none;resize:none;line-height:1.5;font-family:inherit;background:#fff}
.input-area textarea:focus{border-color:#667eea;box-shadow:0 0 0 2px rgba(102,126,234,.12)}
.input-area .send-btn{height:40px;min-width:40px;padding:0 16px;border-radius:20px;border:none;background:#667eea;color:#fff;font-size:14px;font-weight:500;cursor:pointer;flex-shrink:0;white-space:nowrap}
.input-area .send-btn:hover{background:#5a6fd6}
.input-area .newline-btn{width:40px;height:40px;border-radius:20px;border:none;background:#f0f0f0;font-size:16px;cursor:pointer;display:none;align-items:center;justify-content:center;flex-shrink:0;color:#666}

/* Right panel - members */
.members-panel{width:240px;background:#fff;border-left:1px solid #e5e7eb;display:flex;flex-direction:column;flex-shrink:0}
.members-panel-header{padding:14px 16px;border-bottom:1px solid #e5e7eb;font-size:14px;font-weight:600;color:#333}
.members-list{flex:1;overflow-y:auto;padding:8px 12px}
.member-item{display:flex;align-items:center;gap:8px;padding:8px 6px;border-radius:6px}
.member-item:hover{background:#f8f9fa}
.member-item img{width:28px;height:28px;border-radius:50%;object-fit:cover}
.member-item .member-name{font-size:13px;color:#333;flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.member-item .member-role{font-size:11px;color:#999;background:#f0f0f0;padding:1px 6px;border-radius:4px}
.member-item .online-dot{width:8px;height:8px;border-radius:50%;background:#ccc;flex-shrink:0}
.member-item .online-dot.on{background:#22c55e}

/* Modals */
.modal-overlay{position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,.5);display:flex;justify-content:center;align-items:center;z-index:1000}
.modal{background:#fff;padding:24px;border-radius:16px;width:92%;max-width:480px;max-height:85vh;overflow-y:auto}
.modal h3{margin-bottom:20px;text-align:center}
.modal h4{margin:16px 0 10px;font-size:14px;color:#666}
.modal input[type="text"],.modal input[type="password"],.modal input[type="date"],.modal select{width:100%;padding:12px;margin-bottom:10px;border:1px solid #ddd;border-radius:8px;font-size:16px}
.modal textarea{width:100%;padding:12px;border:1px solid #ddd;border-radius:8px;font-size:14px;resize:vertical;font-family:inherit}
.modal button{width:100%;padding:12px;background:#667eea;color:#fff;border:none;border-radius:8px;font-size:14px;cursor:pointer;margin-bottom:8px}
.modal button:hover{opacity:.9}
.modal button.danger{background:#dc2626}
.modal button.secondary{background:#f0f0f0;color:#333}
.modal button.success{background:#10b981}
.modal .close-btn{background:#f0f0f0!important;color:#333!important}
.section{margin-bottom:20px;padding-bottom:16px;border-bottom:1px solid #eee}
.field-label{display:block;font-size:13px;color:#555;margin-bottom:6px;font-weight:500}
.color-row{display:flex;align-items:center;gap:12px;margin-bottom:10px}
.color-row input[type="color"]{width:50px;height:36px;border:1px solid #ddd;border-radius:6px;padding:2px;cursor:pointer}
.radio-group{display:flex;gap:16px;margin-bottom:10px;flex-wrap:wrap}
.radio-group label{display:flex;align-items:center;gap:6px;font-size:14px;cursor:pointer}
.avatar-upload{display:flex;flex-direction:column;align-items:center;gap:10px}
.avatar-preview{width:80px;height:80px;border-radius:50%;object-fit:cover;border:2px solid #ddd}
.user-list{max-height:200px;overflow-y:auto}
.user-item{display:flex;justify-content:space-between;align-items:center;padding:10px;background:#f9f9f9;border-radius:8px;margin-bottom:6px}
.user-item .username{font-weight:600;font-size:14px}
.user-item .nickname{font-size:12px;color:#666}
.user-item button{width:auto;padding:6px 12px;font-size:12px;margin:0 0 0 6px}
.msg-menu{position:fixed;background:#fff;border-radius:8px;box-shadow:0 4px 16px rgba(0,0,0,.15);z-index:2000;overflow:hidden;min-width:140px}
.msg-menu .menu-item{padding:10px 16px;cursor:pointer;font-size:14px;transition:background .15s}
.msg-menu .menu-item:hover{background:#f0f2ff}
.kicked-overlay{position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,.7);display:flex;justify-content:center;align-items:center;z-index:9999}
.kicked-card{background:#fff;padding:32px;border-radius:16px;text-align:center;max-width:360px;width:90%}
.kicked-card h3{margin-bottom:12px;color:#dc2626}
.kicked-card p{margin-bottom:20px;color:#666;font-size:14px}

/* Channel management */
.ch-mgmt-item{display:flex;align-items:center;gap:8px;padding:10px;background:#f9f9f9;border-radius:8px;margin-bottom:6px}
.ch-mgmt-item .ch-info{flex:1;min-width:0}
.ch-mgmt-item .ch-info .ch-name{font-weight:600;font-size:14px}
.ch-mgmt-item .ch-info .ch-meta{font-size:12px;color:#999}
.ch-perm-grid{display:grid;gap:6px;margin:10px 0}
.ch-perm-row{display:flex;align-items:center;gap:8px;padding:6px 8px;background:#f9f9f9;border-radius:6px}
.ch-perm-row .perm-user{flex:1;font-size:13px}
.ch-perm-row select{padding:4px 8px;border:1px solid #ddd;border-radius:4px;font-size:12px}

/* Image preview */
.image-modal{position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,.85);display:flex;justify-content:center;align-items:center;z-index:2000;cursor:zoom-out}
.image-modal img{max-width:90vw;max-height:90vh;border-radius:8px}

/* Sidebar overlay (mobile) */
.sidebar-overlay{display:none;position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,.4);z-index:99}

/* ===== Responsive ===== */
@media(max-width:1024px){
  .members-panel{display:none}
}
@media(max-width:768px){
  .sidebar{position:fixed;top:0;left:0;height:100%;transform:translateX(-100%)}
  .sidebar.open{transform:translateX(0)}
  .sidebar-overlay.show{display:block}
  .chat-header-left .menu-btn{display:block}
  .msg{max-width:88%}
  .newline-btn{display:flex!important}
  .input-area .send-btn{padding:0 12px}
}
@media(min-width:768px){
  .msg-bubble img.chat-image{max-width:300px;max-height:300px}
}
  </style>
</head>
<body>
<div id="app"></div>
<script src="https://cdn.socket.io/4.7.2/socket.io.min.js"></script>
<script src="/app.js?v=20260414"></script>
</body>
</html>
HTMLEOF


    # ===== app.js — Vue 3 SPA (CDN, 无构建步骤) =====
    cat > "$APP_DIR/public/app.js" <<'APPEOF'
/* TeamChat v9 — Vue 3 SPA with multi-channel support */
const{createApp,ref,reactive,computed,watch,onMounted,onUnmounted,nextTick,h}=Vue;

/* ===== Utilities ===== */
const API='';
function esc(t){const d=document.createElement('div');d.appendChild(document.createTextNode(t));return d.innerHTML}
function escAttr(t){return String(t).replace(/&/g,'&amp;').replace(/"/g,'&quot;').replace(/'/g,'&#39;').replace(/</g,'&lt;').replace(/>/g,'&gt;')}
function authH(extra){const h={'Authorization':'Bearer '+(store.token||'')};return Object.assign(h,extra||{})}
function parseUTC(ts){if(!ts)return new Date();if(ts.endsWith('Z')||/[+-]\d{2}:\d{2}$/.test(ts))return new Date(ts);return new Date(ts.replace(' ','T')+'Z')}
function fmtTime(ts){return parseUTC(ts).toLocaleString('zh-CN',{timeZone:store.timezone,year:'numeric',month:'long',day:'numeric',hour:'2-digit',minute:'2-digit',second:'2-digit'})}
function fmtSize(b){if(!b)return'0 B';if(b<1024)return b+' B';if(b<1048576)return(b/1024).toFixed(1)+' KB';return(b/1048576).toFixed(1)+' MB'}
function avatarUrl(a){return a?API+'/avatars/'+encodeURIComponent(a):'/images/default-avatar.svg'}
function sanitize(html){
  if(!html)return'';
  if(!/<[a-zA-Z]/.test(html)){const s=esc(html);return s.replace(/(https?:\/\/[^\s&lt;]+)/g,'<a href="$1" target="_blank" rel="noopener">$1</a>')}
  const t=document.createElement('div');t.innerHTML=html;
  t.querySelectorAll('script,style,link,meta,iframe,object,embed').forEach(e=>e.remove());
  const ok={B:1,STRONG:1,I:1,EM:1,U:1,S:1,STRIKE:1,SPAN:1,FONT:1,BR:1,A:1};
  const okA={style:1,color:1,href:1,target:1,rel:1};
  (function w(n){[...n.childNodes].forEach(c=>{if(c.nodeType===1){if(!ok[c.tagName]){while(c.firstChild)c.parentNode.insertBefore(c.firstChild,c);c.remove()}else{[...c.attributes].forEach(a=>{if(!okA[a.name])c.removeAttribute(a.name)});if(c.tagName==='A'){c.setAttribute('target','_blank');c.setAttribute('rel','noopener')}w(c)}}});})(t);
  const tw=document.createTreeWalker(t,NodeFilter.SHOW_TEXT,null,false);const tn=[];while(tw.nextNode())tn.push(tw.currentNode);
  tn.forEach(n=>{if(n.parentNode&&n.parentNode.tagName==='A')return;const re=/(https?:\/\/[^\s<]+)/g;if(re.test(n.textContent)){const f=document.createDocumentFragment();let li=0;n.textContent.replace(re,(m,_,o)=>{if(o>li)f.appendChild(document.createTextNode(n.textContent.slice(li,o)));const a=document.createElement('a');a.href=m;a.target='_blank';a.rel='noopener';a.textContent=m;f.appendChild(a);li=o+m.length;});if(li<n.textContent.length)f.appendChild(document.createTextNode(n.textContent.slice(li)));n.parentNode.replaceChild(f,n);}});
  return t.innerHTML;
}

/* ===== Global reactive store ===== */
const store=reactive({
  token:localStorage.getItem('token')||'',
  username:localStorage.getItem('username')||'',
  userId:parseInt(localStorage.getItem('userId'))||0,
  isAdmin:localStorage.getItem('isAdmin')==='true',
  nickname:localStorage.getItem('nickname')||'',
  avatar:localStorage.getItem('avatar')||'',
  timezone:'Asia/Shanghai',
  appearance:{},
  regOpen:false,
  channels:[],
  currentChannelId:parseInt(localStorage.getItem('currentChannelId'))||0,
  onlineUsers:[],
  notice:{content:'',enabled:false},
});
function saveAuth(d){
  store.token=d.token;store.username=d.username;store.userId=d.userId;
  store.isAdmin=d.isAdmin;store.nickname=d.nickname||'';store.avatar=d.avatar||'';
  for(const k of['token','username','userId','isAdmin','nickname','avatar'])localStorage.setItem(k,store[k]);
}
function clearAuth(){for(const k of['token','username','userId','isAdmin','nickname','avatar','currentChannelId'])localStorage.removeItem(k);Object.assign(store,{token:'',username:'',userId:0,isAdmin:false,nickname:'',avatar:'',channels:[],currentChannelId:0});}

/* ===== Socket ===== */
let socket=null;
function initSocket(){
  if(socket){socket.disconnect();socket=null}
  socket=io({auth:{token:store.token}});
  socket.on('connect_error',e=>{if(e.message==='认证失败'||e.message==='未提供认证信息'){alert('登录已过期');clearAuth()}});
  socket.on('newMessage',msg=>{
    if(!msgStore[msg.channel_id])msgStore[msg.channel_id]={msgs:[],oldest:null,allLoaded:false};
    const ch=msgStore[msg.channel_id];
    if(!ch.msgs.find(m=>m.id===msg.id)){ch.msgs.push(msg);if(msg.channel_id===store.currentChannelId)nextTick(()=>scrollBottom())}
    if(msg.channel_id!==store.currentChannelId&&msg.username!==store.username){
      const c=store.channels.find(c=>c.id===msg.channel_id);if(c)c._unread=(c._unread||0)+1;
    }
  });
  socket.on('onlineUsers',users=>{store.onlineUsers=users});
  socket.on('kicked',d=>{showKicked(d.message||'您的账号已在其他设备登录')});
  socket.on('timezoneChanged',d=>{if(d.timezone)store.timezone=d.timezone});
  socket.on('appearanceChanged',d=>{store.appearance=d;applyAppearance(d)});
  socket.on('registrationChanged',d=>{store.regOpen=d.open});
  socket.on('noticeChanged',d=>{store.notice=d});
  socket.on('chainUpdated',data=>{
    const ch=msgStore[data.channelId||store.currentChannelId];
    if(!ch)return;const m=ch.msgs.find(m=>m.id===data.messageId);if(m)m.content=data.content;
  });
  socket.on('channelCreated',ch=>{if(!store.channels.find(c=>c.id===ch.id))store.channels.push({...ch,_unread:0})});
  socket.on('channelDeleted',d=>{store.channels=store.channels.filter(c=>c.id!==d.channelId);if(store.currentChannelId===d.channelId&&store.channels.length)switchChannel(store.channels[0].id)});
  socket.on('channelUpdated',d=>{const c=store.channels.find(c=>c.id===d.id);if(c)Object.assign(c,d)});
  socket.on('membershipChanged',async()=>{await loadChannels()});
}

/* ===== Message store (per channel) ===== */
const msgStore={};
async function loadMessages(channelId,before){
  if(!channelId)return;
  if(!msgStore[channelId])msgStore[channelId]={msgs:[],oldest:null,allLoaded:false};
  const ch=msgStore[channelId];if(ch.allLoaded&&before)return;
  let url=API+'/api/messages?channelId='+channelId+'&limit=50';
  if(before&&ch.oldest)url+='&before='+ch.oldest;
  try{
    const r=await fetch(url,{headers:authH()});if(r.status===401){clearAuth();return}
    if(r.status===403)return;
    const msgs=await r.json();
    if(msgs.length<50)ch.allLoaded=true;
    if(msgs.length){
      if(before){ch.msgs.unshift(...msgs)}else{ch.msgs.push(...msgs)}
      ch.oldest=ch.msgs[0].id;
    }
  }catch(e){console.error('loadMessages:',e)}
}
function scrollBottom(){const el=document.querySelector('.messages');if(el)el.scrollTop=el.scrollHeight}

/* ===== Channel operations ===== */
async function loadChannels(){
  try{const r=await fetch(API+'/api/channels',{headers:authH()});if(r.ok){const chs=await r.json();store.channels=chs.map(c=>({...c,_unread:0}))}}catch(e){}
}
async function switchChannel(id){
  store.currentChannelId=id;localStorage.setItem('currentChannelId',id);
  const c=store.channels.find(c=>c.id===id);if(c)c._unread=0;
  if(!msgStore[id]||!msgStore[id].msgs.length)await loadMessages(id);
  if(socket)socket.emit('switchChannel',{channelId:id});
  nextTick(()=>scrollBottom());
}

/* ===== Appearance ===== */
async function loadAppearance(){try{const r=await fetch(API+'/api/settings/appearance');if(r.ok){const d=await r.json();store.appearance=d;applyAppearance(d)}}catch(e){}}
function applyAppearance(d){
  if(!d)return;
  if(d.timezone)store.timezone=d.timezone;
  const sb=document.querySelector('.input-area .send-btn');
  if(sb){if(d.send_text)sb.textContent=d.send_text;if(d.send_color)sb.style.background=d.send_color}
  const ml=document.querySelector('.messages');
  if(ml){
    if(d.bg_type==='image'&&d.bg_image){ml.style.backgroundImage='url('+API+'/backgrounds/'+encodeURIComponent(d.bg_image)+')';ml.style.backgroundSize=d.bg_mode==='tile'?'auto':'cover';ml.style.backgroundPosition='center';ml.style.backgroundRepeat=d.bg_mode==='tile'?'repeat':'no-repeat';ml.style.backgroundColor=d.bg_color||'#f0f2f5'}
    else{ml.style.backgroundImage='none';ml.style.backgroundColor=d.bg_color||'#f0f2f5'}
  }
  const lp=document.querySelector('.login-page');
  if(lp){
    const lbt=d.login_bg_type||'gradient';
    if(lbt==='color')lp.style.background=d.login_bg_color1||'#667eea';
    else if(lbt==='image'&&d.login_bg_image){lp.style.background='url('+API+'/backgrounds/'+encodeURIComponent(d.login_bg_image)+') center/cover no-repeat'}
    else lp.style.background='linear-gradient(135deg,'+(d.login_bg_color1||'#667eea')+' 0%,'+(d.login_bg_color2||'#764ba2')+' 100%)';
  }
}

/* ===== Push notifications ===== */
let swReg=null,pushSub=null;
async function initSW(){if(!('serviceWorker' in navigator))return;try{swReg=await navigator.serviceWorker.register('/sw.js',{updateViaCache:'none'});swReg.update().catch(()=>{});if(!swReg.active)swReg=await navigator.serviceWorker.ready}catch(e){}}
async function checkPush(){
  if(!swReg||!('PushManager' in window))return{supported:false,subscribed:false,reason:'不支持推送'};
  if('Notification' in window&&Notification.permission==='denied')return{supported:true,subscribed:false,reason:'通知权限已拒绝'};
  try{const sub=await swReg.pushManager.getSubscription();if(sub){pushSub=sub;if(store.token)fetch(API+'/api/push/subscribe',{method:'POST',headers:authH({'Content-Type':'application/json'}),body:JSON.stringify({subscription:sub.toJSON()})}).catch(()=>{});return{supported:true,subscribed:true}}return{supported:true,subscribed:false}}catch(e){return{supported:false,subscribed:false,reason:e.message}}
}
async function togglePush(){
  if(pushSub){const ep=pushSub.endpoint;await pushSub.unsubscribe();fetch(API+'/api/push/unsubscribe',{method:'POST',headers:authH({'Content-Type':'application/json'}),body:JSON.stringify({endpoint:ep})}).catch(()=>{});pushSub=null;return false}
  const kr=await fetch(API+'/api/push/vapid-key');const kd=await kr.json();if(!kd.publicKey){alert('服务器推送未配置');return false}
  const perm=await Notification.requestPermission();if(perm!=='granted')return false;
  if(!swReg)await initSW();const reg=await navigator.serviceWorker.ready;
  const sub=await reg.pushManager.subscribe({userVisibleOnly:true,applicationServerKey:Uint8Array.from(atob(kd.publicKey.replace(/-/g,'+').replace(/_/g,'/') + '='.repeat((4-kd.publicKey.length%4)%4)),c=>c.charCodeAt(0))});
  await fetch(API+'/api/push/subscribe',{method:'POST',headers:authH({'Content-Type':'application/json'}),body:JSON.stringify({subscription:sub.toJSON()})});
  pushSub=sub;return true;
}

/* ===== Kicked overlay ===== */
function showKicked(msg){if(socket){socket.disconnect();socket=null}const o=document.createElement('div');o.className='kicked-overlay';o.innerHTML='<div class="kicked-card"><h3>⚠️ 账号已下线</h3><p>'+esc(msg)+'</p><button onclick="this.closest(\'.kicked-overlay\').remove();clearAuth();appInstance.page=\'login\'">重新登录</button></div>';document.body.appendChild(o)}

/* ===== Vue App ===== */
let appInstance=null;
const App={
  setup(){
    const page=ref(store.token?'chat':'login');
    const loginErr=ref('');
    const showReg=ref(false);
    const sidebarOpen=ref(false);
    const showMembers=ref(true);
    const currentModal=ref('');/* settings|userMgmt|channelMgmt|channelPerm|appearance|backup|deleteMsg|notice|chainNew|imagePreview */
    const modalData=ref({});
    const replyTo=ref(null);
    const noticeExpanded=ref(false);
    const msgInput=ref('');
    const msgListKey=ref(0);/* force re-render */

    const currentChannel=computed(()=>store.channels.find(c=>c.id===store.currentChannelId)||null);
    const currentMessages=computed(()=>{const ch=msgStore[store.currentChannelId];return ch?ch.msgs:[]});
    const onlineSet=computed(()=>new Set(store.onlineUsers.map(u=>u.username)));
    const channelMembers=computed(()=>{
      const mems=modalData.value._channelMembers||[];
      return store.onlineUsers.map(u=>({...u,isOnline:true,role:mems.find(m=>m.username===u.username)?.role||'member'}));
    });

    /* Init */
    onMounted(async()=>{
      await initSW();await loadAppearance();
      try{const r=await fetch(API+'/api/settings/notice');if(r.ok){const d=await r.json();store.notice=d}}catch(e){}
      try{const r=await fetch(API+'/api/settings/registration');if(r.ok){const d=await r.json();store.regOpen=d.open}}catch(e){}
      if(store.token){await enterChat()}
      appInstance={page};
    });

    async function enterChat(){
      page.value='chat';initSocket();await loadChannels();
      if(!store.currentChannelId&&store.channels.length)store.currentChannelId=store.channels[0].id;
      if(store.currentChannelId)await switchChannel(store.currentChannelId);
    }

    /* Auth */
    async function doLogin(u,p){
      loginErr.value='';
      try{const r=await fetch(API+'/api/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username:u,password:p})});const d=await r.json();if(d.success){saveAuth(d);await enterChat()}else loginErr.value=d.message||'登录失败'}catch(e){loginErr.value='登录失败'}
    }
    async function doRegister(u,p,p2,n){
      loginErr.value='';if(p!==p2)return loginErr.value='两次密码不一致';if(p.length<6)return loginErr.value='密码至少6位';
      try{const r=await fetch(API+'/api/public-register',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username:u,password:p,nickname:n||u})});const d=await r.json();if(d.success){loginErr.value='✅ 注册成功，请登录';showReg.value=false}else loginErr.value=d.message||'注册失败'}catch(e){loginErr.value='注册失败'}
    }
    function logout(){if(socket){socket.disconnect();socket=null}clearAuth();page.value='login'}

    /* Send message */
    function sendMsg(){
      const text=msgInput.value.trim();if(!text||!socket)return;
      const d={content:esc(text),channelId:store.currentChannelId};if(replyTo.value)d.replyTo=replyTo.value.id;
      socket.emit('sendMessage',d);replyTo.value=null;msgInput.value='';
      const ta=document.querySelector('.input-area textarea');if(ta){ta.style.height='auto'}
    }
    function handleKey(e){if(e.key==='Enter'&&!e.shiftKey){e.preventDefault();sendMsg()}}
    function insertNewline(){const ta=document.querySelector('.input-area textarea');if(!ta)return;const s=ta.selectionStart,e=ta.selectionEnd;msgInput.value=msgInput.value.substring(0,s)+'\n'+msgInput.value.substring(e);nextTick(()=>{ta.selectionStart=ta.selectionEnd=s+1;ta.style.height='auto';ta.style.height=Math.min(ta.scrollHeight,120)+'px';ta.focus()})}
    function autoGrow(e){e.target.style.height='auto';e.target.style.height=Math.min(e.target.scrollHeight,120)+'px'}

    /* File upload */
    async function uploadFile(file){
      if(!file)return;const fd=new FormData();fd.append('file',file);fd.append('channelId',store.currentChannelId);
      try{const r=await fetch(API+'/api/upload',{method:'POST',headers:{'Authorization':'Bearer '+store.token},body:fd});const d=await r.json();if(!d.success)alert(d.message||'上传失败')}catch(e){alert('上传失败')}
    }

    /* Chain */
    function sendChain(topic,desc){
      if(!topic||!socket)return;
      const myName=store.nickname||store.username;
      const chainData={type:'chain',topic,desc,participants:[{seq:1,username:store.username,name:myName,text:''}]};
      socket.emit('sendMessage',{content:'[CHAIN]'+JSON.stringify(chainData),channelId:store.currentChannelId});
      currentModal.value='';
    }
    function joinChain(msg){
      if(!socket)return;
      const cd=parseChain(msg.content);if(!cd)return;
      if(cd.participants.some(p=>p.username===store.username)){alert('你已参与此接龙');return}
      socket.emit('updateChain',{messageId:msg.id,content:'[CHAIN]'+JSON.stringify(cd),channelId:msg.channel_id||store.currentChannelId});
    }
    function parseChain(c){if(!c||!c.startsWith('[CHAIN]'))return null;try{return JSON.parse(c.substring(7))}catch(e){return null}}

    /* Load more */
    async function loadMore(){await loadMessages(store.currentChannelId,true);msgListKey.value++}

    /* Context menu */
    const ctxMenu=ref(null);
    function showCtx(e,msg){
      e.preventDefault();ctxMenu.value={x:Math.min(e.clientX,window.innerWidth-160),y:Math.min(e.clientY,window.innerHeight-80),msg};
      setTimeout(()=>document.addEventListener('click',hideCtx,{once:true}),50);
    }
    function hideCtx(){ctxMenu.value=null}
    function setReply(msg){replyTo.value=msg;ctxMenu.value=null;document.querySelector('.input-area textarea')?.focus()}

    return{page,loginErr,showReg,sidebarOpen,showMembers,currentModal,modalData,replyTo,noticeExpanded,msgInput,msgListKey,
      currentChannel,currentMessages,onlineSet,channelMembers,ctxMenu,
      doLogin,doRegister,logout,sendMsg,handleKey,insertNewline,autoGrow,uploadFile,sendChain,joinChain,parseChain,loadMore,showCtx,setReply,
      switchChannel:async(id)=>{sidebarOpen.value=false;await switchChannel(id)},
      store,esc,fmtTime,fmtSize,avatarUrl,sanitize,
      togglePush,checkPush}
  },
  template:`
<div v-if="page==='login'" class="login-page" id="loginPage">
  <div class="login-card">
    <h1 id="loginTitle">{{store.appearance.login_title||'团队聊天室'}}</h1>
    <div v-if="!showReg">
      <input id="lu" type="text" placeholder="用户名" @keyup.enter="$refs.lp?.focus()">
      <input ref="lp" id="lpp" type="password" placeholder="密码" @keyup.enter="doLogin(document.getElementById('lu').value,document.getElementById('lpp').value)">
      <button @click="doLogin(document.getElementById('lu').value,document.getElementById('lpp').value)">登录</button>
    </div>
    <div v-else>
      <input id="ru" type="text" placeholder="用户名"><input id="rn" type="text" placeholder="昵称 (选填)">
      <input id="rp" type="password" placeholder="密码 (至少6位)"><input id="rp2" type="password" placeholder="确认密码">
      <button @click="doRegister(document.getElementById('ru').value,document.getElementById('rp').value,document.getElementById('rp2').value,document.getElementById('rn').value)">注册</button>
    </div>
    <p v-if="loginErr" class="error" :style="{color:loginErr.startsWith('✅')?'#10b981':'#dc2626'}">{{loginErr}}</p>
    <p v-if="store.regOpen" class="reg-toggle"><a href="#" @click.prevent="showReg=!showReg;loginErr=''">{{showReg?'已有账号？去登录':'还没有账号？注册一个'}}</a></p>
  </div>
</div>

<div v-else class="app-layout">
  <!-- Sidebar overlay (mobile) -->
  <div class="sidebar-overlay" :class="{show:sidebarOpen}" @click="sidebarOpen=false"></div>
  <!-- Sidebar -->
  <div class="sidebar" :class="{open:sidebarOpen}">
    <div class="sidebar-header">
      <h2>{{store.appearance.chat_title||'TeamChat'}}</h2>
      <button v-if="store.isAdmin" class="btn-icon" title="管理频道" @click="currentModal='channelMgmt'">⚙️</button>
    </div>
    <div class="channel-list">
      <div v-for="ch in store.channels" :key="ch.id" class="channel-item" :class="{active:ch.id===store.currentChannelId}" @click="switchChannel(ch.id)">
        <span class="ch-icon">{{ch.is_private?'🔒':'#'}}</span>
        <span class="ch-name">{{ch.name}}</span>
        <span v-if="ch._unread>0" class="ch-badge">{{ch._unread>99?'99+':ch._unread}}</span>
      </div>
    </div>
    <div class="sidebar-footer">
      <img :src="avatarUrl(store.avatar)" alt="">
      <span class="user-name">{{store.nickname||store.username}}</span>
      <button class="btn-icon" title="设置" @click="currentModal='settings'">⚙</button>
      <button class="btn-icon" title="退出" @click="logout()">🚪</button>
    </div>
  </div>
  <!-- Main area -->
  <div class="main-area">
    <div class="chat-header">
      <div class="chat-header-left">
        <button class="menu-btn" @click="sidebarOpen=!sidebarOpen">☰</button>
        <div>
          <h3>{{currentChannel?currentChannel.name:'TeamChat'}}</h3>
          <div v-if="currentChannel&&currentChannel.description" class="ch-desc">{{currentChannel.description}}</div>
        </div>
      </div>
      <div class="chat-header-right">
        <span class="online-tag">{{store.onlineUsers.length}}人在线</span>
        <button class="btn-icon" title="成员" @click="showMembers=!showMembers">👥</button>
      </div>
    </div>
    <!-- Notice -->
    <div v-if="store.notice.enabled&&store.notice.content" class="notice-bar" @click="noticeExpanded=!noticeExpanded">
      <span class="notice-icon">📌</span>
      <span class="notice-text">{{store.notice.content.substring(0,60)}}</span>
      <span>{{noticeExpanded?'▲':'▼'}}</span>
    </div>
    <div v-if="noticeExpanded&&store.notice.enabled" class="notice-expanded">{{store.notice.content}}</div>
    <!-- Messages -->
    <div class="messages-wrapper">
      <div class="messages" :key="msgListKey">
        <div v-if="!(msgStore[store.currentChannelId]||{}).allLoaded" class="load-more" @click="loadMore()">加载更多</div>
        <div v-for="m in currentMessages" :key="m.id" class="msg" :class="{my:m.username===store.username,other:m.username!==store.username}" @contextmenu="showCtx($event,m)">
          <img class="msg-avatar" :src="avatarUrl(m.avatar)" :alt="m.nickname||m.username">
          <div class="msg-body">
            <div class="msg-sender">{{m.nickname||m.username}}</div>
            <div class="msg-bubble">
              <div v-if="m.reply_to" class="reply-ref">{{getReplyPreview(m.reply_to)}}</div>
              <div v-if="m.type==='text'&&m.content&&m.content.startsWith('[CHAIN]')" v-html="renderChain(m)"></div>
              <div v-else-if="m.type==='text'" class="msg-content" v-html="sanitize(m.content)"></div>
              <img v-else-if="m.type==='image'" class="chat-image" :src="API+'/uploads/'+encodeURIComponent(m.file_path)" :alt="m.file_name" @click="currentModal='imagePreview';modalData={src:API+'/uploads/'+encodeURIComponent(m.file_path)}">
              <div v-else-if="m.type==='file'" class="file-card" @click="downloadFile(API+'/uploads/'+encodeURIComponent(m.file_path),m.file_name)">📄 {{m.file_name}} ({{fmtSize(m.file_size)}})</div>
              <div class="msg-time">{{fmtTime(m.created_at)}}</div>
            </div>
          </div>
        </div>
      </div>
    </div>
    <!-- Reply bar -->
    <div v-if="replyTo" class="reply-bar">
      <span style="font-weight:600;color:#667eea">引用 {{replyTo.nickname||replyTo.username}}:</span>
      <span class="reply-text">{{(replyTo.content||'').replace(/<[^>]*>/g,'').substring(0,40)}}</span>
      <button @click="replyTo=null">✕</button>
    </div>
    <!-- Input -->
    <div class="input-area">
      <button class="attach-btn" @click="$refs.fileInput.click()">📎</button>
      <input ref="fileInput" type="file" hidden @change="uploadFile($event.target.files[0]);$event.target.value=''">
      <textarea v-model="msgInput" placeholder="输入消息... (Shift+Enter 换行)" rows="1" enterkeyhint="send" @keydown="handleKey" @input="autoGrow"></textarea>
      <button class="newline-btn" @mousedown.prevent @click="insertNewline()">⏎</button>
      <button class="chain-btn" @click="currentModal='chainNew'" title="发起接龙">🚂</button>
      <button class="send-btn" @mousedown.prevent @click="sendMsg()">{{store.appearance.send_text||'发送'}}</button>
    </div>
  </div>
  <!-- Members panel (desktop) -->
  <div v-if="showMembers" class="members-panel">
    <div class="members-panel-header">在线成员 ({{store.onlineUsers.length}})</div>
    <div class="members-list">
      <div v-for="u in store.onlineUsers" :key="u.username" class="member-item">
        <img :src="avatarUrl(u.avatar)" alt=""><span class="member-name">{{u.nickname||u.username}}</span>
        <span class="online-dot on"></span>
      </div>
    </div>
  </div>
</div>

<!-- Context menu -->
<div v-if="ctxMenu" class="msg-menu" :style="{left:ctxMenu.x+'px',top:ctxMenu.y+'px'}">
  <div class="menu-item" @click="setReply(ctxMenu.msg)">💬 引用回复</div>
</div>

<!-- Image preview -->
<div v-if="currentModal==='imagePreview'" class="image-modal" @click="currentModal=''">
  <img :src="modalData.src" alt="预览">
</div>

<!-- Settings modal -->
<div v-if="currentModal==='settings'" class="modal-overlay" @click.self="currentModal=''">
  <div class="modal">
    <h3>设置</h3>
    <div class="section"><h4>🔔 推送通知</h4><p id="pushInfo" style="font-size:13px;color:#666">检测中...</p><button id="pushBtn" style="display:none" @click="doPushToggle()">开启推送</button></div>
    <div class="section"><h4>上传头像</h4>
      <div class="avatar-upload"><img class="avatar-preview" :src="avatarUrl(store.avatar)" alt=""><input type="file" accept="image/*" hidden ref="avatarFileInput" @change="doAvatarUpload($event)"><button @click="$refs.avatarFileInput.click()">选择图片</button><p id="avatarMsg" style="font-size:13px"></p></div>
    </div>
    <div class="section"><h4>修改密码</h4>
      <input id="oldPwd" type="password" placeholder="原密码"><input id="newPwd" type="password" placeholder="新密码 (至少6位)">
      <button @click="doChangePwd()">确认修改</button><p id="pwdMsg" style="font-size:13px"></p>
    </div>
    <div v-if="store.isAdmin" class="section"><h4>管理功能</h4>
      <div style="margin-bottom:10px"><label class="field-label">消息时区</label><select id="tzSel" style="width:100%;padding:10px;border:1px solid #ddd;border-radius:8px" @change="doSaveTz()">
        <option v-for="tz in tzList" :key="tz.v" :value="tz.v" :selected="store.timezone===tz.v">{{tz.l}}</option>
      </select></div>
      <button class="success" @click="currentModal='notice'">📌 置顶通知</button>
      <button class="success" @click="currentModal='appearance'">🎨 外观定制</button>
      <button class="success" @click="currentModal='userMgmt';loadUsers()">👥 用户管理</button>
      <button class="success" @click="currentModal='channelMgmt';loadAllChannels()">📺 频道管理</button>
      <button class="success" @click="doToggleReg()">📝 {{store.regOpen?'关闭':'开放'}}注册</button>
      <button class="success" @click="currentModal='backup'">💾 备份/还原</button>
      <button class="danger" @click="currentModal='deleteMsg'">🗑️ 删除记录</button>
    </div>
    <button class="close-btn" @click="currentModal=''">关闭</button>
  </div>
</div>

<!-- Channel management modal -->
<div v-if="currentModal==='channelMgmt'" class="modal-overlay" @click.self="currentModal=''">
  <div class="modal">
    <h3>📺 频道管理</h3>
    <div class="section"><h4>新建频道</h4>
      <input id="newChName" type="text" placeholder="频道名称">
      <input id="newChDesc" type="text" placeholder="频道描述 (选填)">
      <label style="display:flex;align-items:center;gap:8px;margin-bottom:10px;font-size:14px"><input type="checkbox" id="newChPrivate"> 私有频道 (需要手动添加成员)</label>
      <button @click="doCreateChannel()">创建频道</button><p id="chCreateMsg" style="font-size:13px"></p>
    </div>
    <div class="section"><h4>已有频道</h4>
      <div v-for="ch in modalData.allChannels||[]" :key="ch.id" class="ch-mgmt-item">
        <div class="ch-info"><div class="ch-name">{{ch.is_private?'🔒':''}} {{ch.name}}</div><div class="ch-meta">{{ch.description||'无描述'}} · {{ch._memberCount||0}}人</div></div>
        <button style="width:auto;padding:6px 10px;font-size:12px;margin:0;background:#667eea" @click="openChannelPerm(ch)">权限</button>
        <button v-if="!ch.is_default" style="width:auto;padding:6px 10px;font-size:12px;margin:0;background:#dc2626" @click="doDeleteChannel(ch)">删除</button>
      </div>
    </div>
    <button class="close-btn" @click="currentModal='settings'">返回</button>
  </div>
</div>

<!-- Channel permission modal -->
<div v-if="currentModal==='channelPerm'" class="modal-overlay" @click.self="currentModal='channelMgmt'">
  <div class="modal">
    <h3>🔐 频道权限: {{modalData.permChannel?.name}}</h3>
    <div class="section"><h4>添加成员</h4>
      <select id="addMemberSel" style="width:70%;display:inline-block"><option v-for="u in modalData.nonMembers||[]" :key="u.username" :value="u.username">{{u.nickname||u.username}}</option></select>
      <button style="width:28%;display:inline-block;margin-left:2%" @click="doAddMember()">添加</button>
    </div>
    <div class="section"><h4>当前成员</h4>
      <div class="ch-perm-grid">
        <div v-for="m in modalData.permMembers||[]" :key="m.user_id" class="ch-perm-row">
          <span class="perm-user">{{m.nickname||m.username}}</span>
          <select :value="m.role" @change="doChangeRole(m,$event.target.value)"><option value="owner">所有者</option><option value="admin">管理员</option><option value="member">成员</option><option value="viewer">只读</option></select>
          <button style="width:auto;padding:4px 8px;font-size:11px;margin:0;background:#dc2626" @click="doRemoveMember(m)">移除</button>
        </div>
      </div>
    </div>
    <button class="close-btn" @click="currentModal='channelMgmt'">返回</button>
  </div>
</div>

<!-- Notice modal -->
<div v-if="currentModal==='notice'" class="modal-overlay" @click.self="currentModal='settings'">
  <div class="modal"><h3>📌 置顶通知</h3>
    <textarea id="noticeInput" rows="4" :value="store.notice.content||''" placeholder="输入通知内容..."></textarea>
    <button @click="doSaveNotice()">发布</button><button class="danger" @click="doClearNotice()">撤下</button>
    <p id="noticeMsg" style="font-size:13px;text-align:center"></p>
    <button class="close-btn" @click="currentModal='settings'">返回</button>
  </div>
</div>

<!-- Appearance modal -->
<div v-if="currentModal==='appearance'" class="modal-overlay" @click.self="currentModal='settings'">
  <div class="modal"><h3>🎨 外观定制</h3>
    <div class="section"><label class="field-label">登录标题</label><input id="appLT" type="text" :value="store.appearance.login_title||''" placeholder="团队聊天室" maxlength="30">
    <label class="field-label">聊天标题</label><input id="appCT" type="text" :value="store.appearance.chat_title||''" placeholder="团队聊天" maxlength="30"></div>
    <div class="section"><label class="field-label">发送按钮文字</label><input id="appST" type="text" :value="store.appearance.send_text||''" placeholder="发送" maxlength="10">
    <label class="field-label">发送按钮颜色</label><div class="color-row"><input type="color" id="appSC" :value="store.appearance.send_color||'#667eea'"><span id="appSCH" style="font-size:13px;color:#666">{{store.appearance.send_color||'#667eea'}}</span></div></div>
    <div class="section"><label class="field-label">聊天背景颜色</label><div class="color-row"><input type="color" id="appBG" :value="store.appearance.bg_color||'#f0f2f5'"><span style="font-size:13px;color:#666">{{store.appearance.bg_color||'#f0f2f5'}}</span></div></div>
    <button @click="doSaveAppearance()">💾 保存并应用</button><p id="appearMsg" style="font-size:13px;text-align:center"></p>
    <button class="close-btn" @click="currentModal='settings'">返回</button>
  </div>
</div>

<!-- User management modal -->
<div v-if="currentModal==='userMgmt'" class="modal-overlay" @click.self="currentModal='settings'">
  <div class="modal"><h3>👥 用户管理</h3>
    <div class="section"><h4>添加用户</h4>
      <input id="newU" type="text" placeholder="用户名"><input id="newUP" type="password" placeholder="密码 (至少6位)"><input id="newUN" type="text" placeholder="昵称">
      <button @click="doAddUser()">添加</button><p id="addUserMsg" style="font-size:13px"></p>
    </div>
    <div class="section"><h4>用户列表</h4>
      <div class="user-list"><div v-for="u in modalData.users||[]" :key="u.id" class="user-item">
        <div><span class="username">{{u.username}}</span><span v-if="u.is_admin" style="color:#667eea;font-size:11px;margin-left:4px">(管理员)</span><br><span class="nickname">{{u.nickname}}</span></div>
        <div><button v-if="!u.is_admin" style="background:#dc2626" @click="doDeleteUser(u)">删除</button></div>
      </div></div>
    </div>
    <button class="close-btn" @click="currentModal='settings'">返回</button>
  </div>
</div>

<!-- Backup modal -->
<div v-if="currentModal==='backup'" class="modal-overlay" @click.self="currentModal='settings'">
  <div class="modal"><h3>💾 备份与还原</h3>
    <div class="section"><h4>导出备份</h4><input type="date" id="bkStart"><input type="date" id="bkEnd"><button @click="doExportBackup()">下载备份</button></div>
    <div class="section"><h4>还原备份</h4><input type="file" id="restoreFile" accept=".json"><button @click="doRestoreBackup()">还原</button></div>
    <p id="backupMsg" style="font-size:13px;text-align:center"></p>
    <button class="close-btn" @click="currentModal='settings'">返回</button>
  </div>
</div>

<!-- Delete messages modal -->
<div v-if="currentModal==='deleteMsg'" class="modal-overlay" @click.self="currentModal='settings'">
  <div class="modal"><h3>🗑️ 删除聊天记录</h3><p style="color:#dc2626;text-align:center">⚠️ 此操作不可恢复！</p>
    <input type="date" id="delStart"><input type="date" id="delEnd">
    <button class="danger" @click="doDeleteMessages()">确认删除</button><p id="delMsg" style="font-size:13px;text-align:center"></p>
    <button class="close-btn" @click="currentModal='settings'">返回</button>
  </div>
</div>

<!-- Chain modal -->
<div v-if="currentModal==='chainNew'" class="modal-overlay" @click.self="currentModal=''">
  <div class="modal" style="max-width:400px"><h3>🚂 发起接龙</h3>
    <label class="field-label">接龙话题</label><input id="chainTopic" type="text" placeholder="例如：明天团建午餐吃什么？">
    <label class="field-label">补充说明 (选填)</label><textarea id="chainDesc" rows="2" placeholder="规则、选项等..."></textarea>
    <div style="display:flex;gap:10px;margin-top:10px"><button class="secondary" style="flex:1" @click="currentModal=''">取消</button><button style="flex:1" @click="sendChain(document.getElementById('chainTopic').value.trim(),document.getElementById('chainDesc').value.trim())">发起</button></div>
  </div>
</div>
`,
  methods:{
    getReplyPreview(replyId){
      const ch=msgStore[store.currentChannelId];if(!ch)return'';
      const m=ch.msgs.find(m=>m.id===replyId);if(!m)return'';
      const name=m.nickname||m.username;
      if(m.type==='image')return name+': [图片]';if(m.type==='file')return name+': [文件]';
      return name+': '+(m.content||'').replace(/<[^>]*>/g,'').substring(0,40);
    },
    renderChain(msg){
      const d=this.parseChain(msg.content);if(!d)return'';
      let h='<div class="chain-card"><div class="chain-header">🚂 接龙</div>';
      h+='<div class="chain-topic">'+esc(d.topic)+'</div>';
      if(d.desc)h+='<div class="chain-desc">'+esc(d.desc)+'</div>';
      if(d.participants&&d.participants.length){h+='<div class="chain-list">';d.participants.forEach(p=>{h+='<div><span class="chain-seq">'+p.seq+'</span><span class="chain-name">'+esc(p.name)+'</span>'+(p.text?' '+esc(p.text):'')+'</div>'});h+='</div>'}
      const joined=d.participants&&d.participants.some(p=>p.username===store.username);
      if(joined)h+='<button class="chain-join-btn joined" disabled>✅ 已参与</button>';
      else h+='<button class="chain-join-btn" onclick="document.querySelector(\'#app\').__vue_app__.config.globalProperties.$root.joinChainById('+msg.id+')">🙋 参与接龙</button>';
      return h+'</div>';
    },
    downloadFile(url,name){const a=document.createElement('a');a.href=url;a.download=name;a.click()},
    joinChainById(id){const ch=msgStore[store.currentChannelId];if(!ch)return;const m=ch.msgs.find(m=>m.id===id);if(m)this.joinChain(m)},
    /* Admin methods */
    async loadUsers(){try{const r=await fetch(API+'/api/users',{headers:authH()});if(r.ok)this.modalData.users=await r.json()}catch(e){}},
    async doAddUser(){
      const u=document.getElementById('newU').value.trim(),p=document.getElementById('newUP').value,n=document.getElementById('newUN').value.trim();
      const m=document.getElementById('addUserMsg');if(!u||!p){m.textContent='请填写完整';return}
      try{const r=await fetch(API+'/api/users',{method:'POST',headers:authH({'Content-Type':'application/json'}),body:JSON.stringify({username:u,password:p,nickname:n||u})});const d=await r.json();m.textContent=d.success?'✅ 已添加':d.message||'失败';if(d.success)this.loadUsers()}catch(e){m.textContent='失败'}
    },
    async doDeleteUser(u){if(!confirm('确认删除 '+u.username+'?'))return;try{await fetch(API+'/api/users/'+u.username,{method:'DELETE',headers:authH()});this.loadUsers()}catch(e){}},
    async doChangePwd(){
      const o=document.getElementById('oldPwd').value,n=document.getElementById('newPwd').value,m=document.getElementById('pwdMsg');
      if(!o||!n||n.length<6){m.textContent='请填写完整(新密码至少6位)';return}
      try{const r=await fetch(API+'/api/change-password',{method:'POST',headers:authH({'Content-Type':'application/json'}),body:JSON.stringify({oldPassword:o,newPassword:n})});const d=await r.json();m.textContent=d.success?'✅ 已修改':d.message||'失败'}catch(e){m.textContent='失败'}
    },
    async doAvatarUpload(e){
      const f=e.target.files[0];if(!f)return;const fd=new FormData();fd.append('avatar',f);
      try{const r=await fetch(API+'/api/upload-avatar',{method:'POST',headers:{'Authorization':'Bearer '+store.token},body:fd});const d=await r.json();if(d.success){store.avatar=d.avatar;localStorage.setItem('avatar',d.avatar);document.getElementById('avatarMsg').textContent='✅ 已更新'}else document.getElementById('avatarMsg').textContent=d.message||'失败'}catch(e){document.getElementById('avatarMsg').textContent='失败'}
    },
    async doSaveTz(){
      const tz=document.getElementById('tzSel').value;
      try{await fetch(API+'/api/settings/timezone',{method:'POST',headers:authH({'Content-Type':'application/json'}),body:JSON.stringify({timezone:tz})});store.timezone=tz}catch(e){}
    },
    async doToggleReg(){try{const r=await fetch(API+'/api/settings/registration',{method:'POST',headers:authH({'Content-Type':'application/json'}),body:JSON.stringify({open:!store.regOpen})});const d=await r.json();if(d.success)store.regOpen=d.open}catch(e){}},
    async doSaveNotice(){
      const c=document.getElementById('noticeInput').value.trim(),m=document.getElementById('noticeMsg');if(!c){m.textContent='请输入内容';return}
      try{const r=await fetch(API+'/api/settings/notice',{method:'POST',headers:authH({'Content-Type':'application/json'}),body:JSON.stringify({content:c,enabled:true})});const d=await r.json();m.textContent=d.success?'✅ 已发布':'失败'}catch(e){m.textContent='失败'}
    },
    async doClearNotice(){try{await fetch(API+'/api/settings/notice',{method:'POST',headers:authH({'Content-Type':'application/json'}),body:JSON.stringify({content:'',enabled:false})});document.getElementById('noticeMsg').textContent='✅ 已撤下'}catch(e){}},
    async doSaveAppearance(){
      const b={login_title:document.getElementById('appLT').value,chat_title:document.getElementById('appCT').value,send_text:document.getElementById('appST').value,send_color:document.getElementById('appSC').value,bg_color:document.getElementById('appBG').value};
      try{const r=await fetch(API+'/api/settings/appearance',{method:'POST',headers:authH({'Content-Type':'application/json'}),body:JSON.stringify(b)});const d=await r.json();document.getElementById('appearMsg').textContent=d.success?'✅ 已保存':'失败'}catch(e){document.getElementById('appearMsg').textContent='失败'}
    },
    async doExportBackup(){const s=document.getElementById('bkStart').value,e=document.getElementById('bkEnd').value;let url=API+'/api/backup?';if(s&&e)url+='startDate='+s+'&endDate='+e;try{const r=await fetch(url,{headers:authH()});const d=await r.json();const bl=new Blob([JSON.stringify(d,null,2)],{type:'application/json'});const a=document.createElement('a');a.href=URL.createObjectURL(bl);a.download='teamchat-backup.json';a.click()}catch(e){document.getElementById('backupMsg').textContent='导出失败'}},
    async doRestoreBackup(){const f=document.getElementById('restoreFile').files[0];if(!f)return;const t=await f.text();try{const d=JSON.parse(t);const r=await fetch(API+'/api/restore',{method:'POST',headers:authH({'Content-Type':'application/json'}),body:JSON.stringify(d)});const res=await r.json();document.getElementById('backupMsg').textContent=res.success?'✅ 还原 '+res.count+' 条':'失败'}catch(e){document.getElementById('backupMsg').textContent='格式错误'}},
    async doDeleteMessages(){const s=document.getElementById('delStart').value,e=document.getElementById('delEnd').value;if(!s||!e)return;if(!confirm('确认删除 '+s+' 到 '+e+' 的记录?'))return;try{const r=await fetch(API+'/api/messages',{method:'DELETE',headers:authH({'Content-Type':'application/json'}),body:JSON.stringify({startDate:s,endDate:e})});const d=await r.json();document.getElementById('delMsg').textContent=d.success?'✅ 已删除 '+d.deleted+' 条':'失败'}catch(e){document.getElementById('delMsg').textContent='失败'}},
    /* Channel management */
    async loadAllChannels(){try{const r=await fetch(API+'/api/admin/channels',{headers:authH()});if(r.ok)this.modalData.allChannels=await r.json()}catch(e){}},
    async doCreateChannel(){
      const n=document.getElementById('newChName').value.trim(),d=document.getElementById('newChDesc').value.trim(),p=document.getElementById('newChPrivate').checked;
      const m=document.getElementById('chCreateMsg');if(!n){m.textContent='请输入频道名';return}
      try{const r=await fetch(API+'/api/channels',{method:'POST',headers:authH({'Content-Type':'application/json'}),body:JSON.stringify({name:n,description:d,is_private:p})});const res=await r.json();m.textContent=res.success?'✅ 已创建':'失败: '+(res.message||'');if(res.success){this.loadAllChannels();await loadChannels()}}catch(e){m.textContent='失败'}
    },
    async doDeleteChannel(ch){if(!confirm('确认删除频道 '+ch.name+'? 频道内的消息也会被删除。'))return;try{await fetch(API+'/api/channels/'+ch.id,{method:'DELETE',headers:authH()});this.loadAllChannels();await loadChannels()}catch(e){}},
    async openChannelPerm(ch){
      this.modalData.permChannel=ch;this.currentModal='channelPerm';
      try{const r=await fetch(API+'/api/channels/'+ch.id+'/members',{headers:authH()});if(r.ok)this.modalData.permMembers=await r.json()}catch(e){}
      try{const r=await fetch(API+'/api/users',{headers:authH()});if(r.ok){const all=await r.json();const memNames=new Set((this.modalData.permMembers||[]).map(m=>m.username));this.modalData.nonMembers=all.filter(u=>!memNames.has(u.username))}}catch(e){}
    },
    async doAddMember(){
      const u=document.getElementById('addMemberSel').value;if(!u)return;const ch=this.modalData.permChannel;
      try{await fetch(API+'/api/channels/'+ch.id+'/members',{method:'POST',headers:authH({'Content-Type':'application/json'}),body:JSON.stringify({username:u,role:'member'})});this.openChannelPerm(ch)}catch(e){}
    },
    async doRemoveMember(m){
      const ch=this.modalData.permChannel;
      try{await fetch(API+'/api/channels/'+ch.id+'/members/'+m.user_id,{method:'DELETE',headers:authH()});this.openChannelPerm(ch)}catch(e){}
    },
    async doChangeRole(m,role){
      const ch=this.modalData.permChannel;
      try{await fetch(API+'/api/channels/'+ch.id+'/members/'+m.user_id,{method:'PUT',headers:authH({'Content-Type':'application/json'}),body:JSON.stringify({role})});this.openChannelPerm(ch)}catch(e){}
    },
    async doPushToggle(){
      const ok=await togglePush();
      const st=await checkPush();
      document.getElementById('pushInfo').textContent=st.subscribed?'✅ 推送已开启':st.reason||'推送未开启';
      const btn=document.getElementById('pushBtn');
      if(st.supported){btn.style.display='block';btn.textContent=st.subscribed?'关闭推送':'开启推送';btn.style.background=st.subscribed?'#dc2626':'#667eea'}
    },
    tzList:[
      {v:'Asia/Shanghai',l:'中国标准时间 (UTC+8)'},{v:'Asia/Tokyo',l:'日本标准时间 (UTC+9)'},{v:'Asia/Singapore',l:'新加坡时间 (UTC+8)'},
      {v:'Asia/Kolkata',l:'印度标准时间 (UTC+5:30)'},{v:'Asia/Dubai',l:'海湾标准时间 (UTC+4)'},{v:'Europe/London',l:'英国时间 (UTC+0/+1)'},
      {v:'Europe/Paris',l:'中欧时间 (UTC+1/+2)'},{v:'Europe/Moscow',l:'莫斯科时间 (UTC+3)'},{v:'America/New_York',l:'美国东部时间'},
      {v:'America/Chicago',l:'美国中部时间'},{v:'America/Denver',l:'美国山地时间'},{v:'America/Los_Angeles',l:'美国太平洋时间'},
      {v:'Pacific/Auckland',l:'新西兰时间'},{v:'Australia/Sydney',l:'悉尼时间'}
    ],
  },
  async mounted(){
    /* Push init after settings open */
    this.$watch(()=>this.currentModal,async(v)=>{
      if(v==='settings'){await nextTick();const st=await checkPush();document.getElementById('pushInfo').textContent=st.subscribed?'✅ 推送已开启':st.reason||'推送未开启';const btn=document.getElementById('pushBtn');if(st.supported){btn.style.display='block';btn.textContent=st.subscribed?'关闭推送':'开启推送';btn.style.background=st.subscribed?'#dc2626':'#667eea'}}
    });
  }
};

/* iOS PWA keyboard fix */
(function(){if(!/iPad|iPhone|iPod/.test(navigator.userAgent))return;document.addEventListener('focusout',function(e){setTimeout(function(){window.scrollTo(0,0)},100)});if(window.visualViewport){var lh=window.visualViewport.height;window.visualViewport.addEventListener('resize',function(){var nh=window.visualViewport.height;if(nh>lh){setTimeout(function(){window.scrollTo(0,0)},50)}lh=nh})}})();

/* Load Vue 3 from CDN then mount */
(function(){
  const s=document.createElement('script');
  s.src='https://unpkg.com/vue@3/dist/vue.global.prod.js';
  s.onload=function(){const app=Vue.createApp(App);app.config.globalProperties.$root=app._instance?.proxy;app.mount('#app');nextTick(()=>applyAppearance(store.appearance))};
  document.head.appendChild(s);
})();
APPEOF


    # ===== package.json =====
    cat > "$APP_DIR/package.json" <<'PKGEOF'
{
  "name": "teamchat",
  "version": "9.0.0",
  "private": true,
  "main": "server.js",
  "scripts": { "start": "node server.js" },
  "dependencies": {
    "better-sqlite3": "^9.2.2",
    "bcryptjs": "^2.4.3",
    "cors": "^2.8.5",
    "express": "^4.18.2",
    "jsonwebtoken": "^9.0.2",
    "multer": "^1.4.5-lts.1",
    "socket.io": "^4.7.2",
    "uuid": "^9.0.0",
    "web-push": "^3.6.6"
  }
}
PKGEOF

    # ===== server.js — modular backend with channels + RBAC =====
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

/* ===== Secrets ===== */
const SECRET_FILE = path.join(__dirname, ".jwt_secret");
let JWT_SECRET;
if (fs.existsSync(SECRET_FILE)) JWT_SECRET = fs.readFileSync(SECRET_FILE, "utf-8").trim();
else { JWT_SECRET = crypto.randomBytes(32).toString("hex"); fs.writeFileSync(SECRET_FILE, JWT_SECRET, { mode: 0o600 }); }

const VAPID_FILE = path.join(__dirname, ".vapid_keys");
let vapidKeys;
if (fs.existsSync(VAPID_FILE)) vapidKeys = JSON.parse(fs.readFileSync(VAPID_FILE, "utf-8"));
else { vapidKeys = webpush.generateVAPIDKeys(); fs.writeFileSync(VAPID_FILE, JSON.stringify(vapidKeys), { mode: 0o600 }); }
webpush.setVapidDetails("mailto:admin@teamchat.local", vapidKeys.publicKey, vapidKeys.privateKey);

const PORT = process.env.PORT || __PORT_PLACEHOLDER__;
const DB_PATH = path.join(__dirname, "database.sqlite");
const UPLOAD_DIR = path.join(__dirname, "uploads");
const AVATAR_DIR = path.join(__dirname, "avatars");
const BG_DIR = path.join(__dirname, "backgrounds");
[UPLOAD_DIR, AVATAR_DIR, BG_DIR].forEach(d => { if (!fs.existsSync(d)) fs.mkdirSync(d, { recursive: true }); });

/* ===== Database ===== */
const db = new Database(DB_PATH);
db.pragma("journal_mode = WAL");
db.pragma("foreign_keys = ON");

/* Migrations */
try { db.exec("ALTER TABLE users ADD COLUMN is_admin INTEGER DEFAULT 0"); } catch(e) {}
try { db.exec("ALTER TABLE messages ADD COLUMN reply_to INTEGER"); } catch(e) {}
try { db.exec("ALTER TABLE users ADD COLUMN last_login_at TEXT"); } catch(e) {}
try { db.exec("ALTER TABLE messages ADD COLUMN channel_id INTEGER DEFAULT 1"); } catch(e) {}

/* Timestamp migration */
try {
  const nf = db.prepare("SELECT COUNT(*) as cnt FROM messages WHERE created_at NOT LIKE '%Z' AND created_at NOT LIKE '%+%' AND created_at NOT LIKE '%-__:__'").get();
  if (nf && nf.cnt > 0) { db.exec("UPDATE messages SET created_at = REPLACE(created_at, ' ', 'T') || 'Z' WHERE created_at NOT LIKE '%Z' AND created_at NOT LIKE '%+%' AND created_at NOT LIKE '%-__:__'"); console.log("✅ 已迁移 " + nf.cnt + " 条时间戳"); }
} catch(e) {}

db.exec(`
  CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP);
  CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT UNIQUE NOT NULL, password TEXT NOT NULL, nickname TEXT, avatar TEXT, is_admin INTEGER DEFAULT 0, last_login_at TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP);
  CREATE TABLE IF NOT EXISTS channels (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, description TEXT DEFAULT '', is_private INTEGER DEFAULT 0, is_default INTEGER DEFAULT 0, created_by INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP);
  CREATE TABLE IF NOT EXISTS channel_members (id INTEGER PRIMARY KEY AUTOINCREMENT, channel_id INTEGER NOT NULL, user_id INTEGER NOT NULL, role TEXT DEFAULT 'member', created_at DATETIME DEFAULT CURRENT_TIMESTAMP, UNIQUE(channel_id, user_id), FOREIGN KEY (channel_id) REFERENCES channels(id) ON DELETE CASCADE, FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE);
  CREATE TABLE IF NOT EXISTS messages (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL, username TEXT NOT NULL, content TEXT, type TEXT DEFAULT 'text', file_name TEXT, file_path TEXT, file_size INTEGER, reply_to INTEGER, channel_id INTEGER DEFAULT 1, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE);
  CREATE TABLE IF NOT EXISTS push_subscriptions (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL, endpoint TEXT UNIQUE NOT NULL, keys_p256dh TEXT NOT NULL, keys_auth TEXT NOT NULL, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE);
`);

/* Ensure default channel exists */
const defaultCh = db.prepare("SELECT id FROM channels WHERE is_default = 1").get();
if (!defaultCh) {
  const r = db.prepare("INSERT INTO channels (name, description, is_default, is_private) VALUES ('综合频道', '默认公开频道', 1, 0)").run();
  const chId = r.lastInsertRowid;
  /* Add all existing users to default channel */
  const users = db.prepare("SELECT id FROM users").all();
  const ins = db.prepare("INSERT OR IGNORE INTO channel_members (channel_id, user_id, role) VALUES (?, ?, ?)");
  users.forEach(u => ins.run(chId, u.id, 'member'));
  /* Migrate old messages to default channel */
  db.prepare("UPDATE messages SET channel_id = ? WHERE channel_id IS NULL OR channel_id = 0 OR channel_id = 1").run(chId);
  console.log("✅ 默认频道已创建, ID=" + chId);
}

/* Default settings */
const defaultSettings = { timezone:"Asia/Shanghai", login_title:"团队聊天室", chat_title:"TeamChat", send_text:"发送", send_color:"#667eea", bg_type:"color", bg_color:"#f0f2f5", bg_image:"", bg_mode:"cover", bg_video:"", bg_video_url:"", bg_video_mode:"cover", pinned_notice:"", pinned_notice_enabled:"0", registration_open:"0", login_bg_type:"gradient", login_bg_color1:"#667eea", login_bg_color2:"#764ba2", login_bg_image:"", login_bg_mode:"cover", login_bg_video:"", login_bg_video_url:"", login_bg_video_mode:"cover" };
const insSetting = db.prepare("INSERT OR IGNORE INTO settings (key, value) VALUES (?, ?)");
for (const [k, v] of Object.entries(defaultSettings)) insSetting.run(k, v);

/* ===== Middleware & Helpers ===== */
app.use(cors());
app.use(express.json({ limit: "5mb" }));
app.get("/sw.js", (req, res) => { res.setHeader("Cache-Control", "no-cache, no-store, must-revalidate"); res.setHeader("Content-Type", "application/javascript"); res.sendFile(path.join(__dirname, "public", "sw.js")); });
app.get("/manifest.json", (req, res) => { res.setHeader("Cache-Control", "no-cache"); res.setHeader("Content-Type", "application/manifest+json"); res.sendFile(path.join(__dirname, "public", "manifest.json")); });
app.use(express.static(path.join(__dirname, "public")));
app.use("/uploads", express.static(UPLOAD_DIR));
app.use("/avatars", express.static(AVATAR_DIR));
app.use("/backgrounds", express.static(BG_DIR));

function getSetting(k) { const r = db.prepare("SELECT value FROM settings WHERE key=?").get(k); return r ? r.value : (defaultSettings[k] || ""); }
function setSetting(k, v) { db.prepare("INSERT OR REPLACE INTO settings (key,value,updated_at) VALUES (?,?,datetime('now'))").run(k, v); }
function normalizeToUTC(ts) { if (!ts) return ts; if (ts.endsWith("Z") || /[+-]\d{2}:\d{2}$/.test(ts)) return ts; return ts.replace(" ", "T") + "Z"; }

function authMiddleware(req, res, next) {
  const token = req.headers.authorization?.split(" ")[1];
  if (!token) return res.status(401).json({ success: false, message: "未提供认证信息" });
  try {
    const decoded = jwt.verify(token, JWT_SECRET);
    const user = db.prepare("SELECT last_login_at FROM users WHERE id = ?").get(decoded.userId);
    if (user && user.last_login_at && decoded.loginAt && user.last_login_at !== decoded.loginAt) return res.status(401).json({ success: false, message: "账号已在其他设备登录" });
    req.user = decoded; next();
  } catch(e) { res.status(401).json({ success: false, message: "认证失败" }); }
}
function adminMiddleware(req, res, next) { if (!req.user.isAdmin) return res.status(403).json({ success: false, message: "需要管理员权限" }); next(); }

/* Channel access check */
function canAccessChannel(userId, channelId) {
  const ch = db.prepare("SELECT * FROM channels WHERE id=?").get(channelId);
  if (!ch) return false;
  if (!ch.is_private) return true; /* Public channels are accessible to all */
  const user = db.prepare("SELECT is_admin FROM users WHERE id=?").get(userId);
  if (user && user.is_admin) return true; /* Admins can access all */
  const mem = db.prepare("SELECT role FROM channel_members WHERE channel_id=? AND user_id=?").get(channelId, userId);
  return !!mem;
}
function canWriteChannel(userId, channelId) {
  const ch = db.prepare("SELECT * FROM channels WHERE id=?").get(channelId);
  if (!ch) return false;
  if (!ch.is_private) return true;
  const user = db.prepare("SELECT is_admin FROM users WHERE id=?").get(userId);
  if (user && user.is_admin) return true;
  const mem = db.prepare("SELECT role FROM channel_members WHERE channel_id=? AND user_id=?").get(channelId, userId);
  if (!mem) return false;
  return mem.role !== 'viewer';
}

/* File upload configs */
const ALLOWED_EXT = [".jpg",".jpeg",".png",".gif",".webp",".bmp",".pdf",".doc",".docx",".xls",".xlsx",".ppt",".pptx",".txt",".csv",".zip",".rar",".7z",".mp3",".mp4",".mov"];
function fixFilename(file) { try { const raw=file.originalname; let h=false; for(let i=0;i<raw.length;i++){if(raw.charCodeAt(i)>127){h=true;break}} if(!h)return; const buf=Buffer.from(raw,"latin1"); const dec=buf.toString("utf8"); if(!dec.includes("\ufffd"))file.originalname=dec; } catch(e) {} }
const storage = multer.diskStorage({ destination:(r,f,cb)=>cb(null,UPLOAD_DIR), filename:(r,f,cb)=>{fixFilename(f);cb(null,uuidv4()+path.extname(f.originalname).toLowerCase())} });
function fileFilter(r,f,cb){fixFilename(f);const ext=path.extname(f.originalname).toLowerCase();cb(ALLOWED_EXT.includes(ext)?null:new Error("不支持的文件类型"),ALLOWED_EXT.includes(ext))}
const upload = multer({storage,limits:{fileSize:50*1024*1024},fileFilter,defParamCharset:"utf8"});
const avatarStorage = multer.diskStorage({ destination:(r,f,cb)=>cb(null,AVATAR_DIR), filename:(r,f,cb)=>{fixFilename(f);cb(null,uuidv4()+path.extname(f.originalname).toLowerCase())} });
const uploadAvatar = multer({storage:avatarStorage,limits:{fileSize:5*1024*1024},fileFilter:(r,f,cb)=>{fixFilename(f);const ext=path.extname(f.originalname).toLowerCase();cb([".jpg",".jpeg",".png",".gif",".webp"].includes(ext)?null:new Error("头像只支持图片"),[".jpg",".jpeg",".png",".gif",".webp"].includes(ext))},defParamCharset:"utf8"});
const bgStorage = multer.diskStorage({ destination:(r,f,cb)=>cb(null,BG_DIR), filename:(r,f,cb)=>{fixFilename(f);cb(null,uuidv4()+path.extname(f.originalname).toLowerCase())} });
const uploadBg = multer({storage:bgStorage,limits:{fileSize:100*1024*1024},fileFilter:(r,f,cb)=>{fixFilename(f);const ext=path.extname(f.originalname).toLowerCase();const ok=[".jpg",".jpeg",".png",".gif",".webp",".bmp",".svg",".mp4",".mov",".webm",".m4v"].includes(ext);cb(ok?null:new Error("背景只支持图片或视频"),ok)},defParamCharset:"utf8"});

/* ===== Push ===== */
app.get("/api/push/vapid-key", (req, res) => { res.json({ publicKey: vapidKeys.publicKey }); });
app.post("/api/push/subscribe", authMiddleware, (req, res) => { const { subscription, oldEndpoint } = req.body; if (!subscription || !subscription.endpoint || !subscription.keys) return res.json({ success: false, message: "无效数据" }); try { if (oldEndpoint) db.prepare("DELETE FROM push_subscriptions WHERE endpoint=?").run(oldEndpoint); db.prepare("INSERT OR REPLACE INTO push_subscriptions (user_id,endpoint,keys_p256dh,keys_auth) VALUES (?,?,?,?)").run(req.user.userId, subscription.endpoint, subscription.keys.p256dh, subscription.keys.auth); res.json({ success: true }); } catch(e) { res.json({ success: false, message: "保存失败" }); } });
app.post("/api/push/unsubscribe", authMiddleware, (req, res) => { const { endpoint } = req.body; if (endpoint) db.prepare("DELETE FROM push_subscriptions WHERE endpoint=?").run(endpoint); res.json({ success: true }); });
app.post("/api/push/renew", (req, res) => { const { subscription, oldEndpoint } = req.body; if (!subscription || !subscription.endpoint || !subscription.keys || !oldEndpoint) return res.json({ success: false }); try { const old = db.prepare("SELECT user_id FROM push_subscriptions WHERE endpoint=?").get(oldEndpoint); if (!old) return res.json({ success: false }); db.prepare("DELETE FROM push_subscriptions WHERE endpoint=?").run(oldEndpoint); db.prepare("INSERT OR REPLACE INTO push_subscriptions (user_id,endpoint,keys_p256dh,keys_auth) VALUES (?,?,?,?)").run(old.user_id, subscription.endpoint, subscription.keys.p256dh, subscription.keys.auth); res.json({ success: true }); } catch(e) { res.json({ success: false }); } });

function sendPushToOthers(senderUserId, senderName, messageText, channelId) {
  /* Only push to users who have access to the channel */
  const ch = db.prepare("SELECT * FROM channels WHERE id=?").get(channelId);
  let subs;
  if (ch && ch.is_private) {
    subs = db.prepare("SELECT ps.* FROM push_subscriptions ps JOIN channel_members cm ON ps.user_id = cm.user_id WHERE cm.channel_id = ? AND ps.user_id != ?").all(channelId, senderUserId);
  } else {
    subs = db.prepare("SELECT * FROM push_subscriptions WHERE user_id != ?").all(senderUserId);
  }
  const chatTitle = getSetting("chat_title") || "TeamChat";
  const body = messageText.replace(/<[^>]*>/g, '');
  const payload = JSON.stringify({ title: chatTitle, body: senderName + ": " + (body.length > 100 ? body.substring(0, 100) + "..." : body), icon: "/images/icon-192.png", data: { url: "/" } });
  for (const sub of subs) {
    webpush.sendNotification({ endpoint: sub.endpoint, keys: { p256dh: sub.keys_p256dh, auth: sub.keys_auth } }, payload, { TTL: 86400, urgency: "high", topic: "teamchat-msg" }).catch(err => { if (err.statusCode === 410 || err.statusCode === 404) db.prepare("DELETE FROM push_subscriptions WHERE id=?").run(sub.id); });
  }
}

/* ===== Auth Routes ===== */
app.post("/api/login", async (req, res) => {
  const { username, password } = req.body; if (!username || !password) return res.json({ success: false, message: "缺少参数" });
  const user = db.prepare("SELECT * FROM users WHERE username=?").get(username);
  if (!user || !(await bcrypt.compare(password, user.password))) return res.json({ success: false, message: "用户名或密码错误" });
  const loginAt = new Date().toISOString();
  db.prepare("UPDATE users SET last_login_at=? WHERE id=?").run(loginAt, user.id);
  const token = jwt.sign({ userId: user.id, username: user.username, isAdmin: user.is_admin, loginAt }, JWT_SECRET, { expiresIn: "7d" });
  /* Kick existing sessions */
  for (const [sid, info] of onlineUsers.entries()) { if (info.userId === user.id) { const s = io.sockets.sockets.get(sid); if (s) { s.emit("kicked", { message: "您的账号已在其他设备登录" }); s.disconnect(true); } } }
  /* Ensure user is in default channel */
  const defCh = db.prepare("SELECT id FROM channels WHERE is_default=1").get();
  if (defCh) db.prepare("INSERT OR IGNORE INTO channel_members (channel_id, user_id, role) VALUES (?, ?, 'member')").run(defCh.id, user.id);
  res.json({ success: true, token, username: user.username, userId: user.id, nickname: user.nickname, avatar: user.avatar, isAdmin: !!user.is_admin });
});

app.post("/api/public-register", async (req, res) => {
  if (getSetting("registration_open") !== "1") return res.json({ success: false, message: "注册通道已关闭" });
  const { username, password, nickname } = req.body; if (!username || !password) return res.json({ success: false, message: "缺少参数" });
  if (!/^[a-zA-Z0-9_.\-]+$/.test(username)) return res.json({ success: false, message: "用户名只允许字母数字下划线" });
  if (username.length < 2 || username.length > 20) return res.json({ success: false, message: "用户名需 2-20 字符" });
  if (password.length < 6) return res.json({ success: false, message: "密码不能小于6位" });
  try {
    const r = db.prepare("INSERT INTO users (username,password,nickname) VALUES (?,?,?)").run(username, await bcrypt.hash(password, 10), nickname || username);
    /* Add to all public channels */
    const pubChs = db.prepare("SELECT id FROM channels WHERE is_private=0").all();
    pubChs.forEach(ch => db.prepare("INSERT OR IGNORE INTO channel_members (channel_id,user_id,role) VALUES (?,?,'member')").run(ch.id, r.lastInsertRowid));
    res.json({ success: true });
  } catch(e) { res.json({ success: false, message: "用户名已存在" }); }
});

app.post("/api/change-password", authMiddleware, async (req, res) => {
  const { oldPassword, newPassword } = req.body; if (!newPassword || newPassword.length < 6) return res.json({ success: false, message: "新密码不能小于6位" });
  const user = db.prepare("SELECT password FROM users WHERE id=?").get(req.user.userId); if (!user) return res.json({ success: false, message: "用户不存在" });
  if (!(await bcrypt.compare(oldPassword, user.password))) return res.json({ success: false, message: "原密码错误" });
  db.prepare("UPDATE users SET password=? WHERE id=?").run(await bcrypt.hash(newPassword, 10), req.user.userId); res.json({ success: true });
});

/* ===== Channel Routes ===== */
app.get("/api/channels", authMiddleware, (req, res) => {
  /* Return channels the user can access */
  const user = db.prepare("SELECT is_admin FROM users WHERE id=?").get(req.user.userId);
  let channels;
  if (user && user.is_admin) {
    channels = db.prepare("SELECT c.*, (SELECT COUNT(*) FROM channel_members WHERE channel_id=c.id) as _memberCount FROM channels c ORDER BY c.is_default DESC, c.id ASC").all();
  } else {
    channels = db.prepare(`SELECT c.*, (SELECT COUNT(*) FROM channel_members WHERE channel_id=c.id) as _memberCount FROM channels c WHERE c.is_private = 0 OR c.id IN (SELECT channel_id FROM channel_members WHERE user_id = ?) ORDER BY c.is_default DESC, c.id ASC`).all(req.user.userId);
  }
  res.json(channels);
});

app.get("/api/admin/channels", authMiddleware, adminMiddleware, (req, res) => {
  res.json(db.prepare("SELECT c.*, (SELECT COUNT(*) FROM channel_members WHERE channel_id=c.id) as _memberCount FROM channels c ORDER BY c.is_default DESC, c.id ASC").all());
});

app.post("/api/channels", authMiddleware, adminMiddleware, (req, res) => {
  const { name, description, is_private } = req.body; if (!name) return res.json({ success: false, message: "缺少频道名" });
  try {
    const r = db.prepare("INSERT INTO channels (name, description, is_private, created_by) VALUES (?, ?, ?, ?)").run(name, description || '', is_private ? 1 : 0, req.user.userId);
    const chId = r.lastInsertRowid;
    /* Add creator as owner */
    db.prepare("INSERT INTO channel_members (channel_id, user_id, role) VALUES (?, ?, 'owner')").run(chId, req.user.userId);
    /* For public channels, add all users */
    if (!is_private) { db.prepare("SELECT id FROM users").all().forEach(u => { if (u.id !== req.user.userId) db.prepare("INSERT OR IGNORE INTO channel_members (channel_id,user_id,role) VALUES (?,?,'member')").run(chId, u.id); }); }
    const ch = db.prepare("SELECT * FROM channels WHERE id=?").get(chId);
    io.emit("channelCreated", ch);
    res.json({ success: true, channel: ch });
  } catch(e) { res.json({ success: false, message: "创建失败" }); }
});

app.delete("/api/channels/:id", authMiddleware, adminMiddleware, (req, res) => {
  const ch = db.prepare("SELECT * FROM channels WHERE id=?").get(req.params.id);
  if (!ch) return res.json({ success: false, message: "频道不存在" });
  if (ch.is_default) return res.json({ success: false, message: "不能删除默认频道" });
  db.prepare("DELETE FROM messages WHERE channel_id=?").run(ch.id);
  db.prepare("DELETE FROM channel_members WHERE channel_id=?").run(ch.id);
  db.prepare("DELETE FROM channels WHERE id=?").run(ch.id);
  io.emit("channelDeleted", { channelId: ch.id });
  res.json({ success: true });
});

app.get("/api/channels/:id/members", authMiddleware, (req, res) => {
  res.json(db.prepare("SELECT cm.*, u.username, u.nickname, u.avatar FROM channel_members cm JOIN users u ON cm.user_id = u.id WHERE cm.channel_id = ?").all(req.params.id));
});

app.post("/api/channels/:id/members", authMiddleware, adminMiddleware, (req, res) => {
  const { username, role } = req.body; const user = db.prepare("SELECT id FROM users WHERE username=?").get(username);
  if (!user) return res.json({ success: false, message: "用户不存在" });
  try { db.prepare("INSERT OR REPLACE INTO channel_members (channel_id, user_id, role) VALUES (?, ?, ?)").run(req.params.id, user.id, role || 'member'); io.emit("membershipChanged", {}); res.json({ success: true }); } catch(e) { res.json({ success: false, message: "添加失败" }); }
});

app.put("/api/channels/:id/members/:userId", authMiddleware, adminMiddleware, (req, res) => {
  const { role } = req.body;
  db.prepare("UPDATE channel_members SET role=? WHERE channel_id=? AND user_id=?").run(role, req.params.id, req.params.userId);
  io.emit("membershipChanged", {}); res.json({ success: true });
});

app.delete("/api/channels/:id/members/:userId", authMiddleware, adminMiddleware, (req, res) => {
  db.prepare("DELETE FROM channel_members WHERE channel_id=? AND user_id=?").run(req.params.id, req.params.userId);
  io.emit("membershipChanged", {}); res.json({ success: true });
});

/* ===== Message Routes ===== */
app.get("/api/messages", authMiddleware, (req, res) => {
  const { before, limit = 50, channelId } = req.query;
  const chId = parseInt(channelId) || 1;
  if (!canAccessChannel(req.user.userId, chId)) return res.status(403).json({ success: false, message: "无权访问此频道" });
  const pl = Math.min(Math.max(parseInt(limit) || 50, 1), 200);
  let sql = "SELECT m.*,u.nickname,u.avatar FROM messages m JOIN users u ON m.user_id=u.id WHERE m.channel_id=?"; const params = [chId];
  if (before) { const pb = parseInt(before); if (!isNaN(pb) && pb > 0) { sql += " AND m.id < ?"; params.push(pb); } }
  sql += " ORDER BY m.id DESC LIMIT ?"; params.push(pl);
  res.json(db.prepare(sql).all(...params).reverse().map(m => { m.created_at = normalizeToUTC(m.created_at); return m; }));
});

app.post("/api/upload", authMiddleware, upload.single("file"), (req, res) => {
  if (!req.file) return res.json({ success: false, message: "上传失败" });
  const channelId = parseInt(req.body.channelId) || 1;
  if (!canWriteChannel(req.user.userId, channelId)) return res.json({ success: false, message: "无权在此频道发送" });
  const type = req.file.mimetype.startsWith("image/") ? "image" : "file";
  const user = db.prepare("SELECT username,nickname,avatar FROM users WHERE id=?").get(req.user.userId);
  if (!user) return res.json({ success: false, message: "用户不存在" });
  const nowUtc = new Date().toISOString();
  const result = db.prepare("INSERT INTO messages (user_id,username,content,type,file_name,file_path,file_size,channel_id,created_at) VALUES (?,?,?,?,?,?,?,?,?)").run(req.user.userId, user.username, "", type, req.file.originalname, req.file.filename, req.file.size, channelId, nowUtc);
  const message = { id: result.lastInsertRowid, username: user.username, nickname: user.nickname, avatar: user.avatar, content: "", type, file_name: req.file.originalname, file_path: req.file.filename, file_size: req.file.size, channel_id: channelId, created_at: nowUtc };
  io.emit("newMessage", message);
  sendPushToOthers(req.user.userId, user.nickname || user.username, type === "image" ? "[图片]" : "[文件] " + req.file.originalname, channelId);
  res.json({ success: true });
});

app.post("/api/upload-avatar", authMiddleware, uploadAvatar.single("avatar"), (req, res) => { if (!req.file) return res.json({ success: false }); db.prepare("UPDATE users SET avatar=? WHERE id=?").run(req.file.filename, req.user.userId); res.json({ success: true, avatar: req.file.filename }); });
app.post("/api/upload-bg", authMiddleware, adminMiddleware, uploadBg.single("bg"), (req, res) => { if (!req.file) return res.json({ success: false }); res.json({ success: true, filename: req.file.filename }); });

/* ===== Admin Routes ===== */
app.get("/api/settings/notice", (req, res) => { res.json({ content: getSetting("pinned_notice"), enabled: getSetting("pinned_notice_enabled") === "1" }); });
app.post("/api/settings/notice", authMiddleware, adminMiddleware, (req, res) => { const { content, enabled } = req.body; if (typeof content === "string") setSetting("pinned_notice", content.substring(0, 2000)); if (typeof enabled === "boolean") setSetting("pinned_notice_enabled", enabled ? "1" : "0"); const d = { content: getSetting("pinned_notice"), enabled: getSetting("pinned_notice_enabled") === "1" }; io.emit("noticeChanged", d); res.json({ success: true }); });

app.get("/api/settings/registration", (req, res) => { res.json({ open: getSetting("registration_open") === "1" }); });
app.post("/api/settings/registration", authMiddleware, adminMiddleware, (req, res) => { const { open } = req.body; setSetting("registration_open", open ? "1" : "0"); io.emit("registrationChanged", { open: !!open }); res.json({ success: true, open: !!open }); });

const VALID_TZ = ["Asia/Shanghai","Asia/Tokyo","Asia/Singapore","Asia/Kolkata","Asia/Dubai","Europe/London","Europe/Paris","Europe/Moscow","America/New_York","America/Chicago","America/Denver","America/Los_Angeles","Pacific/Auckland","Australia/Sydney"];
app.get("/api/settings/timezone", authMiddleware, (req, res) => { res.json({ timezone: getSetting("timezone"), serverTimezone: Intl.DateTimeFormat().resolvedOptions().timeZone }); });
app.post("/api/settings/timezone", authMiddleware, adminMiddleware, (req, res) => { const { timezone } = req.body; if (!timezone || !VALID_TZ.includes(timezone)) return res.json({ success: false, message: "不支持的时区" }); setSetting("timezone", timezone); io.emit("timezoneChanged", { timezone }); res.json({ success: true }); });

app.get("/api/settings/appearance", (req, res) => { const keys = ["login_title","chat_title","send_text","send_color","bg_type","bg_color","bg_image","bg_mode","bg_video","bg_video_url","bg_video_mode","timezone","login_bg_type","login_bg_color1","login_bg_color2","login_bg_image","login_bg_mode","login_bg_video","login_bg_video_url","login_bg_video_mode"]; const r = {}; keys.forEach(k => { r[k] = getSetting(k); }); res.json(r); });
app.post("/api/settings/appearance", authMiddleware, adminMiddleware, (req, res) => {
  const body = req.body; const allowed = ["login_title","chat_title","send_text","send_color","bg_type","bg_color","bg_image","bg_mode","bg_video","bg_video_url","bg_video_mode","login_bg_type","login_bg_color1","login_bg_color2","login_bg_image","login_bg_mode","login_bg_video","login_bg_video_url","login_bg_video_mode"];
  const upd = db.prepare("INSERT OR REPLACE INTO settings (key,value,updated_at) VALUES (?,?,datetime('now'))");
  db.transaction(() => { for (const k of allowed) { if (body[k] !== undefined) upd.run(k, String(body[k])); } })();
  const bd = {}; [...allowed, "timezone"].forEach(k => { bd[k] = getSetting(k); }); io.emit("appearanceChanged", bd); res.json({ success: true });
});

app.post("/api/register", authMiddleware, adminMiddleware, async (req, res) => {
  const { username, password, nickname } = req.body; if (!username || !password) return res.json({ success: false, message: "缺少参数" });
  if (!/^[a-zA-Z0-9_.\-]+$/.test(username)) return res.json({ success: false, message: "用户名非法" }); if (password.length < 6) return res.json({ success: false, message: "密码不能小于6位" });
  try {
    const r = db.prepare("INSERT INTO users (username,password,nickname) VALUES (?,?,?)").run(username, await bcrypt.hash(password, 10), nickname || username);
    /* Add to all public channels */
    db.prepare("SELECT id FROM channels WHERE is_private=0").all().forEach(ch => db.prepare("INSERT OR IGNORE INTO channel_members (channel_id,user_id,role) VALUES (?,?,'member')").run(ch.id, r.lastInsertRowid));
    res.json({ success: true });
  } catch(e) { res.json({ success: false, message: "用户名已存在" }); }
});

app.get("/api/users", authMiddleware, adminMiddleware, (req, res) => { res.json(db.prepare("SELECT id,username,nickname,avatar,is_admin,created_at FROM users").all()); });
app.post("/api/users", authMiddleware, adminMiddleware, async (req, res) => {
  const { username, password, nickname } = req.body; if (!username || !password) return res.json({ success: false, message: "缺少参数" });
  if (!/^[a-zA-Z0-9_.\-]+$/.test(username)) return res.json({ success: false, message: "用户名非法" }); if (password.length < 6) return res.json({ success: false, message: "密码不能小于6位" });
  try {
    const r = db.prepare("INSERT INTO users (username,password,nickname) VALUES (?,?,?)").run(username, await bcrypt.hash(password, 10), nickname || username);
    db.prepare("SELECT id FROM channels WHERE is_private=0").all().forEach(ch => db.prepare("INSERT OR IGNORE INTO channel_members (channel_id,user_id,role) VALUES (?,?,'member')").run(ch.id, r.lastInsertRowid));
    res.json({ success: true });
  } catch(e) { res.json({ success: false, message: "用户名已存在" }); }
});
app.delete("/api/users/:username", authMiddleware, adminMiddleware, (req, res) => { const t = db.prepare("SELECT is_admin FROM users WHERE username=?").get(req.params.username); if (!t) return res.json({ success: false, message: "用户不存在" }); if (t.is_admin) return res.json({ success: false, message: "不能删除管理员" }); db.prepare("DELETE FROM users WHERE username=?").run(req.params.username); res.json({ success: true }); });
app.post("/api/admin/reset-password", authMiddleware, adminMiddleware, async (req, res) => { const { username, newPassword } = req.body; if (!username || !newPassword || newPassword.length < 6) return res.json({ success: false, message: "参数不足" }); db.prepare("UPDATE users SET password=? WHERE username=?").run(await bcrypt.hash(newPassword, 10), username); res.json({ success: true }); });

app.get("/api/backup", authMiddleware, adminMiddleware, (req, res) => { const { startDate, endDate } = req.query; let sql = "SELECT m.*,u.username as user_username,u.nickname,u.avatar FROM messages m JOIN users u ON m.user_id=u.id"; const p = []; if (startDate && endDate) { sql += " WHERE DATE(m.created_at) BETWEEN ? AND ?"; p.push(startDate, endDate); } sql += " ORDER BY m.id"; res.json({ messages: db.prepare(sql).all(...p).map(m => { m.created_at = normalizeToUTC(m.created_at); return m; }) }); });
app.post("/api/restore", authMiddleware, adminMiddleware, (req, res) => { const { messages } = req.body; if (!Array.isArray(messages)) return res.json({ success: false, message: "格式错误" }); let count = 0; const ins = db.prepare("INSERT INTO messages (user_id,username,content,type,file_name,file_path,file_size,channel_id,created_at) VALUES (?,?,?,?,?,?,?,?,?)"); try { db.transaction(ms => { for (const m of ms) { const u = db.prepare("SELECT id FROM users WHERE username=?").get(m.username); if (u) { ins.run(u.id, m.username, m.content, m.type, m.file_name, m.file_path, m.file_size, m.channel_id || 1, m.created_at); count++; } } })(messages); res.json({ success: true, count }); } catch(e) { res.json({ success: false, message: "恢复失败" }); } });
app.delete("/api/messages", authMiddleware, adminMiddleware, (req, res) => { const { startDate, endDate } = req.body; if (!startDate || !endDate) return res.json({ success: false, message: "请提供日期" }); res.json({ success: true, deleted: db.prepare("DELETE FROM messages WHERE DATE(created_at) BETWEEN ? AND ?").run(startDate, endDate).changes }); });

/* SPA fallback — serve index.html for any unmatched route */
app.get("*", (req, res) => { if (!req.path.startsWith("/api/")) res.sendFile(path.join(__dirname, "public", "index.html")); else res.status(404).json({ error: "Not found" }); });

/* ===== Socket.IO ===== */
const onlineUsers = new Map(), userSocketMap = new Map();
io.use((socket, next) => {
  const token = socket.handshake.auth.token; if (!token) return next(new Error("未提供认证信息"));
  try { const d = jwt.verify(token, JWT_SECRET); const u = db.prepare("SELECT last_login_at FROM users WHERE id=?").get(d.userId); if (u && u.last_login_at && d.loginAt && u.last_login_at !== d.loginAt) return next(new Error("认证失败")); socket.user = d; next(); } catch(e) { next(new Error("认证失败")); }
});

io.on("connection", (socket) => {
  const userId = socket.user.userId;
  const oldSid = userSocketMap.get(userId);
  if (oldSid && oldSid !== socket.id) { const s = io.sockets.sockets.get(oldSid); if (s) { s.emit("kicked", { message: "您的账号已在其他设备登录" }); s.disconnect(true); } onlineUsers.delete(oldSid); }
  userSocketMap.set(userId, socket.id);
  const ui = db.prepare("SELECT nickname,avatar FROM users WHERE id=?").get(userId);
  onlineUsers.set(socket.id, { username: socket.user.username, userId, nickname: ui ? ui.nickname : socket.user.username, avatar: ui ? ui.avatar : null });
  broadcastOnlineUsers();

  /* Join channel rooms the user has access to */
  const userChannels = db.prepare("SELECT channel_id FROM channel_members WHERE user_id=?").all(userId);
  userChannels.forEach(c => socket.join("ch:" + c.channel_id));
  /* Also join public channels */
  db.prepare("SELECT id FROM channels WHERE is_private=0").all().forEach(c => socket.join("ch:" + c.id));

  socket.on("switchChannel", (data) => {
    if (data && data.channelId && canAccessChannel(userId, data.channelId)) {
      socket.join("ch:" + data.channelId);
    }
  });

  socket.on("sendMessage", (data) => {
    if (!data || typeof data !== "object") return;
    const { content, replyTo, channelId } = data;
    if (!content || typeof content !== "string" || content.trim().length === 0) return;
    const chId = parseInt(channelId) || 1;
    if (!canWriteChannel(userId, chId)) return;
    let trimmed = content.trim().substring(0, 10000);
    const isChain = trimmed.startsWith("[CHAIN]");
    if (isChain) { try { const cd = JSON.parse(trimmed.substring(7)); if (!cd.type || cd.type !== "chain" || !cd.topic) return; } catch(e) { return; } }
    else {
      trimmed = trimmed.replace(/<(script|style|iframe|object|embed|link|meta)[^>]*>[\s\S]*?<\/\1>/gi, '');
      trimmed = trimmed.replace(/<(script|style|iframe|object|embed|link|meta)[^>]*\/?>/gi, '');
      trimmed = trimmed.replace(/\s+on[a-z]+\s*=\s*["'][^"']*["']/gi, '');
      trimmed = trimmed.replace(/\s+on[a-z]+\s*=\s*[^\s>]+/gi, '');
      trimmed = trimmed.replace(/href\s*=\s*["']javascript:[^"']*["']/gi, 'href="#"');
      if (!trimmed.replace(/<[^>]*>/g, '').trim() && !/<br\s*\/?>/i.test(trimmed)) return;
    }
    const safeReplyTo = (Number.isInteger(replyTo) && replyTo > 0) ? replyTo : null;
    const nowUtc = new Date().toISOString();
    const result = db.prepare("INSERT INTO messages (user_id,username,content,reply_to,channel_id,created_at) VALUES (?,?,?,?,?,?)").run(userId, socket.user.username, trimmed, safeReplyTo, chId, nowUtc);
    const user = db.prepare("SELECT nickname,avatar FROM users WHERE id=?").get(userId);
    const message = { id: result.lastInsertRowid, username: socket.user.username, nickname: user ? user.nickname : socket.user.username, avatar: user ? user.avatar : null, content: trimmed, type: "text", reply_to: safeReplyTo, channel_id: chId, created_at: nowUtc };
    io.emit("newMessage", message);
    let pushText;
    if (isChain) { try { pushText = "[接龙] " + JSON.parse(trimmed.substring(7)).topic; } catch(e) { pushText = "[接龙]"; } }
    else pushText = trimmed.replace(/<[^>]*>/g, '').substring(0, 200);
    sendPushToOthers(userId, user ? user.nickname : socket.user.username, pushText, chId);
  });

  socket.on("updateChain", (data) => {
    if (!data || typeof data !== "object") return;
    const { messageId, content, channelId } = data;
    if (!messageId || !content || typeof content !== "string" || !content.startsWith("[CHAIN]")) return;
    let chainData; try { chainData = JSON.parse(content.substring(7)); if (!chainData.type || chainData.type !== "chain") return; } catch(e) { return; }
    const origMsg = db.prepare("SELECT id,content,channel_id FROM messages WHERE id=?").get(messageId);
    if (!origMsg || !origMsg.content.startsWith("[CHAIN]")) return;
    let origData; try { origData = JSON.parse(origMsg.content.substring(7)); } catch(e) { return; }
    const username = socket.user.username;
    if (origData.participants && origData.participants.some(p => p.username === username)) return;
    const user = db.prepare("SELECT nickname FROM users WHERE id=?").get(userId);
    const myName = user ? user.nickname : username;
    if (!origData.participants) origData.participants = [];
    origData.participants.push({ seq: origData.participants.length + 1, username, name: myName, text: "" });
    const newContent = "[CHAIN]" + JSON.stringify(origData);
    db.prepare("UPDATE messages SET content=? WHERE id=?").run(newContent, messageId);
    io.emit("chainUpdated", { messageId, content: newContent, channelId: origMsg.channel_id });
    sendPushToOthers(userId, myName, "[接龙] " + myName + " 参与了: " + origData.topic, origMsg.channel_id);
  });

  socket.on("disconnect", () => { if (userSocketMap.get(userId) === socket.id) userSocketMap.delete(userId); onlineUsers.delete(socket.id); broadcastOnlineUsers(); });
});

function broadcastOnlineUsers() { io.emit("onlineUsers", [...new Map(Array.from(onlineUsers.values()).map(u => [u.username, u])).values()]); }
process.on("SIGTERM", () => { io.close(); server.close(() => { db.close(); process.exit(0); }); setTimeout(() => process.exit(1), 5000); });
server.listen(PORT, () => { console.log("TeamChat v9 服务器运行在端口 " + PORT); });
SERVEREOF

    sed -i "s/__PORT_PLACEHOLDER__/${PORT}/" "$APP_DIR/server.js"
    chmod -R 755 "$APP_DIR"
    chmod 755 "$APP_DIR/uploads" "$APP_DIR/avatars" "$APP_DIR/backgrounds" 2>/dev/null || true

    echo -e "${GREEN}✅ 应用程序文件写入完成${NC}"
}


install_npm_deps() {
    echo -e "\n${YELLOW}阶段 4/6: 正在安装 Node.js 依赖...${NC}"
    cd "$APP_DIR"
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
CREATE TABLE IF NOT EXISTS channels (id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT NOT NULL,description TEXT DEFAULT "",is_private INTEGER DEFAULT 0,is_default INTEGER DEFAULT 0,created_by INTEGER,created_at DATETIME DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE IF NOT EXISTS channel_members (id INTEGER PRIMARY KEY AUTOINCREMENT,channel_id INTEGER NOT NULL,user_id INTEGER NOT NULL,role TEXT DEFAULT "member",created_at DATETIME DEFAULT CURRENT_TIMESTAMP,UNIQUE(channel_id,user_id),FOREIGN KEY (channel_id) REFERENCES channels(id) ON DELETE CASCADE,FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE);
CREATE TABLE IF NOT EXISTS messages (id INTEGER PRIMARY KEY AUTOINCREMENT,user_id INTEGER NOT NULL,username TEXT NOT NULL,content TEXT,type TEXT DEFAULT "text",file_name TEXT,file_path TEXT,file_size INTEGER,reply_to INTEGER,channel_id INTEGER DEFAULT 1,created_at DATETIME DEFAULT CURRENT_TIMESTAMP,FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE);
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY,value TEXT NOT NULL,updated_at DATETIME DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE IF NOT EXISTS push_subscriptions (id INTEGER PRIMARY KEY AUTOINCREMENT,user_id INTEGER NOT NULL,endpoint TEXT UNIQUE NOT NULL,keys_p256dh TEXT NOT NULL,keys_auth TEXT NOT NULL,created_at DATETIME DEFAULT CURRENT_TIMESTAMP,FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE);`);
const defs={timezone:"Asia/Shanghai",login_title:"团队聊天室",chat_title:"TeamChat",send_text:"发送",send_color:"#667eea",bg_type:"color",bg_color:"#f0f2f5",bg_image:"",bg_mode:"cover",bg_video:"",bg_video_url:"",bg_video_mode:"cover",pinned_notice:"",pinned_notice_enabled:"0",registration_open:"0",login_bg_type:"gradient",login_bg_color1:"#667eea",login_bg_color2:"#764ba2",login_bg_image:"",login_bg_mode:"cover",login_bg_video:"",login_bg_video_url:"",login_bg_video_mode:"cover"};
const ins=db.prepare("INSERT OR IGNORE INTO settings (key,value) VALUES (?,?)");for(const[k,v] of Object.entries(defs))ins.run(k,v);
// Create admin
const au=process.env.ADMIN_USER_ENV,ap=process.env.ADMIN_PASS_ENV,h=bcrypt.hashSync(ap,10);
let adminId;
try{const r=db.prepare("INSERT INTO users (username,password,is_admin) VALUES (?,?,1)").run(au,h);adminId=r.lastInsertRowid;console.log("✅ 管理员已创建")}catch(e){db.prepare("UPDATE users SET password=?,is_admin=1 WHERE username=?").run(h,au);const u=db.prepare("SELECT id FROM users WHERE username=?").get(au);adminId=u?u.id:1;console.log("✅ 管理员密码已重置")}
// Ensure default channel
const defCh=db.prepare("SELECT id FROM channels WHERE is_default=1").get();
if(!defCh){const r=db.prepare("INSERT INTO channels (name,description,is_default,is_private) VALUES (\"综合频道\",\"默认公开频道\",1,0)").run();const chId=r.lastInsertRowid;db.prepare("INSERT OR IGNORE INTO channel_members (channel_id,user_id,role) VALUES (?,?,\"owner\")").run(chId,adminId);console.log("✅ 默认频道已创建")}
else{db.prepare("INSERT OR IGNORE INTO channel_members (channel_id,user_id,role) VALUES (?,?,\"owner\")").run(defCh.id,adminId)}
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

find_cert_path() {
    # 查找域名对应的 Let's Encrypt 证书目录（处理 Certbot 的 -0001 等后缀）
    local domain="$1"
    # 优先精确匹配
    if [ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ] && [ -f "/etc/letsencrypt/live/${domain}/privkey.pem" ]; then
        echo "/etc/letsencrypt/live/${domain}"; return 0
    fi
    # 检查带后缀的目录（如 domain-0001, domain-0002）
    local latest_dir=""
    for dir in /etc/letsencrypt/live/${domain}-*; do
        [ -d "$dir" ] || continue
        [ -f "$dir/fullchain.pem" ] && [ -f "$dir/privkey.pem" ] || continue
        latest_dir="$dir"
    done
    if [ -n "$latest_dir" ]; then
        echo "$latest_dir"; return 0
    fi
    return 1
}

detect_existing_ssl() {
    local domain="$1"
    # 使用 find_cert_path 检查证书（含 -0001 等后缀目录）
    if find_cert_path "$domain" >/dev/null 2>&1; then
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
    # 优先使用 server_name（真实域名），避免从证书路径提取到 -0001 后缀
    if [ -f /etc/nginx/conf.d/teamchat.conf ]; then
        local d
        d=$(grep -oP 'server_name\s+\K[^;]+' /etc/nginx/conf.d/teamchat.conf 2>/dev/null | head -1 | awk '{print $1}')
        if [ -n "$d" ] && [ "$d" != "_" ]; then echo "$d"; return 0; fi
        # 回退到证书路径，但去掉 Certbot 的 -NNNN 后缀
        d=$(grep -oP 'ssl_certificate\s+/etc/letsencrypt/live/\K[^/]+' /etc/nginx/conf.d/teamchat.conf 2>/dev/null | head -1)
        if [ -n "$d" ]; then
            d=$(echo "$d" | sed 's/-[0-9]\{4\}$//')
            echo "$d"; return 0
        fi
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
        local cert_dir
        cert_dir=$(find_cert_path "$domain" 2>/dev/null)
        if [ -n "$cert_dir" ]; then
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
    ssl_certificate ${cert_dir}/fullchain.pem;
    ssl_certificate_key ${cert_dir}/privkey.pem;
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
        if find_cert_path "$INST_DOMAIN" >/dev/null 2>&1; then
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
        # 检查是否有现有证书可复用（含 Certbot -0001 等后缀目录）
        local inst_cert_dir
        inst_cert_dir=$(find_cert_path "$INST_DOMAIN" 2>/dev/null)
        if [ -n "$inst_cert_dir" ]; then
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
    ssl_certificate ${inst_cert_dir}/fullchain.pem;
    ssl_certificate_key ${inst_cert_dir}/privkey.pem;
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
CREATE TABLE IF NOT EXISTS channels (id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT NOT NULL,description TEXT DEFAULT "",is_private INTEGER DEFAULT 0,is_default INTEGER DEFAULT 0,created_by INTEGER,created_at DATETIME DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE IF NOT EXISTS channel_members (id INTEGER PRIMARY KEY AUTOINCREMENT,channel_id INTEGER NOT NULL,user_id INTEGER NOT NULL,role TEXT DEFAULT "member",created_at DATETIME DEFAULT CURRENT_TIMESTAMP,UNIQUE(channel_id,user_id),FOREIGN KEY (channel_id) REFERENCES channels(id) ON DELETE CASCADE,FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE);
CREATE TABLE IF NOT EXISTS messages (id INTEGER PRIMARY KEY AUTOINCREMENT,user_id INTEGER NOT NULL,username TEXT NOT NULL,content TEXT,type TEXT DEFAULT "text",file_name TEXT,file_path TEXT,file_size INTEGER,reply_to INTEGER,channel_id INTEGER DEFAULT 1,created_at DATETIME DEFAULT CURRENT_TIMESTAMP,FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE);
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY,value TEXT NOT NULL,updated_at DATETIME DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE IF NOT EXISTS push_subscriptions (id INTEGER PRIMARY KEY AUTOINCREMENT,user_id INTEGER NOT NULL,endpoint TEXT UNIQUE NOT NULL,keys_p256dh TEXT NOT NULL,keys_auth TEXT NOT NULL,created_at DATETIME DEFAULT CURRENT_TIMESTAMP,FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE);`);
try{db.exec("ALTER TABLE users ADD COLUMN is_admin INTEGER DEFAULT 0")}catch(e){}
try{db.exec("ALTER TABLE messages ADD COLUMN reply_to INTEGER")}catch(e){}
try{db.exec("ALTER TABLE users ADD COLUMN last_login_at TEXT")}catch(e){}
try{db.exec("ALTER TABLE messages ADD COLUMN channel_id INTEGER DEFAULT 1")}catch(e){}
// Ensure default channel
const defCh=db.prepare("SELECT id FROM channels WHERE is_default=1").get();
if(!defCh){const r=db.prepare("INSERT INTO channels (name,description,is_default,is_private) VALUES (\"综合频道\",\"默认公开频道\",1,0)").run();const chId=r.lastInsertRowid;
const users=db.prepare("SELECT id FROM users").all();users.forEach(u=>db.prepare("INSERT OR IGNORE INTO channel_members (channel_id,user_id,role) VALUES (?,?,\"member\")").run(chId,u.id));
db.prepare("UPDATE messages SET channel_id=? WHERE channel_id IS NULL OR channel_id=0").run(chId);console.log("✅ 默认频道已创建并迁移消息")}
else{const users=db.prepare("SELECT id FROM users").all();users.forEach(u=>db.prepare("INSERT OR IGNORE INTO channel_members (channel_id,user_id,role) VALUES (?,?,\"member\")").run(defCh.id,u.id))}
const defs={timezone:"Asia/Shanghai",login_title:"团队聊天室",chat_title:"TeamChat",send_text:"发送",send_color:"#667eea",bg_type:"color",bg_color:"#f0f2f5",bg_image:"",bg_mode:"cover",bg_video:"",bg_video_url:"",bg_video_mode:"cover",pinned_notice:"",pinned_notice_enabled:"0",registration_open:"0",login_bg_type:"gradient",login_bg_color1:"#667eea",login_bg_color2:"#764ba2",login_bg_image:"",login_bg_mode:"cover",login_bg_video:"",login_bg_video_url:"",login_bg_video_mode:"cover"};
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
