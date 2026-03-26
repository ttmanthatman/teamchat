<div align="center">

# 💬 TeamChat

**开箱即用的私有团队聊天室 · 一键部署 · 零依赖配置**

[![Shell Script](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnubash&logoColor=white)](#)
[![Node.js](https://img.shields.io/badge/Node.js-20.x-339933?logo=node.js&logoColor=white)](#)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](#license)
[![Version](https://img.shields.io/badge/Version-7.4-orange)](#更新日志)

一个 Shell 脚本，一行命令，在你自己的服务器上搭建一个功能完整的团队实时聊天室。

**不依赖任何第三方服务 · 数据完全自主可控 · 支持移动端 PWA**

</div>

---

## ✨ 功能亮点

### 聊天核心
- **富文本消息** — 加粗、斜体、下划线、删除线、文字颜色、背景高亮色
- **多行消息** — `Shift+Enter` 换行，`Enter` 发送
- **文件共享** — 支持图片、文档、压缩包等 20+ 种格式，最大 50MB
- **图片预览** — 聊天图片点击全屏查看
- **引用回复** — 右键消息即可引用
- **消息历史** — 无限滚动加载，支持按日期范围备份/还原/删除

### 移动端 & 推送
- **PWA 支持** — 添加到主屏幕，原生 App 体验
- **推送通知** — Android Chrome + iOS Safari (16.4+) 双平台支持
- **移动适配** — 响应式布局，iOS 键盘收起视口修复

### 管理后台
- **用户管理** — 添加/删除用户，批量导入导出（JSON）
- **外观定制** — 自定义登录标题、聊天室标题、发送按钮颜色/文字、聊天背景（纯色/图片）
- **置顶通知** — 全局置顶公告栏，可折叠展开
- **时区设置** — 支持 14 个时区，管理员统一切换
- **数据备份** — 按日期范围导出/还原聊天记录

### 安全 & 运维
- **JWT 认证** — 自动生成密钥，7 天有效期
- **单设备登录** — 同一账号仅允许一个设备在线，后登录踢掉前者
- **HTTPS 一键配置** — 集成 Let's Encrypt 自动申请证书 + 自动续期
- **富文本安全** — 三层 XSS 防护（客户端发送/服务端存储/客户端渲染）
- **PM2 守护** — 进程崩溃自动重启
- **Nginx 反代** — 生产级反向代理配置

---

## 🖥️ 系统要求

| 项目 | 要求 |
|------|------|
| 操作系统 | Ubuntu 20.04+ / Debian 10+ / CentOS 7+ / RHEL / Rocky / Alma |
| 内存 | ≥ 512MB |
| 磁盘 | ≥ 1GB 可用空间 |
| 权限 | root 或 sudo |
| 端口 | 默认 3000（可自定义），HTTPS 需开放 80/443 |

> Node.js、Nginx、PM2 等依赖由脚本自动安装，无需手动配置。

---

## 🚀 快速开始

### 一键安装

```bash
# 下载脚本
wget https://raw.githubusercontent.com/YOUR_USERNAME/teamchat/main/bushu-20.sh

# 赋予执行权限
chmod +x bushu-20.sh

# 运行（交互式菜单）
sudo ./bushu-20.sh
```

选择 `1. 安装/修复`，按提示输入管理员账号、密码和端口即可。

### 命令行模式

```bash
sudo ./bushu-20.sh --install    # 直接安装
sudo ./bushu-20.sh --ssl        # 配置 HTTPS
sudo ./bushu-20.sh --help       # 查看帮助
```

### 安装完成后

```
================================================
  🎉 部署完成！
================================================
  访问: http://你的IP:3000
  管理员: admin / 你设置的密码
================================================
```

---

## 📋 管理菜单

再次运行 `sudo ./bushu-20.sh` 进入交互式菜单：

```
  1. 安装/修复 (保留数据)
  2. 启动/重启服务
  3. 停止服务
  4. 查看运行日志
  5. 修改配置参数
  6. 配置 SSL/HTTPS
  7. 卸载程序
  0. 退出
```

**修改配置** 支持：
- 修改管理员密码
- 修改服务端口
- 修改管理员用户名

**卸载选项**：
- 保留数据卸载（仅停止服务）
- 完全卸载（删除所有数据）
- 仅卸载 SSL 证书

---

## 🔒 配置 HTTPS

```bash
sudo ./bushu-20.sh --ssl
```

前置条件：
1. 已有域名并解析到服务器 IP
2. 服务器开放 80 和 443 端口

脚本会自动：
- 配置 Nginx 反向代理
- 通过 Let's Encrypt 申请免费 SSL 证书
- 设置证书自动续期定时任务
- 检测已有证书并提供复用选项

---

## 📱 移动端推送通知

### Android
打开网页 → 浏览器设置 → 开启通知权限 → 在聊天室设置中开启推送

### iOS (需要 16.4+)
1. 用 Safari 打开聊天室
2. 点击底部「分享」按钮 → 「添加到主屏幕」
3. 从主屏幕图标打开应用
4. 进入设置 → 开启推送通知

> ⚠️ 推送通知需要 HTTPS 环境（已配置 SSL）或 localhost。

---

## 🏗️ 技术架构

```
┌─────────────┐     ┌───────────┐     ┌──────────────┐
│   Browser   │────▶│   Nginx   │────▶│   Express    │
│  (PWA/SW)   │◀────│  (反向代理) │◀────│  + Socket.IO │
└─────────────┘     └───────────┘     └──────┬───────┘
                                             │
                                      ┌──────▼───────┐
                                      │    SQLite     │
                                      │  (WAL 模式)   │
                                      └──────────────┘
```

| 组件 | 技术 |
|------|------|
| 前端 | 原生 HTML/CSS/JS，Socket.IO Client，PWA + Service Worker |
| 后端 | Node.js + Express + Socket.IO |
| 数据库 | SQLite (better-sqlite3)，WAL 模式 |
| 认证 | JWT (jsonwebtoken) + bcryptjs |
| 推送 | Web Push (VAPID) |
| 文件上传 | Multer，支持中文文件名 |
| 进程管理 | PM2 |
| 反向代理 | Nginx |
| HTTPS | Let's Encrypt (Certbot) |

---

## 📁 目录结构

```
/var/www/teamchat/
├── server.js              # 后端主程序
├── package.json
├── database.sqlite        # 数据库（自动创建）
├── .jwt_secret            # JWT 密钥（自动生成）
├── .vapid_keys            # Web Push 密钥（自动生成）
├── public/
│   ├── index.html         # 前端页面
│   ├── app.js             # 前端逻辑
│   ├── style.css          # 样式
│   ├── sw.js              # Service Worker
│   ├── manifest.json      # PWA 配置
│   └── images/            # 图标资源
├── uploads/               # 用户上传文件
├── avatars/               # 用户头像
└── backgrounds/           # 聊天背景图
```

---

## 🔧 常见问题

<details>
<summary><b>升级后页面没有变化？</b></summary>

浏览器可能缓存了旧版文件。按 `Ctrl+Shift+R` (Windows/Linux) 或 `Cmd+Shift+R` (Mac) 强制刷新。PWA 用户需要在设置中关闭再重新开启推送通知以更新 Service Worker。
</details>

<details>
<summary><b>端口被占用？</b></summary>

安装时选择其他端口，或通过管理菜单 `5. 修改配置参数` → `2. 修改端口` 更换。
</details>

<details>
<summary><b>忘记管理员密码？</b></summary>

运行 `sudo ./bushu-20.sh`，选择 `5. 修改配置参数` → `1. 修改管理员密码`。
</details>

<details>
<summary><b>SSL 证书申请失败？</b></summary>

确认：①域名已正确解析到服务器 IP；②服务器 80/443 端口已开放；③没有其他程序占用 80 端口。
</details>

<details>
<summary><b>iOS 收不到推送通知？</b></summary>

确认：①iOS 版本 ≥ 16.4；②必须通过「添加到主屏幕」后从主屏图标打开；③已开启 HTTPS；④在系统设置中允许了通知权限。
</details>

<details>
<summary><b>如何迁移到新服务器？</b></summary>

1. 在旧服务器管理后台导出备份（JSON 格式）
2. 导出用户数据（用户管理 → 导出用户数据）
3. 在新服务器运行安装脚本
4. 导入用户数据和聊天记录
5. 手动迁移 `/var/www/teamchat/uploads/` 和 `/var/www/teamchat/avatars/` 目录
</details>

---

## 📝 更新日志

### v7.4 (2026-03-26)
- ✨ 新增富文本编辑器：加粗、斜体、下划线、删除线、文字颜色、背景高亮色
- ✨ 新增多行消息支持 (Shift+Enter 换行)
- 🔒 三层 XSS 防护（客户端发送端 + 服务端 + 客户端渲染端）
- 🔄 向后兼容旧版纯文本消息

### v7.3
- 📱 iOS/Android 推送通知修复
- 🎨 生成真正的 PNG 格式 PWA 图标
- ⚡ Service Worker 完整化

---

## 📄 License

[MIT](LICENSE)

---

<div align="center">

**如果觉得有用，欢迎 ⭐ Star 支持！**

</div>
