#!/bin/bash
set -e

# entra no diretório do script (para suportar git clone)
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Quem chamou o sudo
TARGET_USER="${SUDO_USER:-$USER}"

# Pastas agora relativas ao projeto
STACK_DIR="$(pwd)"                  # docker-compose.yml ficará aqui
APP_DATA="$STACK_DIR/app-data"     # dados do Nextcloud em ./app-data
PORT=8443

# Exigir root
[[ "$EUID" -eq 0 ]] || { echo "Use o comando sudo ./nextcloud_install.sh"; exit 1; }

clear
echo "====================================================="
echo " SCRIPT DE INSTALAÇÃO AUTOMÁTICA:"
echo "  - Docker e Docker Compose"
echo "  - Tailscale (VPN mesh)"
echo "  - OpenSSL (para gerar certificado)"
echo "  - Nextcloud Stack (MariaDB, Redis, OnlyOffice + proxy HTTPS autoassinado)"
echo "====================================================="
read -p "Prosseguir? [s/N]: " RESP
RESP=${RESP,,}
[[ "$RESP" == "s" || "$RESP" == "sim" ]] || { echo "Cancelado."; exit 0; }

# ------------- pergunta usuário e senha ------------
read -p "Usuário administrador do Nextcloud [admin]: " NC_USER
NC_USER=${NC_USER:-admin}

while [[ -z "$NC_PASS" ]]; do
  read -s -p "Senha para o usuário \"$NC_USER\": " NC_PASS
  echo
done
echo "Usuário \"$NC_USER\" será criado no Nextcloud."
# ----------------------------------------------------

# ---------- Pré-requisitos ----------
install_docker_if_needed() {
  if ! command -v docker &>/dev/null; then
    echo "🐳 Instalando Docker..."
    apt-get update
    apt-get install -y ca-certificates curl gnupg lsb-release
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
      | tee /etc/apt/sources.list.d/docker.list >/dev/null
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io
  else
    echo "🐳 Docker já instalado."
  fi

  if ! command -v docker-compose &>/dev/null && ! docker compose version &>/dev/null; then
    echo "🔧 Instalando Docker Compose..."
    curl -L "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" \
      -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
  else
    echo "🔧 Docker Compose já instalado."
  fi
}

install_tailscale_if_needed() {
  if ! command -v tailscale &>/dev/null; then
    echo "🔗 Instalando Tailscale..."
    curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/jammy.noarmor.gpg \
      | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
    echo "deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] \
https://pkgs.tailscale.com/stable/ubuntu jammy main" \
      | tee /etc/apt/sources.list.d/tailscale.list >/dev/null
    apt-get update
    apt-get install -y tailscale
  else
    echo "🔗 Tailscale já instalado."
  fi
}

install_openssl_if_needed() {
  if command -v openssl &>/dev/null; then
    echo "🔒 OpenSSL já instalado."
  else
    echo "🔒 Instalando OpenSSL..."
    apt-get update
    apt-get install -y openssl
  fi
}

# ---------- Instala o stack ----------
install_nextcloud_stack() {
  mkdir -p "$APP_DATA/nginx/certs" "$APP_DATA/nginx" "$APP_DATA"

  CERT="$APP_DATA/nginx/certs/selfsigned.crt"
  KEY="$APP_DATA/nginx/certs/selfsigned.key"
  if [[ ! -f "$CERT" ]]; then
    echo "🔑 Gerando certificado autoassinado..."
    openssl req -x509 -nodes -newkey rsa:4096 -days 3650 \
      -keyout "$KEY" -out "$CERT" -subj "/CN=nextcloud"
  fi

  # nginx.conf
  cat >"$APP_DATA/nginx/nginx.conf" <<'EOF'
events {}
http {
  server {
    listen 443 ssl;
    server_name _;
    ssl_certificate /certs/selfsigned.crt;
    ssl_certificate_key /certs/selfsigned.key;

    location / {
      proxy_pass http://nextcloud:80;
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto https;
      client_max_body_size 1024M;
    }
  }
}
EOF

  # docker-compose.yml
  cat >"$APP_DATA/docker-compose.yml" <<EOF
services:
  nextcloud:
    image: nextcloud:latest
    container_name: nextcloud
    restart: unless-stopped
    environment:
      - MYSQL_HOST=mariadb
      - MYSQL_DATABASE=nextcloud_db
      - MYSQL_USER=nextcloud
      - MYSQL_PASSWORD=nextcloudpassword
      - REDIS_HOST=redis
      - NEXTCLOUD_ADMIN_USER=${NC_USER}
      - NEXTCLOUD_ADMIN_PASSWORD=${NC_PASS}
    volumes:
      - ${APP_DATA}/nextcloud:/var/www/html
    depends_on:
      - mariadb
      - redis

  mariadb:
    image: mariadb:latest
    container_name: nextcloud_mariadb
    restart: unless-stopped
    environment:
      - MYSQL_ROOT_PASSWORD=rootpassword
      - MYSQL_DATABASE=nextcloud_db
      - MYSQL_USER=nextcloud
      - MYSQL_PASSWORD=nextcloudpassword
    volumes:
      - ${APP_DATA}/mariadb:/var/lib/mysql

  redis:
    image: redis:latest
    container_name: nextcloud_redis
    restart: unless-stopped
    command: ["redis-server", "--appendonly", "yes"]
    volumes:
      - ${APP_DATA}/redis:/data

  nginx:
    image: nginx:alpine
    container_name: nextcloud_proxy
    restart: unless-stopped
    ports:
      - "${PORT}:443"
    volumes:
      - ${APP_DATA}/nginx/certs:/certs
      - $APP_DATA/nginx/nginx.conf:/etc/nginx/nginx.conf:ro
    depends_on:
      - nextcloud
EOF

  echo "🚀 Subindo o stack..."
  cd "$APP_DATA"
  docker compose up -d

  # --- Ajusta trusted_domains e overwrite* ---
  TS_IP=$(tailscale ip -4 | head -n1 2>/dev/null)

  echo "⏳ Aguardando Nextcloud iniciar..."
  until docker exec -u www-data nextcloud php occ status 2>/dev/null \
        | grep -q "installed: true"; do
    sleep 5
  done

  echo "🔧 Configurando trusted_domains e overwritehost..."
  docker exec -u www-data nextcloud php occ config:system:set trusted_domains 1 --value "$TS_IP"
  docker exec -u www-data nextcloud php occ config:system:set trusted_domains 2 --value "${TS_IP}:${PORT}"
  docker exec -u www-data nextcloud php occ config:system:set overwritehost --value "${TS_IP}:${PORT}"
  docker exec -u www-data nextcloud php occ config:system:set overwriteprotocol --value https
  docker exec -u www-data nextcloud php occ config:system:set overwrite.cli.url --value "https://${TS_IP}:${PORT}"

  echo "✅ Nextcloud em https://$TS_IP:${PORT}"
  echo "Usuário: ${NC_USER}"
}

# ---------- Execução ----------
install_docker_if_needed
install_tailscale_if_needed
install_openssl_if_needed

# Conectar ao tailscale se necessário
until TS_IP=$(tailscale ip -4 2>/dev/null | head -n1); [[ -n "$TS_IP" ]]; do
  echo "Execute 'tailscale up' para conectar à Tailnet..."
  tailscale up
done
echo "Tailnet ok — IP $TS_IP"

install_nextcloud_stack
echo "Tudo pronto! 👍"
