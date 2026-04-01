#!/bin/bash
# ============================================================
#  NEXUS IMOB — SCRIPT DE SETUP DO VPS
#  Execute como root no servidor Hostinger
#  Testado em: Ubuntu 22.04 LTS
#
#  USO: chmod +x setup-vps.sh && ./setup-vps.sh
# ============================================================

set -e  # Para se qualquer comando falhar

echo ""
echo "██╗███╗   ██╗███████╗██╗  ██╗██╗   ██╗███████╗"
echo "██║████╗  ██║██╔════╝╚██╗██╔╝██║   ██║██╔════╝"
echo "██║██╔██╗ ██║█████╗   ╚███╔╝ ██║   ██║███████╗"
echo "██║██║╚██╗██║██╔══╝   ██╔██╗ ██║   ██║╚════██║"
echo "██║██║ ╚████║███████╗██╔╝ ██╗╚██████╔╝███████║"
echo "╚═╝╚═╝  ╚═══╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝"
echo "          IMOB — VPS SETUP v1.0"
echo ""

# ----------------------------------------------------------
# 1. ATUALIZAR SISTEMA
# ----------------------------------------------------------
echo "[ 1/8 ] Atualizando sistema..."
apt-get update -qq && apt-get upgrade -y -qq
apt-get install -y -qq \
  curl wget git unzip \
  nginx certbot python3-certbot-nginx \
  ufw fail2ban htop

# ----------------------------------------------------------
# 2. CONFIGURAR FIREWALL
# ----------------------------------------------------------
echo "[ 2/8 ] Configurando firewall..."
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# ----------------------------------------------------------
# 3. INSTALAR DOCKER
# ----------------------------------------------------------
echo "[ 3/8 ] Instalando Docker..."
if ! command -v docker &> /dev/null; then
  curl -fsSL https://get.docker.com | sh
  systemctl enable docker
  systemctl start docker
fi

# Docker Compose plugin
if ! docker compose version &> /dev/null; then
  apt-get install -y docker-compose-plugin
fi

echo "Docker version: $(docker --version)"
echo "Docker Compose version: $(docker compose version)"

# ----------------------------------------------------------
# 4. CRIAR ESTRUTURA DE DIRETÓRIOS
# ----------------------------------------------------------
echo "[ 4/8 ] Criando estrutura de diretórios..."
mkdir -p /opt/nexus-imob/{nginx/conf.d,nginx/www,postgres/{init,backups},n8n/workflows,ssl}
cd /opt/nexus-imob

# ----------------------------------------------------------
# 5. CONFIGURAR SSL (Let's Encrypt)
# ----------------------------------------------------------
echo "[ 5/8 ] Configurando SSL..."
echo "  → Certifique-se que o DNS já aponta para este servidor"
echo "  → Domínios necessários:"
echo "     n8n.seudominio.com.br"
echo "     wpp.seudominio.com.br"
echo ""
read -p "  Digite seu domínio (ex: nexusimob.com.br): " DOMAIN
read -p "  Digite seu e-mail para o Let's Encrypt: " EMAIL

# Obtém certificado wildcard via Cloudflare (recomendado)
# Ou certbot individual por subdomínio:
certbot certonly --nginx \
  --non-interactive \
  --agree-tos \
  --email "$EMAIL" \
  -d "n8n.$DOMAIN" \
  -d "wpp.$DOMAIN" \
  || echo "  ⚠ SSL manual necessário. Execute certbot manualmente após setup."

# ----------------------------------------------------------
# 6. COPIAR ARQUIVOS DE CONFIGURAÇÃO
# ----------------------------------------------------------
echo "[ 6/8 ] Copiando arquivos de configuração..."

# Nginx
cat > /opt/nexus-imob/nginx/conf.d/nexus.conf << NGINXEOF
# N8N
server {
    listen 443 ssl http2;
    server_name n8n.$DOMAIN;
    ssl_certificate     /etc/letsencrypt/live/n8n.$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/n8n.$DOMAIN/privkey.pem;
    client_max_body_size 50M;
    location / {
        proxy_pass http://n8n:5678;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 900s;
    }
}

# Evolution API
server {
    listen 443 ssl http2;
    server_name wpp.$DOMAIN;
    ssl_certificate     /etc/letsencrypt/live/wpp.$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/wpp.$DOMAIN/privkey.pem;
    client_max_body_size 100M;
    location / {
        proxy_pass http://evolution-api:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
    }
}

server {
    listen 80;
    server_name n8n.$DOMAIN wpp.$DOMAIN;
    return 301 https://\$host\$request_uri;
}
NGINXEOF

# ----------------------------------------------------------
# 7. GERAR .env E SUBIR CONTAINERS
# ----------------------------------------------------------
echo "[ 7/8 ] Configurando variáveis de ambiente..."

if [ ! -f /opt/nexus-imob/.env ]; then
  # Gera senhas aleatórias
  PG_PASS=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)
  REDIS_PASS=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)
  N8N_PASS=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 24)
  N8N_KEY=$(openssl rand -hex 16)
  EVO_KEY=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 40)

  cat > /opt/nexus-imob/.env << ENVEOF
DOMAIN=$DOMAIN
POSTGRES_USER=nexus
POSTGRES_PASSWORD=$PG_PASS
POSTGRES_DB=nexus_imob
REDIS_PASSWORD=$REDIS_PASS
N8N_USER=admin
N8N_PASSWORD=$N8N_PASS
N8N_ENCRYPTION_KEY=$N8N_KEY
EVOLUTION_API_KEY=$EVO_KEY
ENVEOF

  echo ""
  echo "  ✅ Credenciais geradas automaticamente:"
  echo "  PostgreSQL: nexus / $PG_PASS"
  echo "  Redis:      $REDIS_PASS"
  echo "  N8N:        admin / $N8N_PASS"
  echo "  N8N Key:    $N8N_KEY"
  echo "  Evo API:    $EVO_KEY"
  echo ""
  echo "  ⚠ SALVE ESTAS CREDENCIAIS EM LOCAL SEGURO!"
  echo ""
fi

# ----------------------------------------------------------
# 8. SUBIR CONTAINERS
# ----------------------------------------------------------
echo "[ 8/8 ] Iniciando containers..."
cd /opt/nexus-imob
docker compose up -d

# Aguarda serviços ficarem saudáveis
echo "  Aguardando serviços iniciarem (60s)..."
sleep 60

# Status
docker compose ps

echo ""
echo "✅ NEXUS IMOB — VPS CONFIGURADO COM SUCESSO!"
echo ""
echo "  📊 N8N:           https://n8n.$DOMAIN"
echo "  💬 Evolution API: https://wpp.$DOMAIN"
echo "  🔧 Próximos passos:"
echo "     1. Configure o .env com suas chaves de API"
echo "     2. Acesse o N8N e importe os workflows"
echo "     3. Conecte o WhatsApp na Evolution API"
echo "     4. Configure os webhooks dos portais imobiliários"
echo ""
