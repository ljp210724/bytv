#!/usr/bin/env bash
set -euo pipefail
export LANG=C.UTF-8 LC_ALL=C.UTF-8

APP="DecoTV"
DIR="/opt/decotv"
ENVF="$DIR/.env"
YML="$DIR/docker-compose.yml"

C1="decotv-core"
C2="decotv-kvrocks"

NGX_DIR="$DIR/nginx"
NGX_CONF="$NGX_DIR/nginx.conf"
NGX_CERTS="$NGX_DIR/certs"
NGX_C="decotv-nginx"
NGX_IMG="nginx:latest"

need_root(){ [[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo "请用 root 运行（sudo -i）"; exit 1; }; }
has(){ command -v "$1" >/dev/null 2>&1; }
pause(){ read -r -p "按回车继续..." _ || true; }
installed(){ [[ -f "$ENVF" && -f "$YML" ]]; }
compose(){ (cd "$DIR" && docker compose --env-file "$ENVF" "$@"); }
kv(){ grep -E "^$1=" "$ENVF" 2>/dev/null | cut -d= -f2- || true; }

ensure(){
  has curl || apt-get install -y curl ca-certificates
  has docker || curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker >/dev/null 2>&1 || true
  docker compose version >/dev/null 2>&1 || apt-get install -y docker-compose-plugin
}

ip(){ curl -fsSL https://api.ipify.org || hostname -I | awk '{print $1}'; }

detect_upstream_port(){
  docker port "$C1" 2>/dev/null | awk -F: 'NR==1{print $2}'
}

访问地址(){
  local domain
  domain="$(kv RP_DOMAIN)"
  if [[ -n "$domain" ]]; then
    echo "https://${domain}"
  else
    echo "http://$(ip):$(kv APP_PORT)"
  fi
}

运行状态(){
  docker inspect -f '{{.State.Status}}' "$C1" 2>/dev/null || echo "未运行"
}

状态摘要(){
  echo "------------------------------"
  echo "运行状态：$(运行状态)"
  if [[ -n "$(kv RP_DOMAIN)" ]]; then
    echo "反代状态：已启用"
    echo "绑定域名：$(kv RP_DOMAIN)"
    echo "上游端口：$(kv RP_UPSTREAM)"
  else
    echo "反代状态：未启用"
  fi
  echo "访问地址：$(访问地址)"
  echo "------------------------------"
}

write_cfg(){
  mkdir -p "$DIR"
  cat >"$ENVF" <<EOF
USERNAME=$1
PASSWORD=$2
APP_PORT=$3
EOF

  cat >"$YML" <<'EOF'
services:
  decotv-core:
    image: ghcr.io/decohererk/decotv:latest
    container_name: decotv-core
    restart: unless-stopped
    ports:
      - "${APP_PORT}:3000"
    environment:
      - USERNAME=${USERNAME}
      - PASSWORD=${PASSWORD}
      - NEXT_PUBLIC_STORAGE_TYPE=kvrocks
      - KVROCKS_URL=redis://decotv-kvrocks:6666
  decotv-kvrocks:
    image: apache/kvrocks:latest
    container_name: decotv-kvrocks
    restart: unless-stopped
EOF
}

ensure_acme(){
  has socat || apt-get install -y socat
  [[ -x "$HOME/.acme.sh/acme.sh" ]] || curl -fsSL https://get.acme.sh | sh
  "$HOME/.acme.sh/acme.sh" --set-default-ca --server letsencrypt >/dev/null
}

write_nginx_conf(){
  cat >"$NGX_CONF" <<EOF
events {}
http {
  server {
    listen 80;
    server_name $1;
    return 301 https://\$host\$request_uri;
  }
  server {
    listen 443 ssl;
    server_name $1;
    ssl_certificate /etc/nginx/certs/cert.pem;
    ssl_certificate_key /etc/nginx/certs/key.pem;
    location / {
      proxy_pass http://127.0.0.1:$2;
      proxy_set_header Host \$host;
      proxy_set_header X-Forwarded-For \$remote_addr;
    }
  }
}
EOF
}

run_nginx(){
  docker rm -f "$NGX_C" >/dev/null 2>&1 || true
  docker run -d --name "$NGX_C" \
    -p 80:80 -p 443:443 \
    -v "$NGX_CONF:/etc/nginx/nginx.conf" \
    -v "$NGX_CERTS:/etc/nginx/certs" \
    "$NGX_IMG" >/dev/null
}

绑定域名反代(){
  read -r -p "请输入域名：" domain
  ensure_acme
  mkdir -p "$NGX_CERTS"

  "$HOME/.acme.sh/acme.sh" --issue -d "$domain" --standalone || true
  "$HOME/.acme.sh/acme.sh" --installcert -d "$domain" \
    --key-file "$NGX_CERTS/key.pem" \
    --fullchain-file "$NGX_CERTS/cert.pem"

  local up
  up="$(detect_upstream_port)"
  write_nginx_conf "$domain" "$up"
  run_nginx

  sed -i '/^RP_/d' "$ENVF"
  echo "RP_DOMAIN=$domain" >>"$ENVF"
  echo "RP_UPSTREAM=$up" >>"$ENVF"
}

部署(){
  ensure
  read -r -p "用户名 [admin]：" u; u="${u:-admin}"
  read -r -p "密码：" p
  read -r -p "外部端口 [3000]：" port; port="${port:-3000}"
  write_cfg "$u" "$p" "$port"
  compose up -d
  read -r -p "是否绑定域名并开启 HTTPS？(y/n)：" a
  [[ "$a" == "y" ]] && 绑定域名反代
  状态摘要
}

菜单(){
  clear
  echo "=============================="
  echo " ${APP} · 交互式管理面板"
  echo "=============================="
  echo "访问：$(访问地址)"
  echo
  echo "1) 部署 / 重装"
  echo "2) 状态"
  echo "3) 日志"
  echo "4) 卸载"
  echo "5) 域名反代"
  echo "0) 退出"
}

main(){
  need_root
  while :; do
    菜单
    read -r -p "请选择：" c
    case "$c" in
      1) 部署; pause ;;
      2) 状态摘要; pause ;;
      3) docker logs -f "$C1" ;;
      4) docker compose -f "$YML" down -v; rm -rf "$DIR"; exit ;;
      5) 绑定域名反代; pause ;;
      0) exit ;;
    esac
  done
}

main
