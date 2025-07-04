# Nextcloud Auto-Deploy (Docker + Tailscale)

Instalador 100 % automatizado que põe um Nextcloud rodando em poucos comandos, dentro
de contêineres Docker, protegido por HTTPS (autoassinado) e acessível pela
Tailnet. Nada de gambiarra no host — só pacotes essenciais e diretórios de dados.

> **Suporta** Ubuntu 22/24 (server ou VPS) rodando como root/sudo.

---

## O que o script faz

1. **Checagem / instalação**
   - Docker Engine + Docker Compose  
   - Tailscale  
   - OpenSSL  
   (se já tiver, ele só avisa — não reinstala)

2. **Gera** certificado autoassinado (`~/nextcloud-auto/app-data/nginx/certs`).

3. **Cria e sobe** via `docker-compose`:  
   | Contêiner | Porta interna | Descrição |
   |-----------|---------------|-----------|
   | nextcloud | `80`          | PHP-FPM + Apache |
   | mariadb   | `3306`        | Banco de dados |
   | redis     | `6379`        | Cache/memória |
   | nginx     | `443`         | Proxy HTTPS (porta externa **8443**) |

4. **Pergunta** usuário e senha admin do Nextcloud antes de subir.

5. Após a instalação do Nextcloud, grava:  
   - `trusted_domains` (IP Tailnet e IP:8443)  
   - `overwritehost`, `overwriteprotocol`, `overwrite.cli.url`  
   Assim a URL não perde `:8443` e não aparece o aviso “contacte seu administrador”.

6. **Deixa tudo isolado** em `~/nextcloud-auto/app-data*`; nada é instalado fora de
   contêineres, exceto os pacotes de pré-requisito.

---

## Uso rápido

```bash
git clone https://github.com/naghust/nextcloud-auto.git
cd nextcloud-auto/
sudo ./nextcloud_install.sh
