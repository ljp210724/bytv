#!/usr/bin/env bash
set -euo pipefail
export LANG=C.UTF-8 LC_ALL=C.UTF-8

APP="DecoTV"
DIR="/opt/decotv"; ENVF="$DIR/.env"; YML="$DIR/docker-compose.yml"

C1="decotv-core"; C2="decotv-kvrocks"
IMG1="ghcr.io/decohererk/decotv:latest"; IMG2="apache/kvrocks:latest"

# 域名反代：Docker Nginx + acme.sh standalone + 证书挂载 + nginx.conf 挂载
NGX_DIR="$DIR/nginx"
NGX_CONF="$NGX_DIR/nginx.conf"
NGX_CERTS="$NGX_DIR/certs"
NGX_C="decotv-nginx"
NGX_IMG="nginx:latest"

need_root(){ [[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo "请用 root 运行（sudo -i）"; exit 1; }; }
has(){ command -v "$1" >/dev/null 2>&1; }
pm(){ has apt-get&&echo apt||has dnf&&echo dnf||has yum&&echo yum||has pacman&&echo pacman||echo none; }
pause(){ read -r -p "按回车继续..." _ || true; }
installed(){ [[ -f "$ENVF" && -f "$YML" ]]; }
compose(){ (cd "$DIR" && docker compose --env-file "$ENVF" "$@"); }
kv(){ grep -E "^$1=" "$ENVF" 2>/dev/null | head -n1 | cut -d= -f2- || true; }

inst_pkgs(){
  local m; m="$(pm)"
  case "$m" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null
         DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" >/dev/null ;;
    dnf) dnf install -y "$@" >/dev/null ;;
    yum) yum install -y "$@" >/dev/null ;;
    pacman) pacman -Sy --noconfirm "$@" >/dev/null ;;
    *) echo "不支持的包管理器，请手动安装：$*"; exit 1 ;;
  esac
}

ensure(){
  has curl || inst_pkgs curl ca-certificates
  if ! has docker; then curl -fsSL https://get.docker.com | sh; fi
  has systemctl && systemctl enable --now docker >/dev/null 2>&1 || true
  docker compose version >/dev/null 2>&1 || inst_pkgs docker-compose-plugin || true
  docker compose version >/dev/null 2>&1 || { echo "Docker Compose 不可用，请手动安装 compose 插件"; exit 1; }
}

ip(){
  curl -fsSL https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}'
}

inuse(){ has ss && ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1$"; }
pick_port(){
  local p="${1:-3000}"
  if [[ "$p" =~ ^[0-9]+$ ]] && ((p>=1&&p<=65535)) && ! inuse "$p"; then echo "$p"; return; fi
  for x in 3000 3001 3030 3080 3100 3200 8080 18080; do ! inuse "$x" && { echo "$x"; return; }; done
  while :; do x="$(shuf -i 20000-60000 -n 1 2>/dev/null || echo 3000)"; ! inuse "$x" && { echo "$x"; return; }; done
}

访问地址(){
  installed || { echo "未安装"; return; }
  local host p
  host="$(ip || true)"; [[ -z "${host:-}" ]] && host="<服务器IP>"
  p="$(kv APP_PORT)"
  echo "http://${host}:${p:-?}"
}

运行状态(){
  installed || { echo "未安装"; return; }
  local n
  n="$(compose ps --status running 2>/dev/null | awk 'NR>1{print $1}' | wc -l | tr -d ' ')"
  [[ "$n" == "2" ]] && echo "运行中" || echo "未完全运行"
}

c_state(){ docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null || echo "不存在"; }
c_health(){ docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}无健康检查{{end}}' "$1" 2>/dev/null || echo "-"; }
c_ports(){ docker port "$1" 2>/dev/null | head -n1 | tr -d '\r' || echo "-"; }

状态摘要(){
  echo "------------------------------"
  echo "服务状态（紧凑版）"
  echo "------------------------------"
  printf "%-14s | %-8s | %s\n" "容器" "状态" "端口/健康"
  echo "------------------------------"
  printf "%-14s | %-8s | %s\n" "$C1" "$(c_state "$C1")" "$(c_ports "$C1")"
  printf "%-14s | %-8s | %s\n" "$C2" "$(c_state "$C2")" "$(c_health "$C2")"
  printf "%-14s | %-8s | %s\n" "$NGX_C" "$(c_state "$NGX_C")" "$(c_ports "$NGX_C")"
  echo "------------------------------"
}

write_cfg(){
  local port="$1" user="$2" pass="$3"
  mkdir -p "$DIR"
  cat >"$ENVF" <<EOF
USERNAME=$user
PASSWORD=$pass
APP_PORT=$port
EOF
  cat >"$YML" <<'EOF'
services:
  decotv-core:
    image: ghcr.io/decohererk/decotv:latest
    container_name: decotv-core
    restart: on-failure
    ports: ["${APP_PORT}:3000"]
    environment:
      - USERNAME=${USERNAME}
      - PASSWORD=${PASSWORD}
      - NEXT_PUBLIC_STORAGE_TYPE=kvrocks
      - KVROCKS_URL=redis://decotv-kvrocks:6666
    networks: [decotv-network]
    depends_on: [decotv-kvrocks]
  decotv-kvrocks:
    image: apache/kvrocks:latest
    container_name: decotv-kvrocks
    restart: unless-stopped
    volumes: [kvrocks-data:/var/lib/kvrocks]
    networks: [decotv-network]
networks: { decotv-network: { driver: bridge } }
volumes: { kvrocks-data: {} }
EOF
}

安装快捷指令(){ return 0; }

部署完成输出(){
  local host p user pass
  host="$(ip || true)"; [[ -z "${host:-}" ]] && host="<服务器IP>"
  p="$(kv APP_PORT)"; user="$(kv USERNAME)"; pass="$(kv PASSWORD)"
  echo
  echo "=============================="
  echo " DecoTV 部署完成"
  echo "=============================="
  echo "访问地址：http://${host}:${p}"
  echo "端口映射：${p}:3000"
  echo "账号：${user}"
  echo "密码：${pass}"
  echo
  echo "常用命令："
  echo "  日志：docker logs -f --tail=200 ${C1}"
  echo "  更新：decotv -> 更新"
  echo "  卸载：decotv -> 卸载"
  echo
}

# ------------------------------
# 域名反代 + HTTPS
# ------------------------------

domain_resolve_ip(){
  local d="$1"
  if has getent; then
    getent ahosts "$d" 2>/dev/null | awk '{print $1}' | head -n1
  elif has dig; then
    dig +short A "$d" 2>/dev/null | head -n1
  else
    echo ""
  fi
}

ensure_acme(){
  has socat || inst_pkgs socat || true
  if [[ ! -x "${HOME}/.acme.sh/acme.sh" ]]; then
    curl -fsSL https://get.acme.sh | sh >/dev/null 2>&1 || true
  fi
  [[ -x "${HOME}/.acme.sh/acme.sh" ]] || { echo "acme.sh 安装失败，请检查网络后重试"; return 1; }

  # 强制使用 Let's Encrypt，避免 ZeroSSL/EAB 报错
  "${HOME}/.acme.sh/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
  "${HOME}/.acme.sh/acme.sh" --upgrade --auto-upgrade >/dev/null 2>&1 || true
}

write_nginx_conf(){
  local domain="$1" backend_port="$2"
  mkdir -p "$NGX_DIR" "$NGX_CERTS"
  cat >"$NGX_CONF" <<EOF
events { worker_connections 1024; }
http {
  client_max_body_size 1000m;

  server {
    listen 80;
    server_name ${domain};
    return 301 https://\$host\$request_uri;
  }

  server {
    listen 443 ssl http2;
    server_name ${domain};

    ssl_certificate /etc/nginx/certs/cert.pem;
    ssl_certificate_key /etc/nginx/certs/key.pem;

    location / {
      proxy_pass http://127.0.0.1:${backend_port};
      proxy_set_header Host \$host;
      proxy_set_header X-Real-IP \$remote_addr;
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
  }
}
EOF
}

run_nginx_container(){
  docker rm -f "$NGX_C" >/dev/null 2>&1 || true
  docker run -d \
    --name "$NGX_C" \
    -p 80:80 -p 443:443 \
    -v "$NGX_CONF:/etc/nginx/nginx.conf" \
    -v "$NGX_CERTS:/etc/nginx/certs" \
    "$NGX_IMG" >/dev/null
  docker update --restart=always "$NGX_C" >/dev/null 2>&1 || true
}

绑定域名反代(){
  installed || { echo "未安装，请先部署"; return; }

  if inuse 80 || inuse 443; then
    echo "检测到 80/443 已被占用："
    inuse 80 && echo " - 80 端口占用（standalone 需要 80）"
    inuse 443 && echo " - 443 端口占用（nginx 需要 443）"
    echo "请先释放 80/443 后再绑定域名。"
    return
  fi

  read -r -p "请输入域名（A 记录指向本机公网 IP）：" domain
  [[ -n "${domain:-}" ]] || { echo "域名不能为空"; return; }

  local sip dip
  sip="$(ip || true)"
  dip="$(domain_resolve_ip "$domain" || true)"
  if [[ -n "${sip:-}" && -n "${dip:-}" && "$sip" != "$dip" ]]; then
    echo "警告：域名解析 IP = ${dip}，本机公网 IP = ${sip}"
    echo "如果开启了 Cloudflare 橙云代理，请先切灰云再签证书。"
    read -r -p "仍继续？(y/n) [n]：" a
    [[ "${a:-n}" == "y" ]] || { echo "已取消"; return; }
  fi

  ensure_acme || return

  # ✅ 关键修复：installcert 之前必须先创建证书目录
  mkdir -p "$NGX_DIR" "$NGX_CERTS"

  echo "开始申请证书（standalone / Let's Encrypt）：$domain"
  "${HOME}/.acme.sh/acme.sh" --issue -d "$domain" --standalone --server letsencrypt \
    || { echo "证书签发失败（常见原因：80 不通 / 解析未生效 / 橙云代理 / 防火墙拦截）"; return; }

  "${HOME}/.acme.sh/acme.sh" --installcert -d "$domain" \
    --key-file "$NGX_CERTS/key.pem" \
    --fullchain-file "$NGX_CERTS/cert.pem" >/dev/null \
    || { echo "证书安装失败"; return; }

  local backend_port
  backend_port="$(kv APP_PORT)"
  [[ -n "${backend_port:-}" ]] || { echo "读取 APP_PORT 失败"; return; }

  write_nginx_conf "$domain" "$backend_port"
  run_nginx_container

  echo
  echo "=============================="
  echo " 域名反代已配置完成"
  echo "=============================="
  echo "访问地址：https://${domain}"
  echo "后端：127.0.0.1:${backend_port}"
  echo "nginx容器：${NGX_C}"
  echo
}

部署(){
  ensure
  if installed; then
    read -r -p "检测到已安装，是否覆盖并重建？(y/n) [n]：" a
    [[ "${a:-n}" == "y" ]] || { echo "已取消"; return; }
  fi

  read -r -p "设置用户名 [admin]：" user; user="${user:-admin}"
  while :; do
    read -r -p "设置密码（可见）：" p1
    read -r -p "再次确认（可见）：" p2
    [[ -n "${p1:-}" ]] || { echo "密码不能为空"; continue; }
    [[ "$p1" == "$p2" ]] || { echo "两次密码不一致"; continue; }
    break
  done

  read -r -p "外部访问端口 [3000]：" pp; pp="${pp:-3000}"
  port="$(pick_port "$pp")"
  [[ "$port" != "$pp" ]] && echo "端口 $pp 已占用，自动选用：$port"

  write_cfg "$port" "$user" "$p1"
  compose up -d
  安装快捷指令

  read -r -p "是否绑定域名并配置 HTTPS 反代（占用80/443）？(y/n) [n]：" a
  [[ "${a:-n}" == "y" ]] && 绑定域名反代 || true

  状态摘要
  部署完成输出
}

更新(){
  ensure; installed || { echo "未安装，请先部署"; return; }
  compose pull; compose up -d
  echo "更新完成：$(访问地址)"
  状态摘要
}

状态(){
  ensure; installed || { echo "未安装"; return; }
  echo "运行状态：$(运行状态)"
  echo "访问地址：$(访问地址)"
  if [[ "$(c_state "$NGX_C")" == "running" ]]; then
    echo "域名反代：已启用（${NGX_C}）"
  else
    echo "域名反代：未启用/未运行"
  fi
  状态摘要
  echo "账号：$(kv USERNAME)"
  read -r -p "是否显示密码？(y/n) [n]：" a
  [[ "${a:-n}" == "y" ]] && echo "密码：$(kv PASSWORD)"
}

日志(){
  ensure; installed || { echo "未安装"; return; }
  echo "1) 核心(core)日志"
  echo "2) 数据库(kvrocks)日志"
  echo "3) 反代(nginx)日志"
  echo "0) 返回"
  read -r -p "请选择 [0-3]：" c
  case "${c:-}" in
    1) echo "提示：按 Ctrl+C 退出日志"; docker logs -f --tail=200 "$C1" ;;
    2) echo "提示：按 Ctrl+C 退出日志"; docker logs -f --tail=200 "$C2" ;;
    3) echo "提示：按 Ctrl+C 退出日志"; docker logs -f --tail=200 "$NGX_C" ;;
    0) return ;;
    *) echo "无效选择" ;;
  esac
}

卸载(){
  ensure
  echo "将执行：停止并删除容器/卷/网络/目录，并尝试删除镜像；最后删除脚本本体。"
  read -r -p "确认卸载？(y/n) [n]：" a
  [[ "${a:-n}" == "y" ]] || { echo "已取消"; return; }

  if installed; then
    (cd "$DIR" && docker compose --env-file "$ENVF" down -v --remove-orphans) || true
  fi
  docker rm -f "$C1" >/dev/null 2>&1 || true
  docker rm -f "$C2" >/dev/null 2>&1 || true
  docker rm -f "$NGX_C" >/dev/null 2>&1 || true

  docker network rm decotv-network >/dev/null 2>&1 || true
  docker volume rm kvrocks-data >/dev/null 2>&1 || true

  docker rmi -f "$IMG1" >/dev/null 2>&1 || true
  docker rmi -f "$IMG2" >/dev/null 2>&1 || true
  docker rmi -f "$NGX_IMG" >/dev/null 2>&1 || true

  rm -rf "$DIR" || true

  echo "卸载完成，即将删除脚本本体并退出。"

  ( sleep 1; rm -f "$0" >/dev/null 2>&1 || true ) &
  exit 0
}

清理(){
  ensure
  echo "仅清理未使用资源：停止容器/悬空镜像/未使用网络/未使用卷"
  read -r -p "确认清理？(y/n) [n]：" a
  [[ "${a:-n}" == "y" ]] || { echo "已取消"; return; }
  docker system prune -f >/dev/null 2>&1 || true
  docker volume prune -f >/dev/null 2>&1 || true
  echo "清理完成"
}

菜单(){
  clear 2>/dev/null || true
  echo "=============================="
  echo " ${APP} · 交互式管理面板"
  echo "=============================="
  echo "当前状态：$(运行状态) ｜ 访问：$(访问地址)"
  if [[ "$(c_state "$NGX_C")" == "running" ]]; then
    echo "域名反代：已启用（${NGX_C}）"
  else
    echo "域名反代：未启用"
  fi
  echo
  echo "1) 部署 / 重装"
  echo "2) 更新（拉取最新镜像）"
  echo "3) 状态（查看信息）"
  echo "4) 日志（实时跟踪）"
  echo "5) 卸载（彻底删除）"
  echo "6) 清理（Docker 垃圾清理）"
  echo "7) 域名反代（配置HTTPS反代）"
  echo "0) 退出"
  echo
}

main(){
  need_root
  while :; do
    菜单
    read -r -p "请选择 [0-7]：" c
    case "${c:-}" in
      1) 部署; pause ;;
      2) 更新; pause ;;
      3) 状态; pause ;;
      4) 日志 ;;
      5) 卸载 ;;
      6) 清理; pause ;;
      7) 绑定域名反代; pause ;;
      0) exit 0 ;;
      *) echo "无效选择"; pause ;;
    esac
  done
}

main "$@"
