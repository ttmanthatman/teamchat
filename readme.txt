# TeamChat - 团队聊天室

一键部署的轻量级团队即时通讯系统，支持私有化部署，无需依赖任何第三方服务。

![TeamChat](https://img.shields.io/badge/version-2.3.0-blue) ![Node](https://img.shields.io/badge/node-%3E%3D18-green) ![License](https://img.shields.io/badge/license-MIT-orange)

## ✨ 功能特性

**基础聊天**
- 实时文字消息、文件/图片发送
- 引用回复、在线状态显示
- 消息历史记录、分页加载

**推送通知**
- Android Chrome 原生推送
- iOS Safari PWA 推送（16.4+）
- 桌面浏览器推送（Chrome / Edge / Firefox）

**管理功能**
- 用户管理（增删、批量导入/导出含密码迁移）
- 聊天记录备份与还原
- 按日期范围删除聊天记录
- 单终端登录（新设备登录自动踢出旧设备）

**外观定制**
- 自定义登录页标题、聊天室标题
- 自定义发送按钮文字和颜色
- 聊天背景：纯色 / 图片（填充、适应、拉伸、平铺）
- 全局时区设置
- 实时预览，保存后全员即时生效

## 📋 环境要求

- Linux 服务器（Ubuntu / Debian / CentOS / Rocky / Alma）
- Root 权限
- 开放端口（默认 3000，或自定义）

脚本会自动安装以下依赖：Node.js 20.x、PM2、Nginx、Certbot

## 🚀 快速部署

**一行命令安装：**

```bash
curl -fsSL https://raw.githubusercontent.com/你的用户名/teamchat/main/bushu.sh -o bushu.sh && sudo bash bushu.sh
```

**或手动安装：**

```bash
git clone https://github.com/你的用户名/teamchat.git
cd teamchat
sudo bash bushu.sh
```

按提示选择 IP、设置管理员账号密码和端口即可完成部署。

## 📖 使用说明

### 交互式菜单

直接运行脚本即可进入交互式菜单：

```bash
sudo bash bushu.sh
```

```
================================================
  请选择操作:
================================================
  1. 安装/修复 (保留数据)
  2. 启动/重启服务
  3. 停止服务
  4. 查看运行日志
  5. 修改配置参数
  6. 配置 SSL/HTTPS
  7. 卸载程序
  0. 退出
================================================
```

### 命令行参数

```bash
sudo bash bushu.sh --install        # 直接安装
sudo bash bushu.sh --ssl            # 配置 SSL
sudo bash bushu.sh --uninstall      # 卸载
sudo bash bushu.sh --uninstall-force # 完全卸载（删除所有数据）
sudo bash bushu.sh --help           # 帮助
```

### 常用运维命令

```bash
pm2 logs teamchat          # 查看日志
pm2 restart teamchat       # 重启服务
pm2 stop teamchat          # 停止服务
pm2 monit                  # 监控面板
```

## 📱 推送通知配置

> **推送通知需要 HTTPS 环境**（localhost 除外）

| 平台 | 使用方式 |
|------|---------|
| Android Chrome | 打开网页 → 设置 → 开启推送 |
| iOS Safari 16.4+ | Safari 分享 → 添加到主屏幕 → 从主屏幕打开 → 设置 → 开启推送 |
| 桌面浏览器 | 打开网页 → 设置 → 开启推送 |

配置 SSL 一键命令：

```bash
sudo bash bushu.sh --ssl
```

## 🔄 用户数据迁移

导出的用户数据包含 bcrypt 哈希密码，可直接在另一台服务器导入，用户无需重置密码。

**导出**：设置 → 用户管理 → 导出用户数据

**导入**：设置 → 用户管理 → 导入用户数据

导出文件格式：
```json
{
  "version": 2,
  "exported_at": "2026-03-13T12:00:00.000Z",
  "users": [
    {
      "username": "zhangsan",
      "password_hash": "$2a$10$...",
      "nickname": "张三",
      "is_admin": false,
      "created_at": "2026-03-01 08:00:00"
    }
  ]
}
```

## 🏗️ 技术架构

```
前端: 原生 HTML/CSS/JS + Socket.IO Client + PWA
后端: Node.js + Express + Socket.IO + better-sqlite3
数据库: SQLite (WAL 模式)
推送: Web Push (VAPID)
进程管理: PM2
反向代理: Nginx
SSL: Let's Encrypt (Certbot)
```

## 📁 目录结构

```
/var/www/teamchat/
├── server.js              # 后端主程序
├── package.json
├── database.sqlite        # 数据库
├── .jwt_secret            # JWT 密钥（自动生成）
├── .vapid_keys            # 推送密钥（自动生成）
├── uploads/               # 用户上传文件
├── avatars/               # 用户头像
├── backgrounds/           # 聊天背景图
└── public/
    ├── index.html
    ├── style.css
    ├── app.js
    ├── sw.js              # Service Worker
    ├── manifest.json      # PWA 清单
    └── images/
```

## ❓ 常见问题

**Q: 忘记管理员密码怎么办？**

```bash
sudo bash bushu.sh
# 选择 5 → 1 修改管理员密码
```

**Q: 如何修改端口？**

```bash
sudo bash bushu.sh
# 选择 5 → 2 修改端口，Nginx 配置会自动同步
```

**Q: iOS 收不到推送？**

必须先"添加到主屏幕"，再从主屏幕图标打开，且需要 HTTPS 环境。

**Q: 数据如何备份？**

- 方式一：管理面板 → 备份/还原 → 按日期导出
- 方式二：直接备份 `/var/www/teamchat/database.sqlite` 文件

**Q: 重新安装会丢失数据吗？**

不会。选择"安装/修复"会保留数据库和上传文件，仅更新代码。

## 📄 许可证

[MIT License](LICENSE)

## 🤝 贡献

欢迎提交 Issue 和 Pull Request。
