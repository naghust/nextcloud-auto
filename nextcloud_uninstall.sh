#!/bin/bash
set -e

# entra no diretório do script
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STACK_DIR="$(pwd)"
APP_DATA="$STACK_DIR/app-data"
COMPOSE_FILE="$APP_DATA/docker-compose.yml"
PORT=8443

# exige root
[[ $EUID -eq 0 ]] || { echo "Use sudo para executar este script"; exit 1; }

echo "============== DESINSTALAR NEXTCLOUD =============="
echo "Isso vai:"
echo "  1) Parar e remover contêineres + imagens do stack"
echo "  2) Excluir volumes declarados no compose"
echo "  3) Apagar a pasta de dados em $APP_DATA"
echo "===================================================="
read -p "Prosseguir? [s/N]: " RESP
RESP=${RESP,,}
[[ "$RESP" == "s" || "$RESP" == "sim" ]] || { echo "Cancelado."; exit 0; }

# 1) Para e remove contêineres/imagens se o compose existir
if [[ -f "$COMPOSE_FILE" ]]; then
  echo "🚦 Parando e removendo contêineres e imagens..."
  cd "$APP_DATA"
  docker compose down --volumes --remove-orphans --rmi all || true
else
  echo "⚠️  Não encontrei $COMPOSE_FILE, pulando remoção de containers."
fi

# 2) Prune geral (opcional)
echo "🧹 Prune de redes e imagens órfãs..."
docker network prune -f || true
docker image prune -af || true

# 3) Remove diretório de dados
echo "🗑️  Removendo diretório de dados: $APP_DATA"
rm -rf "$APP_DATA"

echo "✅ Nextcloud desinstalado com sucesso. Você pode remover este repositório se não for mais usar."
