#!/bin/bash
# TeamChat Manager - Web管理面板一键部署脚本 v1.1
# 功能: 浏览器管理聊天室部署/升级/实例/用户数据/域名/SSL
# 独立运行，卸载不影响已部署的聊天室
set -e
GREEN='\033[0;32m';YELLOW='\033[1;33m';RED='\033[1;31m';CYAN='\033[0;36m';NC='\033[0m'
trap 'echo -e "${RED}[错误] 第 $LINENO 行执行失败${NC}"' ERR

MGR_DIR="/var/www/tc-manager"
MGR_PORT=9800
MGR_PM2="tc-manager"
CHAT_BASE="/var/www"
CHAT_PREFIX="teamchat"

print_menu(){
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}  TeamChat Manager 管理面板${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo -e "  ${GREEN}1${NC}. 安装/更新管理面板"
    echo -e "  ${GREEN}2${NC}. 启动/重启"
    echo -e "  ${GREEN}3${NC}. 停止"
    echo -e "  ${GREEN}4${NC}. 查看日志"
    echo -e "  ${GREEN}5${NC}. 修改端口/密码"
    echo -e "  ${GREEN}6${NC}. 卸载管理面板"
    echo -e "  ${GREEN}0${NC}. 退出"
    echo -e "${CYAN}========================================${NC}"
    echo -n "请选择 [0-6]: "
}

check_root(){ if [ "$EUID" -ne 0 ]; then echo -e "${RED}请用 sudo 运行${NC}";exit 1;fi; }

install_node(){
    if ! command -v node >/dev/null 2>&1;then
        echo -e "${YELLOW}安装 Node.js...${NC}"
        if [ -f /etc/os-release ];then . /etc/os-release;fi
        if [ "$ID" = "centos" ]||[ "$ID" = "rhel" ]||[ "$ID" = "rocky" ];then
            curl -fsSL https://rpm.nodesource.com/setup_20.x|bash - >/dev/null 2>&1;yum install -y nodejs
        else
            curl -fsSL https://deb.nodesource.com/setup_20.x|bash - >/dev/null 2>&1;apt-get install -y nodejs
        fi
    fi
    command -v pm2 >/dev/null 2>&1||npm install -g pm2
}

do_install(){
    echo -e "\n${CYAN}>>> 安装 TeamChat Manager <<<${NC}\n"
    install_node
    mkdir -p "$MGR_DIR/uploads" "$MGR_DIR/backups" "$MGR_DIR/public"

    # 管理面板密码
    local current_pass=""
    if [ -f "$MGR_DIR/.env" ]; then current_pass=$(grep '^ADMIN_PASS=' "$MGR_DIR/.env" 2>/dev/null|cut -d= -f2); fi
    if [ -n "$current_pass" ];then
        echo -e "${GREEN}检测到已有密码配置${NC}"
        printf "是否修改密码? (y/n) [n]: ";read -r chg
        if [ "$chg" = "y" ];then
            printf "新管理密码: ";read -r MGR_PASS
            if [ -z "$MGR_PASS" ]; then MGR_PASS="$current_pass"; fi
        else MGR_PASS="$current_pass";fi
    else
        printf "设置管理密码 [admin888]: ";read -r MGR_PASS
        MGR_PASS=${MGR_PASS:-admin888}
    fi

    local current_port=""
    if [ -f "$MGR_DIR/.env" ]; then current_port=$(grep '^PORT=' "$MGR_DIR/.env" 2>/dev/null|cut -d= -f2); fi
    if [ -n "$current_port" ];then
        printf "管理面板端口 [$current_port]: ";read -r input
        MGR_PORT=${input:-$current_port}
    else
        printf "管理面板端口 [$MGR_PORT]: ";read -r input
        MGR_PORT=${input:-$MGR_PORT}
    fi

    cat > "$MGR_DIR/.env" <<EOF
PORT=$MGR_PORT
ADMIN_PASS=$MGR_PASS
CHAT_BASE=$CHAT_BASE
CHAT_PREFIX=$CHAT_PREFIX
EOF
    chmod 600 "$MGR_DIR/.env"

    write_package_json
    write_server
    write_frontend

    echo -e "${YELLOW}安装依赖...${NC}"
    cd "$MGR_DIR"&&npm install --production 2>&1|tail -1
    npm rebuild 2>/dev/null||true

    pm2 stop $MGR_PM2 2>/dev/null||true
    pm2 delete $MGR_PM2 2>/dev/null||true
    cd "$MGR_DIR";pm2 start server.js --name $MGR_PM2;pm2 save
    pm2 startup systemd -u root --hp /root >/dev/null 2>&1||true

    local ip=$(curl -s --connect-timeout 5 -4 ifconfig.me 2>/dev/null||hostname -I|awk '{print $1}')
    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${GREEN}  ✅ 管理面板部署完成！${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "  访问: http://${ip}:${MGR_PORT}"
    echo -e "  密码: $MGR_PASS"
    echo -e "${GREEN}========================================${NC}\n"
}

write_package_json(){
    cat > "$MGR_DIR/package.json" <<'EOF'
{"name":"tc-manager","version":"1.0.0","main":"server.js","dependencies":{"express":"^4.18.2","multer":"^1.4.5-lts.1","better-sqlite3":"^9.2.2","bcryptjs":"^2.4.3","jsonwebtoken":"^9.0.2","cookie-parser":"^1.4.6"}}
EOF
}

write_server(){
    cat > "$MGR_DIR/server.js" <<'SRVEOF'
const express=require("express"),multer=require("multer"),path=require("path"),fs=require("fs"),{execSync,spawn}=require("child_process"),crypto=require("crypto"),jwt=require("jsonwebtoken"),cookieParser=require("cookie-parser");

// 加载配置
const envFile=path.join(__dirname,".env");
const env={};
if(fs.existsSync(envFile)){fs.readFileSync(envFile,"utf-8").split("\n").forEach(l=>{const[k,...v]=l.split("=");if(k&&v.length)env[k.trim()]=v.join("=").trim()})}
const PORT=env.PORT||9800;
const ADMIN_PASS=env.ADMIN_PASS||"admin888";
const CHAT_BASE=env.CHAT_BASE||"/var/www";
const CHAT_PREFIX=env.CHAT_PREFIX||"teamchat";
const JWT_SECRET=crypto.randomBytes(32).toString("hex");
const UPLOAD_DIR=path.join(__dirname,"uploads");
const BACKUP_DIR=path.join(__dirname,"backups");
[UPLOAD_DIR,BACKUP_DIR].forEach(d=>{if(!fs.existsSync(d))fs.mkdirSync(d,{recursive:true})});

const app=express();
app.use(express.json({limit:"200mb"}));
app.use(cookieParser());
app.use(express.static(path.join(__dirname,"public")));

const upload=multer({dest:UPLOAD_DIR,limits:{fileSize:200*1024*1024},fileFilter:(r,f,cb)=>{cb(f.originalname.endsWith(".sh")?null:new Error("只允许.sh文件"),f.originalname.endsWith(".sh"))}});

// 认证
function auth(req,res,next){
  const token=req.cookies?.token||req.headers.authorization?.split(" ")[1];
  if(!token)return res.status(401).json({error:"未登录"});
  try{jwt.verify(token,JWT_SECRET);next()}catch(e){res.status(401).json({error:"登录过期"})}
}

app.post("/api/login",(req,res)=>{
  if(req.body.password===ADMIN_PASS){
    const token=jwt.sign({role:"admin"},JWT_SECRET,{expiresIn:"24h"});
    res.cookie("token",token,{httpOnly:true,maxAge:86400000,sameSite:"strict"});
    res.json({success:true,token});
  }else res.json({success:false,message:"密码错误"});
});

app.post("/api/logout",(req,res)=>{res.clearCookie("token");res.json({success:true})});

// 执行shell命令（带超时）
function run(cmd,timeout=60000){
  try{return{ok:true,output:execSync(cmd,{timeout,encoding:"utf-8",stdio:["pipe","pipe","pipe"]}).trim()}}
  catch(e){return{ok:false,output:(e.stderr||e.stdout||e.message||"").toString().trim()}}
}

// ===== 实例管理 =====
function getInstances(){
  const instances=[];
  const dirs=[path.join(CHAT_BASE,CHAT_PREFIX)];
  try{fs.readdirSync(CHAT_BASE).forEach(d=>{if(d.startsWith(CHAT_PREFIX+"-"))dirs.push(path.join(CHAT_BASE,d))})}catch(e){}
  for(const dir of dirs){
    if(!fs.existsSync(path.join(dir,"server.js")))continue;
    const name=path.basename(dir);
    let port="?";
    try{const s=fs.readFileSync(path.join(dir,"server.js"),"utf-8");const m=s.match(/const PORT\s*=\s*process\.env\.PORT\s*\|\|\s*(\d+)/);if(m)port=m[1]}catch(e){}
    let status="stopped",pm2info={};
    const r=run("pm2 jlist 2>/dev/null");
    if(r.ok){try{const list=JSON.parse(r.output);const p=list.find(x=>x.name===name);if(p){status=p.pm2_env?.status||"unknown";pm2info={cpu:p.monit?.cpu,mem:p.monit?.memory,uptime:p.pm2_env?.pm_uptime}}}catch(e){}}
    let version="未知",dbSize=0,userCount=0,msgCount=0;
    try{const pkg=JSON.parse(fs.readFileSync(path.join(dir,"package.json"),"utf-8"));version=pkg.version||version}catch(e){}
    const dbPath=path.join(dir,"database.sqlite");
    if(fs.existsSync(dbPath)){
      try{dbSize=fs.statSync(dbPath).size;
        const Database=require("better-sqlite3");const db=new Database(dbPath,{readonly:true});
        userCount=db.prepare("SELECT COUNT(*) as c FROM users").get()?.c||0;
        msgCount=db.prepare("SELECT COUNT(*) as c FROM messages").get()?.c||0;
        db.close();
      }catch(e){}
    }
    instances.push({name,dir,port,status,version,dbSize,userCount,msgCount,pm2info,...getNginxInfo(name,port)});
  }
  return instances;
}

function getNginxInfo(name,port){
  const info={domain:"",ssl:false,sslExpiry:"",nginxConf:""};
  const confPaths=[`/etc/nginx/conf.d/${name}.conf`,"/etc/nginx/conf.d/teamchat.conf"];
  for(const cp of confPaths){
    if(!fs.existsSync(cp))continue;
    try{
      const c=fs.readFileSync(cp,"utf-8");
      if(!c.includes("proxy_pass http://127.0.0.1:"+port))continue;
      info.nginxConf=cp;
      const sm=c.match(/server_name\s+([^;]+)/);
      if(sm)info.domain=sm[1].trim().replace(/_/g,"");
      if(c.includes("ssl_certificate")&&!c.includes("#ssl_certificate"))info.ssl=true;
      if(info.ssl&&info.domain){
        const r=run(`echo | openssl s_client -servername ${info.domain} -connect ${info.domain}:443 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null`);
        if(r.ok){const m=r.output.match(/notAfter=(.*)/);if(m)info.sslExpiry=m[1]}
      }
      break;
    }catch(e){}
  }
  return info;
}

app.get("/api/instances",auth,(req,res)=>res.json(getInstances()));

app.post("/api/instances/:name/start",auth,(req,res)=>{
  const inst=getInstances().find(i=>i.name===req.params.name);
  if(!inst)return res.json({success:false,message:"实例不存在"});
  const r=run(`cd "${inst.dir}" && pm2 start server.js --name "${inst.name}" 2>&1||pm2 restart "${inst.name}" 2>&1`);
  run("pm2 save 2>/dev/null");
  res.json({success:r.ok,output:r.output});
});

app.post("/api/instances/:name/stop",auth,(req,res)=>{
  const r=run(`pm2 stop "${req.params.name}" 2>&1`);
  run("pm2 save 2>/dev/null");
  res.json({success:r.ok,output:r.output});
});

app.post("/api/instances/:name/restart",auth,(req,res)=>{
  const r=run(`pm2 restart "${req.params.name}" 2>&1`);
  run("pm2 save 2>/dev/null");
  res.json({success:r.ok,output:r.output});
});

app.get("/api/instances/:name/logs",auth,(req,res)=>{
  const r=run(`pm2 logs "${req.params.name}" --lines 100 --nostream 2>&1`,10000);
  res.json({output:r.output||"无日志"});
});

app.delete("/api/instances/:name",auth,(req,res)=>{
  const name=req.params.name;
  if(name===CHAT_PREFIX)return res.json({success:false,message:"不能从管理面板删除默认实例，请用SSH操作"});
  const inst=getInstances().find(i=>i.name===name);
  if(!inst)return res.json({success:false,message:"实例不存在"});
  run(`pm2 stop "${name}" 2>/dev/null;pm2 delete "${name}" 2>/dev/null;pm2 save 2>/dev/null`);
  run(`rm -f /etc/nginx/conf.d/${name}.conf;nginx -t 2>/dev/null&&systemctl reload nginx 2>/dev/null`);
  // 不删除数据目录，只标记
  const ts=new Date().toISOString().replace(/[:.]/g,"-");
  if(fs.existsSync(inst.dir)){try{fs.renameSync(inst.dir,inst.dir+".deleted-"+ts)}catch(e){}}
  res.json({success:true,message:"实例已停止并标记删除"});
});

// ===== 脚本版本管理 =====
app.get("/api/scripts",auth,(req,res)=>{
  const files=[];
  try{fs.readdirSync(UPLOAD_DIR).forEach(f=>{
    if(!f.endsWith(".sh"))return;
    const stat=fs.statSync(path.join(UPLOAD_DIR,f));
    let ver="";
    try{const c=fs.readFileSync(path.join(UPLOAD_DIR,f),"utf-8").substring(0,500);const m=c.match(/v[\d.]+/);if(m)ver=m[0]}catch(e){}
    files.push({name:f,size:stat.size,time:stat.mtime,version:ver});
  })}catch(e){}
  files.sort((a,b)=>new Date(b.time)-new Date(a.time));
  res.json(files);
});

app.post("/api/scripts/upload",auth,upload.single("script"),(req,res)=>{
  if(!req.file)return res.json({success:false,message:"上传失败"});
  const origName=req.file.originalname.replace(/[^a-zA-Z0-9_.\-]/g,"_");
  const ts=new Date().toISOString().slice(0,19).replace(/[:.]/g,"");
  const finalName=ts+"_"+origName;
  fs.renameSync(req.file.path,path.join(UPLOAD_DIR,finalName));
  fs.chmodSync(path.join(UPLOAD_DIR,finalName),0o755);
  res.json({success:true,name:finalName});
});

app.delete("/api/scripts/:name",auth,(req,res)=>{
  const fp=path.join(UPLOAD_DIR,path.basename(req.params.name));
  if(!fs.existsSync(fp))return res.json({success:false,message:"文件不存在"});
  fs.unlinkSync(fp);res.json({success:true});
});

// 用脚本部署新实例
app.post("/api/deploy",auth,(req,res)=>{
  const{script,instanceName,port,adminUser,adminPass}=req.body;
  if(!script||!port)return res.json({success:false,message:"参数不完整"});
  const fp=path.join(UPLOAD_DIR,path.basename(script));
  if(!fs.existsSync(fp))return res.json({success:false,message:"脚本不存在"});

  // 部署用非交互方式：先解析脚本写入文件，然后改端口启动
  // 返回 job id，前端轮询状态
  const jobId=crypto.randomBytes(8).toString("hex");
  const logFile=path.join(BACKUP_DIR,`deploy-${jobId}.log`);
  fs.writeFileSync(logFile,"开始部署...\n");

  const child=spawn("bash",[fp,"--install"],{
    env:{...process.env,NONINTERACTIVE:"1",DEPLOY_PORT:port||"3000",DEPLOY_ADMIN:adminUser||"admin",DEPLOY_PASS:adminPass||"admin123",DEPLOY_INSTANCE:instanceName||""},
    stdio:["pipe","pipe","pipe"]
  });

  const logStream=fs.createWriteStream(logFile,{flags:"a"});
  child.stdout.pipe(logStream);
  child.stderr.pipe(logStream);
  child.on("close",(code)=>{
    fs.appendFileSync(logFile,`\n部署${code===0?"成功":"失败"}(退出码:${code})\n`);
  });

  // 自动响应脚本的交互式输入
  setTimeout(()=>{try{child.stdin.write("1\n")}catch(e){}},1000);// IP选择
  setTimeout(()=>{try{child.stdin.write((adminUser||"admin")+"\n")}catch(e){}},2000);
  setTimeout(()=>{try{child.stdin.write((adminPass||"admin123")+"\n")}catch(e){}},3000);
  setTimeout(()=>{try{child.stdin.write((port||"3000")+"\n")}catch(e){}},4000);
  setTimeout(()=>{try{child.stdin.write("n\n")}catch(e){}},5000);// SSL
  setTimeout(()=>{try{child.stdin.write("y\n")}catch(e){}},6000);// 确认

  res.json({success:true,jobId});
});

app.get("/api/deploy/:jobId/log",auth,(req,res)=>{
  const logFile=path.join(BACKUP_DIR,`deploy-${req.params.jobId}.log`);
  if(!fs.existsSync(logFile))return res.json({log:"日志不存在"});
  res.json({log:fs.readFileSync(logFile,"utf-8")});
});

// ===== 用户数据管理 =====
app.get("/api/instances/:name/users",auth,(req,res)=>{
  const inst=getInstances().find(i=>i.name===req.params.name);
  if(!inst)return res.json([]);
  const dbPath=path.join(inst.dir,"database.sqlite");
  if(!fs.existsSync(dbPath))return res.json([]);
  try{
    const Database=require("better-sqlite3");const db=new Database(dbPath,{readonly:true});
    const users=db.prepare("SELECT id,username,nickname,is_admin,created_at FROM users").all();
    db.close();res.json(users);
  }catch(e){res.json([])}
});

app.post("/api/instances/:name/users",auth,async(req,res)=>{
  const inst=getInstances().find(i=>i.name===req.params.name);
  if(!inst)return res.json({success:false,message:"实例不存在"});
  const{username,password,nickname}=req.body;
  if(!username||!password)return res.json({success:false,message:"用户名和密码不能为空"});
  try{
    const Database=require("better-sqlite3");const bcrypt=require("bcryptjs");
    const db=new Database(path.join(inst.dir,"database.sqlite"));
    const hash=bcrypt.hashSync(password,10);
    db.prepare("INSERT INTO users (username,password,nickname) VALUES (?,?,?)").run(username,hash,nickname||username);
    db.close();res.json({success:true});
  }catch(e){res.json({success:false,message:e.message})}
});

app.delete("/api/instances/:name/users/:uid",auth,(req,res)=>{
  const inst=getInstances().find(i=>i.name===req.params.name);
  if(!inst)return res.json({success:false});
  try{
    const Database=require("better-sqlite3");
    const db=new Database(path.join(inst.dir,"database.sqlite"));
    const u=db.prepare("SELECT is_admin FROM users WHERE id=?").get(req.params.uid);
    if(u?.is_admin)return res.json({success:false,message:"不能删除管理员"});
    db.prepare("DELETE FROM users WHERE id=?").run(req.params.uid);
    db.close();res.json({success:true});
  }catch(e){res.json({success:false,message:e.message})}
});

app.post("/api/instances/:name/users/:uid/reset-password",auth,(req,res)=>{
  const inst=getInstances().find(i=>i.name===req.params.name);
  if(!inst)return res.json({success:false});
  const{password}=req.body;if(!password||password.length<6)return res.json({success:false,message:"密码至少6位"});
  try{
    const Database=require("better-sqlite3");const bcrypt=require("bcryptjs");
    const db=new Database(path.join(inst.dir,"database.sqlite"));
    db.prepare("UPDATE users SET password=? WHERE id=?").run(bcrypt.hashSync(password,10),req.params.uid);
    db.close();res.json({success:true});
  }catch(e){res.json({success:false,message:e.message})}
});

// ===== 数据备份 =====
app.post("/api/instances/:name/backup",auth,(req,res)=>{
  const inst=getInstances().find(i=>i.name===req.params.name);
  if(!inst)return res.json({success:false});
  const dbPath=path.join(inst.dir,"database.sqlite");
  if(!fs.existsSync(dbPath))return res.json({success:false,message:"数据库不存在"});
  const ts=new Date().toISOString().slice(0,19).replace(/[:.]/g,"");
  const backupName=`${inst.name}-${ts}.sqlite`;
  try{
    fs.copyFileSync(dbPath,path.join(BACKUP_DIR,backupName));
    res.json({success:true,name:backupName});
  }catch(e){res.json({success:false,message:e.message})}
});

app.get("/api/backups",auth,(req,res)=>{
  try{
    const files=fs.readdirSync(BACKUP_DIR).filter(f=>f.endsWith(".sqlite")).map(f=>{
      const stat=fs.statSync(path.join(BACKUP_DIR,f));
      return{name:f,size:stat.size,time:stat.mtime};
    }).sort((a,b)=>new Date(b.time)-new Date(a.time));
    res.json(files);
  }catch(e){res.json([])}
});

app.get("/api/backups/:name/download",auth,(req,res)=>{
  const fp=path.join(BACKUP_DIR,path.basename(req.params.name));
  if(!fs.existsSync(fp))return res.status(404).send("不存在");
  res.download(fp);
});

app.delete("/api/backups/:name",auth,(req,res)=>{
  const fp=path.join(BACKUP_DIR,path.basename(req.params.name));
  if(fs.existsSync(fp))fs.unlinkSync(fp);
  res.json({success:true});
});

// ===== 域名 & SSL =====
app.post("/api/instances/:name/domain",auth,(req,res)=>{
  const inst=getInstances().find(i=>i.name===req.params.name);
  if(!inst)return res.json({success:false,message:"实例不存在"});
  const{domain}=req.body;
  if(!domain||!/^[a-zA-Z0-9]([a-zA-Z0-9\-]*\.)+[a-zA-Z]{2,}$/.test(domain))return res.json({success:false,message:"域名格式不正确"});
  const confPath=`/etc/nginx/conf.d/${inst.name}.conf`;
  const conf=`server {\n    listen 80;\n    server_name ${domain};\n    client_max_body_size 120M;\n    location / {\n        proxy_pass http://127.0.0.1:${inst.port};\n        proxy_http_version 1.1;\n        proxy_set_header Upgrade $http_upgrade;\n        proxy_set_header Connection "upgrade";\n        proxy_set_header Host $host;\n        proxy_set_header X-Real-IP $remote_addr;\n        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n        proxy_set_header X-Forwarded-Proto $scheme;\n        proxy_read_timeout 3600s;\n        proxy_send_timeout 3600s;\n    }\n}\n`;
  try{fs.writeFileSync(confPath,conf)}catch(e){return res.json({success:false,message:"写入配置失败: "+e.message})}
  let r=run("nginx -t 2>&1");
  if(!r.ok&&!r.output.includes("successful")){
    try{fs.unlinkSync(confPath)}catch(e){}
    return res.json({success:false,message:"Nginx配置测试失败: "+r.output});
  }
  r=run("systemctl reload nginx 2>&1");
  res.json({success:true,message:`域名 ${domain} 已绑定到 ${inst.name}`});
});

app.post("/api/instances/:name/ssl/apply",auth,(req,res)=>{
  const inst=getInstances().find(i=>i.name===req.params.name);
  if(!inst)return res.json({success:false,message:"实例不存在"});
  const{domain,email}=req.body;
  if(!domain)return res.json({success:false,message:"请先绑定域名"});
  const jobId=crypto.randomBytes(8).toString("hex");
  const logFile=path.join(BACKUP_DIR,`ssl-${jobId}.log`);
  fs.writeFileSync(logFile,"开始申请SSL证书...\n域名: "+domain+"\n\n");
  const confPath=inst.nginxConf||`/etc/nginx/conf.d/${inst.name}.conf`;
  // 确保有基础HTTP配置
  if(!fs.existsSync(confPath)){
    fs.appendFileSync(logFile,"错误: Nginx配置不存在，请先绑定域名\n");
    return res.json({success:false,message:"请先绑定域名"});
  }
  const emailArg=email||("admin@"+domain);
  const child=spawn("certbot",["--nginx","-d",domain,"--non-interactive","--agree-tos","--email",emailArg],{stdio:["pipe","pipe","pipe"]});
  const logStream=fs.createWriteStream(logFile,{flags:"a"});
  child.stdout.pipe(logStream);child.stderr.pipe(logStream);
  child.on("close",(code)=>{
    fs.appendFileSync(logFile,`\n${code===0?"✅ SSL证书申请成功！":"❌ SSL证书申请失败"} (退出码:${code})\n`);
    if(code===0){
      run("systemctl enable certbot.timer 2>/dev/null;systemctl start certbot.timer 2>/dev/null");
      fs.appendFileSync(logFile,"已启用自动续期\n");
    }
  });
  res.json({success:true,jobId});
});

app.get("/api/ssl/:jobId/log",auth,(req,res)=>{
  const logFile=path.join(BACKUP_DIR,`ssl-${req.params.jobId}.log`);
  if(!fs.existsSync(logFile))return res.json({log:"日志不存在"});
  res.json({log:fs.readFileSync(logFile,"utf-8")});
});

app.post("/api/instances/:name/ssl/remove",auth,(req,res)=>{
  const inst=getInstances().find(i=>i.name===req.params.name);
  if(!inst)return res.json({success:false,message:"实例不存在"});
  if(!inst.domain)return res.json({success:false,message:"未绑定域名"});
  // 删除certbot证书
  run(`certbot delete --cert-name ${inst.domain} --non-interactive 2>/dev/null`);
  // 重写为纯HTTP配置
  const confPath=inst.nginxConf||`/etc/nginx/conf.d/${inst.name}.conf`;
  const conf=`server {\n    listen 80;\n    server_name ${inst.domain};\n    client_max_body_size 120M;\n    location / {\n        proxy_pass http://127.0.0.1:${inst.port};\n        proxy_http_version 1.1;\n        proxy_set_header Upgrade $http_upgrade;\n        proxy_set_header Connection "upgrade";\n        proxy_set_header Host $host;\n        proxy_set_header X-Real-IP $remote_addr;\n        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n        proxy_set_header X-Forwarded-Proto $scheme;\n        proxy_read_timeout 3600s;\n        proxy_send_timeout 3600s;\n    }\n}\n`;
  try{fs.writeFileSync(confPath,conf)}catch(e){return res.json({success:false,message:"写入失败"})}
  const r=run("nginx -t 2>&1&&systemctl reload nginx 2>&1");
  res.json({success:true,message:"SSL证书已卸载，已回退为HTTP"});
});

app.post("/api/instances/:name/domain/remove",auth,(req,res)=>{
  const inst=getInstances().find(i=>i.name===req.params.name);
  if(!inst)return res.json({success:false,message:"实例不存在"});
  if(inst.ssl&&inst.domain)run(`certbot delete --cert-name ${inst.domain} --non-interactive 2>/dev/null`);
  const confPath=inst.nginxConf||`/etc/nginx/conf.d/${inst.name}.conf`;
  if(fs.existsSync(confPath)){try{fs.unlinkSync(confPath)}catch(e){}}
  run("nginx -t 2>&1&&systemctl reload nginx 2>&1");
  res.json({success:true,message:"域名和Nginx配置已移除"});
});

app.post("/api/instances/:name/ssl/renew",auth,(req,res)=>{
  const inst=getInstances().find(i=>i.name===req.params.name);
  if(!inst||!inst.domain)return res.json({success:false,message:"请先绑定域名"});
  const r=run(`certbot renew --cert-name ${inst.domain} --force-renewal 2>&1`,120000);
  if(r.ok||r.output.includes("success")){
    run("systemctl reload nginx 2>/dev/null");
    res.json({success:true,message:"证书续期成功"});
  }else res.json({success:false,message:"续期失败: "+r.output.substring(0,500)});
});

// ===== 系统信息 =====
app.get("/api/system",auth,(req,res)=>{
  const info={};
  let r=run("cat /proc/uptime 2>/dev/null");
  if(r.ok){const s=parseFloat(r.output);const d=Math.floor(s/86400),h=Math.floor(s%86400/3600),m=Math.floor(s%3600/60);info.uptime=`${d}天${h}时${m}分`}
  r=run("free -m 2>/dev/null|grep Mem");
  if(r.ok){const p=r.output.split(/\s+/);info.memTotal=p[1]+"MB";info.memUsed=p[2]+"MB"}
  r=run("df -h / 2>/dev/null|tail -1");
  if(r.ok){const p=r.output.split(/\s+/);info.diskTotal=p[1];info.diskUsed=p[2];info.diskPercent=p[4]}
  r=run("node -v 2>/dev/null");info.nodeVersion=r.ok?r.output:"未安装";
  r=run("pm2 -v 2>/dev/null");info.pm2Version=r.ok?r.output:"未安装";
  r=run("nginx -v 2>&1");info.nginxVersion=r.ok||r.output?r.output.replace(/.*nginx\//,""):"未安装";
  res.json(info);
});

app.listen(PORT,()=>console.log("TC Manager running on port "+PORT));
SRVEOF
}

write_frontend(){
    cat > "$MGR_DIR/public/index.html" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>TeamChat Manager</title>
<style>
:root{--bg:#0f1117;--card:#1a1d27;--border:#2a2d3a;--text:#e4e4e7;--dim:#71717a;--accent:#6366f1;--accent2:#818cf8;--green:#22c55e;--red:#ef4444;--yellow:#eab308;--radius:10px}
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:'SF Mono',SFMono-Regular,ui-monospace,'Cascadia Code',Menlo,monospace;background:var(--bg);color:var(--text);min-height:100vh;font-size:14px}
a{color:var(--accent2);text-decoration:none}
#loginPage{display:flex;justify-content:center;align-items:center;height:100vh;background:linear-gradient(135deg,#0f1117 0%,#1e1b4b 100%)}
.login-box{background:var(--card);border:1px solid var(--border);border-radius:16px;padding:40px;width:340px;text-align:center}
.login-box h1{font-size:18px;margin-bottom:8px;color:var(--accent2)}
.login-box p{font-size:12px;color:var(--dim);margin-bottom:24px}
input[type=password],input[type=text],input[type=number],select{width:100%;padding:10px 14px;background:var(--bg);border:1px solid var(--border);border-radius:var(--radius);color:var(--text);font-family:inherit;font-size:13px;outline:none;margin-bottom:12px}
input:focus,select:focus{border-color:var(--accent)}
button,.btn{padding:10px 20px;background:var(--accent);color:#fff;border:none;border-radius:var(--radius);cursor:pointer;font-family:inherit;font-size:13px;font-weight:600;transition:all .15s}
button:hover,.btn:hover{background:var(--accent2);transform:translateY(-1px)}
.btn-sm{padding:6px 14px;font-size:12px}
.btn-red{background:var(--red)}.btn-red:hover{background:#dc2626}
.btn-green{background:var(--green)}.btn-green:hover{background:#16a34a}
.btn-ghost{background:transparent;border:1px solid var(--border);color:var(--dim)}.btn-ghost:hover{border-color:var(--accent);color:var(--text)}
#app{display:none}
.layout{display:flex;min-height:100vh}
.sidebar{width:220px;background:var(--card);border-right:1px solid var(--border);padding:16px;flex-shrink:0;display:flex;flex-direction:column}
.sidebar h2{font-size:14px;color:var(--accent2);margin-bottom:20px;padding-bottom:12px;border-bottom:1px solid var(--border)}
.nav-item{padding:10px 14px;border-radius:var(--radius);cursor:pointer;font-size:13px;color:var(--dim);transition:all .15s;margin-bottom:2px;display:flex;align-items:center;gap:10px}
.nav-item:hover,.nav-item.active{background:rgba(99,102,241,.1);color:var(--text)}
.nav-item.active{border-left:3px solid var(--accent);padding-left:11px}
.sidebar-footer{margin-top:auto;padding-top:16px;border-top:1px solid var(--border)}
.main{flex:1;padding:24px;overflow-y:auto;max-height:100vh}
.page-title{font-size:20px;font-weight:700;margin-bottom:20px;display:flex;align-items:center;gap:12px}
.card{background:var(--card);border:1px solid var(--border);border-radius:12px;padding:20px;margin-bottom:16px}
.card h3{font-size:14px;font-weight:600;margin-bottom:14px;color:var(--accent2)}
.grid{display:grid;gap:16px}
.grid-2{grid-template-columns:repeat(auto-fit,minmax(280px,1fr))}
.grid-3{grid-template-columns:repeat(auto-fit,minmax(200px,1fr))}
.grid-4{grid-template-columns:repeat(auto-fit,minmax(160px,1fr))}
.stat{text-align:center;padding:16px}
.stat-value{font-size:24px;font-weight:700;color:var(--accent2)}
.stat-label{font-size:11px;color:var(--dim);margin-top:4px;text-transform:uppercase;letter-spacing:1px}
.badge{display:inline-block;padding:3px 10px;border-radius:20px;font-size:11px;font-weight:600}
.badge-green{background:rgba(34,197,94,.15);color:var(--green)}
.badge-red{background:rgba(239,68,68,.15);color:var(--red)}
.badge-yellow{background:rgba(234,179,8,.15);color:var(--yellow)}
table{width:100%;border-collapse:collapse}
th,td{padding:10px 14px;text-align:left;border-bottom:1px solid var(--border);font-size:13px}
th{color:var(--dim);font-weight:600;font-size:11px;text-transform:uppercase;letter-spacing:.5px}
.actions{display:flex;gap:6px;flex-wrap:wrap}
.empty{text-align:center;padding:40px;color:var(--dim)}
.modal-overlay{position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,.6);display:flex;justify-content:center;align-items:center;z-index:1000}
.modal{background:var(--card);border:1px solid var(--border);border-radius:16px;padding:28px;width:90%;max-width:500px;max-height:80vh;overflow-y:auto}
.modal h3{margin-bottom:16px}
.modal label{display:block;font-size:12px;color:var(--dim);margin-bottom:6px;margin-top:12px}
.modal .btn-row{display:flex;gap:10px;justify-content:flex-end;margin-top:20px}
.log-box{background:#000;color:#0f0;font-family:monospace;padding:16px;border-radius:var(--radius);max-height:400px;overflow-y:auto;font-size:12px;line-height:1.6;white-space:pre-wrap;word-break:break-all}
.upload-zone{border:2px dashed var(--border);border-radius:var(--radius);padding:30px;text-align:center;cursor:pointer;transition:all .2s;color:var(--dim)}
.upload-zone:hover,.upload-zone.dragover{border-color:var(--accent);color:var(--text);background:rgba(99,102,241,.05)}
.toast{position:fixed;top:20px;right:20px;padding:12px 20px;border-radius:var(--radius);color:#fff;font-size:13px;z-index:2000;animation:slideIn .3s ease}
.toast-ok{background:var(--green)}.toast-err{background:var(--red)}
@keyframes slideIn{from{transform:translateX(100px);opacity:0}to{transform:translateX(0);opacity:1}}
.file-size{color:var(--dim);font-size:12px}
@media(max-width:768px){.sidebar{display:none}.main{padding:16px}.grid-2,.grid-3,.grid-4{grid-template-columns:1fr}}
</style>
</head>
<body>
<div id="loginPage">
  <div class="login-box">
    <h1>⚡ TeamChat Manager</h1>
    <p>聊天室管理面板</p>
    <input type="password" id="loginPass" placeholder="管理密码" onkeydown="if(event.key==='Enter')doLogin()">
    <button onclick="doLogin()" style="width:100%">登 录</button>
    <p id="loginErr" style="color:var(--red);margin-top:12px;font-size:12px"></p>
  </div>
</div>
<div id="app">
  <div class="layout">
    <div class="sidebar">
      <h2>⚡ TC Manager</h2>
      <div class="nav-item active" onclick="navigate('dashboard')">📊 仪表盘</div>
      <div class="nav-item" onclick="navigate('instances')">🖥️ 实例管理</div>
      <div class="nav-item" onclick="navigate('domains')">🔒 域名/SSL</div>
      <div class="nav-item" onclick="navigate('scripts')">📁 脚本版本</div>
      <div class="nav-item" onclick="navigate('users')">👥 用户数据</div>
      <div class="nav-item" onclick="navigate('backups')">💾 数据备份</div>
      <div class="sidebar-footer">
        <div class="nav-item" onclick="doLogout()">🚪 退出登录</div>
      </div>
    </div>
    <div class="main" id="mainContent"></div>
  </div>
</div>
<script>
const API="";
let token=localStorage.getItem("tc_token")||"";
let currentPage="dashboard";
let instancesCache=[];

async function api(url,opts={}){
  opts.headers=opts.headers||{};
  if(token)opts.headers["Authorization"]="Bearer "+token;
  if(opts.body&&typeof opts.body==="object"&&!(opts.body instanceof FormData)){opts.headers["Content-Type"]="application/json";opts.body=JSON.stringify(opts.body)}
  const r=await fetch(API+url,opts);
  if(r.status===401){showLogin();throw new Error("未登录")}
  return r.json();
}

function toast(msg,ok=true){const d=document.createElement("div");d.className="toast "+(ok?"toast-ok":"toast-err");d.textContent=msg;document.body.appendChild(d);setTimeout(()=>d.remove(),3000)}
function fmtSize(b){if(!b)return"0B";if(b<1024)return b+"B";if(b<1048576)return(b/1024).toFixed(1)+"KB";return(b/1048576).toFixed(1)+"MB"}
function fmtTime(t){if(!t)return"-";return new Date(t).toLocaleString("zh-CN")}

function showLogin(){document.getElementById("loginPage").style.display="flex";document.getElementById("app").style.display="none"}
function showApp(){document.getElementById("loginPage").style.display="none";document.getElementById("app").style.display="block";navigate(currentPage)}

async function doLogin(){
  const p=document.getElementById("loginPass").value;
  try{const d=await api("/api/login",{method:"POST",body:{password:p}});
    if(d.success){token=d.token;localStorage.setItem("tc_token",token);showApp()}
    else document.getElementById("loginErr").textContent=d.message;
  }catch(e){document.getElementById("loginErr").textContent="登录失败"}
}

function doLogout(){token="";localStorage.removeItem("tc_token");showLogin()}

function navigate(page){
  currentPage=page;
  document.querySelectorAll(".nav-item").forEach((n,i)=>{n.classList.toggle("active",n.textContent.includes({dashboard:"仪表",instances:"实例",domains:"域名",scripts:"脚本",users:"用户",backups:"备份"}[page]||"仪表"))});
  ({dashboard:renderDashboard,instances:renderInstances,domains:renderDomains,scripts:renderScripts,users:renderUsers,backups:renderBackups})[page]();
}

// ===== Dashboard =====
async function renderDashboard(){
  const[instances,sys]=await Promise.all([api("/api/instances"),api("/api/system")]);
  instancesCache=instances;
  const running=instances.filter(i=>i.status==="online").length;
  const sslCount=instances.filter(i=>i.ssl).length;
  const totalUsers=instances.reduce((s,i)=>s+i.userCount,0);
  const totalMsgs=instances.reduce((s,i)=>s+i.msgCount,0);
  document.getElementById("mainContent").innerHTML=`
    <div class="page-title">📊 仪表盘</div>
    <div class="grid grid-4">
      <div class="card stat"><div class="stat-value">${instances.length}</div><div class="stat-label">实例总数</div></div>
      <div class="card stat"><div class="stat-value" style="color:var(--green)">${running}</div><div class="stat-label">运行中</div></div>
      <div class="card stat"><div class="stat-value">${sslCount}</div><div class="stat-label">SSL已启用</div></div>
      <div class="card stat"><div class="stat-value">${totalUsers}</div><div class="stat-label">总用户数</div></div>
    </div>
    <div class="grid grid-2">
      <div class="card"><h3>🖥️ 系统信息</h3>
        <table>
          <tr><td style="color:var(--dim)">运行时间</td><td>${sys.uptime||"-"}</td></tr>
          <tr><td style="color:var(--dim)">内存</td><td>${sys.memUsed||"?"}/${sys.memTotal||"?"}</td></tr>
          <tr><td style="color:var(--dim)">磁盘</td><td>${sys.diskUsed||"?"}/${sys.diskTotal||"?"} (${sys.diskPercent||"?"})</td></tr>
          <tr><td style="color:var(--dim)">Node.js</td><td>${sys.nodeVersion||"-"}</td></tr>
          <tr><td style="color:var(--dim)">Nginx</td><td>${sys.nginxVersion||"-"}</td></tr>
        </table>
      </div>
      <div class="card"><h3>🖥️ 实例状态</h3>
        <table><thead><tr><th>名称</th><th>端口</th><th>域名</th><th>状态</th></tr></thead><tbody>
        ${instances.map(i=>`<tr><td>${i.name}</td><td>${i.port}</td><td>${i.domain?(i.ssl?"🔒 ":"")+""+i.domain:"-"}</td><td><span class="badge ${i.status==="online"?"badge-green":"badge-red"}">${i.status}</span></td></tr>`).join("")}
        </tbody></table>
        ${instances.length===0?'<div class="empty">暂无实例</div>':""}
      </div>
    </div>`;
}

// ===== Instances =====
async function renderInstances(){
  const instances=await api("/api/instances");instancesCache=instances;
  document.getElementById("mainContent").innerHTML=`
    <div class="page-title">🖥️ 实例管理</div>
    ${instances.map(i=>`
    <div class="card">
      <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:14px">
        <div><strong>${i.name}</strong> <span class="badge ${i.status==="online"?"badge-green":"badge-red"}">${i.status}</span>
          <span class="file-size" style="margin-left:8px">v${i.version} · 端口${i.port} · ${i.userCount}用户 · ${i.msgCount}消息 · DB ${fmtSize(i.dbSize)}</span></div>
        <div class="actions">
          <button class="btn-sm btn-green" onclick="instAction('${i.name}','start')">启动</button>
          <button class="btn-sm" onclick="instAction('${i.name}','restart')">重启</button>
          <button class="btn-sm btn-ghost" onclick="instAction('${i.name}','stop')">停止</button>
          <button class="btn-sm btn-ghost" onclick="showLogs('${i.name}')">日志</button>
          <button class="btn-sm btn-red" onclick="deleteInst('${i.name}')">删除</button>
        </div>
      </div>
      <div class="file-size">路径: ${i.dir}${i.domain?` · 域名: <strong>${i.domain}</strong>`:""}${i.ssl?' · <span class="badge badge-green">HTTPS</span>':""}${i.sslExpiry?` · 到期: ${i.sslExpiry}`:""}</div>
    </div>`).join("")}
    ${instances.length===0?'<div class="card empty">暂无部署的实例，请先上传脚本并部署</div>':""}`;
}

async function instAction(name,action){
  toast("执行中...");
  const d=await api(`/api/instances/${name}/${action}`,{method:"POST"});
  toast(d.success?`${action}成功`:d.output||"操作失败",d.success);
  setTimeout(()=>renderInstances(),1500);
}

async function deleteInst(name){
  if(!confirm(`确定要删除实例 ${name} 吗？数据目录会被标记删除。`))return;
  const d=await api(`/api/instances/${name}`,{method:"DELETE"});
  toast(d.message||"已删除",d.success);renderInstances();
}

async function showLogs(name){
  const d=await api(`/api/instances/${name}/logs`);
  showModal("📋 "+name+" 日志",`<div class="log-box">${escHtml(d.output||"无日志")}</div>`);
}

// ===== Scripts =====
async function renderScripts(){
  const scripts=await api("/api/scripts");
  document.getElementById("mainContent").innerHTML=`
    <div class="page-title">📁 脚本版本管理</div>
    <div class="card">
      <div class="upload-zone" id="dropZone" onclick="document.getElementById('scriptFile').click()"
        ondragover="event.preventDefault();this.classList.add('dragover')"
        ondragleave="this.classList.remove('dragover')"
        ondrop="event.preventDefault();this.classList.remove('dragover');uploadScript(event.dataTransfer.files[0])">
        📤 点击或拖拽上传 .sh 部署脚本
        <input type="file" id="scriptFile" accept=".sh" hidden onchange="uploadScript(this.files[0])">
      </div>
    </div>
    <div class="card"><h3>已上传的脚本</h3>
    ${scripts.length?`<table><thead><tr><th>文件名</th><th>版本</th><th>大小</th><th>上传时间</th><th>操作</th></tr></thead><tbody>
      ${scripts.map(s=>`<tr><td>${s.name}</td><td>${s.version||"-"}</td><td>${fmtSize(s.size)}</td><td>${fmtTime(s.time)}</td>
        <td class="actions">
          <button class="btn-sm btn-green" onclick="showDeployModal('${s.name}')">部署</button>
          <button class="btn-sm btn-red" onclick="deleteScript('${s.name}')">删除</button>
        </td></tr>`).join("")}
    </tbody></table>`:'<div class="empty">暂无上传的脚本</div>'}
    </div>`;
}

async function uploadScript(file){
  if(!file||!file.name.endsWith(".sh"))return toast("请选择 .sh 文件",false);
  const fd=new FormData();fd.append("script",file);
  const d=await api("/api/scripts/upload",{method:"POST",body:fd});
  toast(d.success?"上传成功":"上传失败",d.success);renderScripts();
}

async function deleteScript(name){
  if(!confirm("确定删除 "+name+"?"))return;
  await api("/api/scripts/"+name,{method:"DELETE"});renderScripts();
}

function showDeployModal(script){
  showModal("🚀 部署实例",`
    <label>脚本: <strong>${script}</strong></label>
    <label>实例名称 (留空=默认)</label><input type="text" id="dInstName" placeholder="如 team2">
    <label>端口</label><input type="number" id="dPort" value="3000">
    <label>管理员用户名</label><input type="text" id="dAdmin" value="admin">
    <label>管理员密码</label><input type="text" id="dPass" value="admin123">
    <div class="btn-row"><button class="btn-ghost" onclick="closeModal()">取消</button>
    <button onclick="doDeploy('${script}')">开始部署</button></div>
    <div id="deployLog" style="margin-top:16px"></div>`);
}

async function doDeploy(script){
  const body={script,instanceName:document.getElementById("dInstName").value,port:document.getElementById("dPort").value,adminUser:document.getElementById("dAdmin").value,adminPass:document.getElementById("dPass").value};
  const d=await api("/api/deploy",{method:"POST",body});
  if(!d.success)return toast(d.message,false);
  const logEl=document.getElementById("deployLog");
  logEl.innerHTML='<div class="log-box" id="deployLogBox">部署中...</div>';
  const poll=setInterval(async()=>{
    try{const r=await api("/api/deploy/"+d.jobId+"/log");
      document.getElementById("deployLogBox").textContent=r.log;
      document.getElementById("deployLogBox").scrollTop=999999;
      if(r.log.includes("部署成功")||r.log.includes("部署失败")){clearInterval(poll);toast(r.log.includes("部署成功")?"部署完成":"部署可能有问题",r.log.includes("部署成功"))}
    }catch(e){clearInterval(poll)}
  },2000);
}

// ===== Users =====
async function renderUsers(){
  const instances=instancesCache.length?instancesCache:await api("/api/instances");instancesCache=instances;
  const sel=instances[0]?.name||"";
  document.getElementById("mainContent").innerHTML=`
    <div class="page-title">👥 用户数据管理</div>
    <div class="card">
      <div style="display:flex;gap:12px;align-items:center;margin-bottom:16px">
        <label style="white-space:nowrap;color:var(--dim)">选择实例:</label>
        <select id="userInstSel" onchange="loadUsers()">
          ${instances.map(i=>`<option value="${i.name}">${i.name} (${i.userCount}人)</option>`).join("")}
        </select>
        <button class="btn-sm btn-green" onclick="showAddUser()">添加用户</button>
      </div>
      <div id="userTable"></div>
    </div>`;
  if(sel)loadUsers();
}

async function loadUsers(){
  const name=document.getElementById("userInstSel").value;if(!name)return;
  const users=await api(`/api/instances/${name}/users`);
  document.getElementById("userTable").innerHTML=users.length?`<table><thead><tr><th>ID</th><th>用户名</th><th>昵称</th><th>角色</th><th>注册时间</th><th>操作</th></tr></thead><tbody>
    ${users.map(u=>`<tr><td>${u.id}</td><td>${u.username}</td><td>${u.nickname||"-"}</td>
      <td>${u.is_admin?'<span class="badge badge-yellow">管理员</span>':'<span class="badge badge-green">用户</span>'}</td>
      <td>${fmtTime(u.created_at)}</td>
      <td class="actions"><button class="btn-sm btn-ghost" onclick="resetPwd('${name}',${u.id},'${u.username}')">重置密码</button>
      ${u.is_admin?"":`<button class="btn-sm btn-red" onclick="delUser('${name}',${u.id},'${u.username}')">删除</button>`}</td></tr>`).join("")}
  </tbody></table>`:'<div class="empty">该实例暂无用户</div>';
}

function showAddUser(){
  const name=document.getElementById("userInstSel")?.value;if(!name)return;
  showModal("添加用户到 "+name,`
    <label>用户名</label><input type="text" id="nuName">
    <label>密码</label><input type="text" id="nuPass">
    <label>昵称</label><input type="text" id="nuNick">
    <div class="btn-row"><button class="btn-ghost" onclick="closeModal()">取消</button>
    <button onclick="addUser('${name}')">添加</button></div>`);
}

async function addUser(inst){
  const d=await api(`/api/instances/${inst}/users`,{method:"POST",body:{username:document.getElementById("nuName").value,password:document.getElementById("nuPass").value,nickname:document.getElementById("nuNick").value}});
  toast(d.success?"添加成功":d.message,d.success);if(d.success){closeModal();loadUsers()}
}

async function resetPwd(inst,uid,uname){
  const pwd=prompt(`重置 ${uname} 的密码为:`,"")||"";if(!pwd)return;
  const d=await api(`/api/instances/${inst}/users/${uid}/reset-password`,{method:"POST",body:{password:pwd}});
  toast(d.success?"密码已重置":d.message,d.success);
}

async function delUser(inst,uid,uname){
  if(!confirm(`确定删除用户 ${uname}?`))return;
  const d=await api(`/api/instances/${inst}/users/${uid}`,{method:"DELETE"});
  toast(d.success?"已删除":d.message,d.success);loadUsers();
}

// ===== Domains / SSL =====
async function renderDomains(){
  const instances=await api("/api/instances");instancesCache=instances;
  document.getElementById("mainContent").innerHTML=`
    <div class="page-title">🔒 域名 / SSL 管理</div>
    ${instances.map(i=>`
    <div class="card">
      <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:12px">
        <div><strong>${i.name}</strong> <span class="file-size">端口 ${i.port}</span></div>
        <div>${i.ssl?'<span class="badge badge-green">🔒 HTTPS</span>':i.domain?'<span class="badge badge-yellow">⚠️ HTTP</span>':'<span class="badge badge-red">未绑定</span>'}</div>
      </div>
      <table>
        <tr><td style="color:var(--dim);width:100px">域名</td><td>${i.domain?`<strong>${i.domain}</strong>`:'<span style="color:var(--dim)">未绑定</span>'}</td></tr>
        <tr><td style="color:var(--dim)">SSL</td><td>${i.ssl?"已启用":'未启用'}</td></tr>
        ${i.sslExpiry?`<tr><td style="color:var(--dim)">证书到期</td><td>${i.sslExpiry}</td></tr>`:""}
        ${i.nginxConf?`<tr><td style="color:var(--dim)">Nginx配置</td><td class="file-size">${i.nginxConf}</td></tr>`:""}
      </table>
      <div class="actions" style="margin-top:14px">
        <button class="btn-sm" onclick="showBindDomain('${i.name}','${i.domain||""}')">🌐 ${i.domain?"修改":"绑定"}域名</button>
        ${i.domain&&!i.ssl?`<button class="btn-sm btn-green" onclick="showApplySSL('${i.name}','${i.domain}')">🔒 申请SSL</button>`:""}
        ${i.ssl?`<button class="btn-sm" onclick="renewSSL('${i.name}')">🔄 续期证书</button>`:""}
        ${i.ssl?`<button class="btn-sm btn-red" onclick="removeSSL('${i.name}')">🗑️ 卸载SSL</button>`:""}
        ${i.domain?`<button class="btn-sm btn-ghost" onclick="removeDomain('${i.name}')">✕ 解绑域名</button>`:""}
      </div>
    </div>`).join("")}
    ${instances.length===0?'<div class="card empty">暂无实例</div>':""}`;
}

function showBindDomain(name,current){
  showModal("🌐 绑定域名 — "+name,`
    <label>域名 (需已解析到本服务器IP)</label>
    <input type="text" id="bindDomain" placeholder="chat.example.com" value="${current}">
    <div style="font-size:12px;color:var(--dim);margin-top:-6px;margin-bottom:12px">请确保域名A记录已指向本服务器，否则SSL申请会失败</div>
    <div class="btn-row"><button class="btn-ghost" onclick="closeModal()">取消</button>
    <button onclick="doBindDomain('${name}')">绑定</button></div>`);
}

async function doBindDomain(name){
  const domain=document.getElementById("bindDomain").value.trim();
  if(!domain)return toast("请输入域名",false);
  const d=await api(`/api/instances/${name}/domain`,{method:"POST",body:{domain}});
  toast(d.message||"操作完成",d.success);
  if(d.success){closeModal();renderDomains()}
}

function showApplySSL(name,domain){
  showModal("🔒 申请SSL证书 — "+name,`
    <label>域名</label>
    <input type="text" value="${domain}" disabled style="opacity:.7">
    <label>邮箱 (用于证书通知，可选)</label>
    <input type="text" id="sslEmail" placeholder="admin@${domain}">
    <div style="font-size:12px;color:var(--dim);margin-bottom:12px">使用 Let's Encrypt 免费证书，有效期90天，自动续期</div>
    <div class="btn-row"><button class="btn-ghost" onclick="closeModal()">取消</button>
    <button class="btn-green" onclick="doApplySSL('${name}','${domain}')">开始申请</button></div>
    <div id="sslLog" style="margin-top:16px"></div>`);
}

async function doApplySSL(name,domain){
  const email=document.getElementById("sslEmail").value.trim();
  const d=await api(`/api/instances/${name}/ssl/apply`,{method:"POST",body:{domain,email}});
  if(!d.success)return toast(d.message,false);
  const logEl=document.getElementById("sslLog");
  logEl.innerHTML='<div class="log-box" id="sslLogBox">申请中，请稍候...</div>';
  const poll=setInterval(async()=>{
    try{const r=await api("/api/ssl/"+d.jobId+"/log");
      const box=document.getElementById("sslLogBox");
      if(box){box.textContent=r.log;box.scrollTop=999999}
      if(r.log.includes("成功")||r.log.includes("失败")){clearInterval(poll);
        toast(r.log.includes("成功")?"SSL证书申请成功！":"SSL申请可能失败",r.log.includes("成功"));
        setTimeout(()=>renderDomains(),2000);
      }
    }catch(e){clearInterval(poll)}
  },2000);
}

async function renewSSL(name){
  toast("正在续期...");
  const d=await api(`/api/instances/${name}/ssl/renew`,{method:"POST"});
  toast(d.message||"操作完成",d.success);if(d.success)renderDomains();
}

async function removeSSL(name){
  if(!confirm("确定卸载SSL证书？将回退为HTTP访问。"))return;
  const d=await api(`/api/instances/${name}/ssl/remove`,{method:"POST"});
  toast(d.message||"操作完成",d.success);renderDomains();
}

async function removeDomain(name){
  if(!confirm("确定解绑域名？SSL证书也将一并移除。"))return;
  const d=await api(`/api/instances/${name}/domain/remove`,{method:"POST"});
  toast(d.message||"操作完成",d.success);renderDomains();
}

// ===== Backups =====
async function renderBackups(){
  const instances=instancesCache.length?instancesCache:await api("/api/instances");instancesCache=instances;
  const backups=await api("/api/backups");
  document.getElementById("mainContent").innerHTML=`
    <div class="page-title">💾 数据备份</div>
    <div class="card">
      <h3>创建备份</h3>
      <div style="display:flex;gap:12px;align-items:center">
        <select id="backupInstSel">${instances.map(i=>`<option value="${i.name}">${i.name}</option>`).join("")}</select>
        <button class="btn-sm btn-green" onclick="doBackup()">立即备份</button>
      </div>
    </div>
    <div class="card"><h3>备份列表</h3>
    ${backups.length?`<table><thead><tr><th>文件名</th><th>大小</th><th>时间</th><th>操作</th></tr></thead><tbody>
      ${backups.map(b=>`<tr><td>${b.name}</td><td>${fmtSize(b.size)}</td><td>${fmtTime(b.time)}</td>
        <td class="actions"><a class="btn btn-sm btn-ghost" href="/api/backups/${encodeURIComponent(b.name)}/download" target="_blank">下载</a>
        <button class="btn-sm btn-red" onclick="delBackup('${b.name}')">删除</button></td></tr>`).join("")}
    </tbody></table>`:'<div class="empty">暂无备份</div>'}
    </div>`;
}

async function doBackup(){
  const name=document.getElementById("backupInstSel").value;
  const d=await api(`/api/instances/${name}/backup`,{method:"POST"});
  toast(d.success?"备份成功: "+d.name:d.message,d.success);renderBackups();
}

async function delBackup(name){
  if(!confirm("删除备份 "+name+"?"))return;
  await api("/api/backups/"+name,{method:"DELETE"});renderBackups();
}

// ===== Modal =====
function showModal(title,html){
  const m=document.createElement("div");m.className="modal-overlay";m.id="modal";
  m.innerHTML=`<div class="modal"><h3>${title}</h3>${html}</div>`;
  m.addEventListener("click",e=>{if(e.target===m)closeModal()});
  document.body.appendChild(m);
}
function closeModal(){document.getElementById("modal")?.remove()}
function escHtml(s){const d=document.createElement("div");d.textContent=s;return d.innerHTML}

// Init
(async()=>{
  if(token){try{await api("/api/instances");showApp()}catch(e){showLogin()}}else showLogin();
})();
</script>
</body>
</html>
HTMLEOF
}

do_start(){
    if pm2 describe $MGR_PM2 >/dev/null 2>&1;then pm2 restart $MGR_PM2;else cd "$MGR_DIR"&&pm2 start server.js --name $MGR_PM2&&pm2 save;fi
    echo -e "${GREEN}✅ 已启动${NC}"
}

do_stop(){ pm2 stop $MGR_PM2 2>/dev/null;echo -e "${GREEN}✅ 已停止${NC}"; }

do_logs(){ pm2 logs $MGR_PM2 --lines 50 --nostream; }

do_modify(){
    echo -e "\n${YELLOW}修改配置${NC}"
    echo "  1. 修改密码  2. 修改端口  0. 返回"
    printf "选择: ";read -r c
    case $c in
        1) printf "新密码: ";read -r np;if [ -z "$np" ]; then return;fi
           sed -i "s/^ADMIN_PASS=.*/ADMIN_PASS=$np/" "$MGR_DIR/.env"
           pm2 restart $MGR_PM2 2>/dev/null;echo -e "${GREEN}✅ 密码已修改${NC}" ;;
        2) printf "新端口: ";read -r np;if [[ ! "$np" =~ ^[0-9]+$ ]]; then return;fi
           sed -i "s/^PORT=.*/PORT=$np/" "$MGR_DIR/.env"
           pm2 restart $MGR_PM2 2>/dev/null;echo -e "${GREEN}✅ 端口已改为 $np${NC}" ;;
    esac
}

do_uninstall(){
    echo -e "${YELLOW}卸载管理面板${NC}"
    echo -e "  ${GREEN}注意: 卸载管理面板不会影响已部署的聊天室${NC}"
    printf "确认卸载? (y/n): ";read -r c;if [ "$c" != "y" ]; then return;fi
    pm2 stop $MGR_PM2 2>/dev/null||true
    pm2 delete $MGR_PM2 2>/dev/null||true
    pm2 save 2>/dev/null||true
    rm -rf "$MGR_DIR"
    echo -e "${GREEN}✅ 管理面板已卸载，聊天室不受影响${NC}"
}

# ===== 主逻辑 =====
check_root
if [ $# -gt 0 ];then
    case $1 in
        --install|-i) do_install;exit 0;;
        --uninstall|-u) do_uninstall;exit 0;;
        --help|-h) echo "用法: sudo $0 [--install|--uninstall|--help]";exit 0;;
    esac
fi

while true;do
    print_menu;read choice
    case $choice in 1)do_install;;2)do_start;;3)do_stop;;4)do_logs;;5)do_modify;;6)do_uninstall;;0)echo "再见";exit 0;;*)echo -e "${RED}无效${NC}";;esac
    echo ""
done
