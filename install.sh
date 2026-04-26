#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════
#  Cashback Stack — Installation Script
#  Ubuntu 22.04 / 24.04
# ═══════════════════════════════════════════════════════════

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; }
info() { echo -e "${CYAN}[i]${NC} $1"; }

# ─── Проверка root ────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  err "Запуск только от root:  sudo bash install.sh"
  exit 1
fi

# ─── Определяем реального пользователя (кто вызвал sudo) ──
REAL_USER="${SUDO_USER:-root}"
REAL_GROUP="$(id -gn "$REAL_USER" 2>/dev/null || echo "root")"

echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════${NC}"
echo -e "${CYAN}   Cashback Stack — Production Installer${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════${NC}"
echo ""

# ─── Ввод домена ──────────────────────────────────────────
read -rp "$(echo -e "${CYAN}Введите домен сайта (например: cashback.example.com): ${NC}")" DOMAIN
if [[ -z "$DOMAIN" ]]; then
  err "Домен не может быть пустым"
  exit 1
fi

# Валидация домена
if ! echo "$DOMAIN" | grep -qP '^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$'; then
  err "Невалидный формат домена: $DOMAIN"
  exit 1
fi

read -rp "$(echo -e "${CYAN}Email для Let's Encrypt SSL: ${NC}")" ACME_EMAIL
if [[ -z "$ACME_EMAIL" ]]; then
  err "Email обязателен для получения SSL-сертификатов"
  exit 1
fi

# ─── SMTP настройки ─────────────────────────────────────
echo ""
info "Настройка отправки email (SMTP)"
read -rp "$(echo -e "${CYAN}SMTP хост (например: smtp.gmail.com): ${NC}")" SMTP_HOST
read -rp "$(echo -e "${CYAN}SMTP порт [587]: ${NC}")" SMTP_PORT
SMTP_PORT="${SMTP_PORT:-587}"
read -rp "$(echo -e "${CYAN}SMTP пользователь (email): ${NC}")" SMTP_USER
read -rsp "$(echo -e "${CYAN}SMTP пароль: ${NC}")" SMTP_PASSWORD
echo ""
read -rp "$(echo -e "${CYAN}SMTP шифрование (tls/ssl) [tls]: ${NC}")" SMTP_SECURE
SMTP_SECURE="${SMTP_SECURE:-tls}"
read -rp "$(echo -e "${CYAN}Email отправителя (From) [${SMTP_USER}]: ${NC}")" SMTP_FROM
SMTP_FROM="${SMTP_FROM:-$SMTP_USER}"

read -rp "$(echo -e "${CYAN}Email для получения алертов Grafana (можно через запятую) [${SMTP_USER}]: ${NC}")" ALERT_EMAIL
ALERT_EMAIL="${ALERT_EMAIL:-$SMTP_USER}"

echo ""
info "Домен:  $DOMAIN"
info "Email:  $ACME_EMAIL"
info "SMTP:   $SMTP_HOST:$SMTP_PORT ($SMTP_SECURE)"
info "Алерты: $ALERT_EMAIL"
echo ""
read -rp "$(echo -e "${YELLOW}Продолжить? (y/n): ${NC}")" CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  echo "Отмена."
  exit 0
fi

# ─── Генерация паролей ────────────────────────────────────
generate_password() {
  openssl rand -base64 32 | tr -d '/+=' | head -c "$1"
}

MYSQL_ROOT_PASSWORD="$(generate_password 32)"
MYSQL_PASSWORD="$(generate_password 28)"
MYSQL_EXPORTER_PASSWORD="$(generate_password 28)"
MYSQL_DATABASE="cashback_db"
MYSQL_USER="cashback_user"

# WordPress salts
WP_AUTH_KEY="$(generate_password 64)"
WP_SECURE_AUTH_KEY="$(generate_password 64)"
WP_LOGGED_IN_KEY="$(generate_password 64)"
WP_NONCE_KEY="$(generate_password 64)"
WP_AUTH_SALT="$(generate_password 64)"
WP_SECURE_AUTH_SALT="$(generate_password 64)"
WP_LOGGED_IN_SALT="$(generate_password 64)"
WP_NONCE_SALT="$(generate_password 64)"

# Grafana admin
GRAFANA_PASSWORD="$(generate_password 24)"

log "Пароли сгенерированы"

# ─── Установка Docker (если нет) ─────────────────────────
if ! command -v docker &>/dev/null; then
  info "Docker не найден, устанавливаю..."
  curl -fsSL https://get.docker.com | sh
  systemctl enable docker
  systemctl start docker
  log "Docker установлен"
else
  log "Docker уже установлен: $(docker --version)"
fi

if ! docker compose version &>/dev/null; then
  err "Docker Compose V2 не найден. Обновите Docker."
  exit 1
fi
log "Docker Compose V2: $(docker compose version --short)"

# Добавить пользователя в группу docker (если ещё не состоит)
if [[ "$REAL_USER" != "root" ]] && ! id -nG "$REAL_USER" | grep -qw docker; then
  usermod -aG docker "$REAL_USER"
  log "Пользователь ${REAL_USER} добавлен в группу docker"
  warn "Для применения группы docker без перезагрузки выполните:  newgrp docker"
fi

# ─── Создание директорий ──────────────────────────────────
info "Создание структуры директорий..."

dirs=(
  "$INSTALL_DIR/volumes/traefik"
  "$INSTALL_DIR/volumes/nginx"
  "$INSTALL_DIR/volumes/nginx-logs"
  "$INSTALL_DIR/volumes/modsec-logs"
  "$INSTALL_DIR/volumes/crowdsec"
  "$INSTALL_DIR/volumes/php-config"
  "$INSTALL_DIR/volumes/mariadb/conf.d"
  "$INSTALL_DIR/volumes/wordpress"
  "$INSTALL_DIR/secrets"
  "$INSTALL_DIR/scripts"
  "$INSTALL_DIR/volumes/modsecurity/local-rules"
  "$INSTALL_DIR/volumes/vector"
  "/opt/backups"
  "/var/lib/node_exporter/textfile_collector"
)

for d in "${dirs[@]}"; do
  mkdir -p "$d"
done

log "Директории созданы"

# ─── Создание .env ────────────────────────────────────────
cat > "$INSTALL_DIR/.env" <<EOF
# ═══════════════════════════════════════════
# Автоматически сгенерировано install.sh
# $(date '+%Y-%m-%d %H:%M:%S')
# ═══════════════════════════════════════════

DOMAIN=${DOMAIN}
ACME_EMAIL=${ACME_EMAIL}

# MariaDB
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
MYSQL_DATABASE=${MYSQL_DATABASE}
MYSQL_USER=${MYSQL_USER}
MYSQL_PASSWORD=${MYSQL_PASSWORD}

# WordPress Salts
WP_AUTH_KEY=${WP_AUTH_KEY}
WP_SECURE_AUTH_KEY=${WP_SECURE_AUTH_KEY}
WP_LOGGED_IN_KEY=${WP_LOGGED_IN_KEY}
WP_NONCE_KEY=${WP_NONCE_KEY}
WP_AUTH_SALT=${WP_AUTH_SALT}
WP_SECURE_AUTH_SALT=${WP_SECURE_AUTH_SALT}
WP_LOGGED_IN_SALT=${WP_LOGGED_IN_SALT}
WP_NONCE_SALT=${WP_NONCE_SALT}

# SMTP
SMTP_HOST=${SMTP_HOST}
SMTP_PORT=${SMTP_PORT}
SMTP_USER=${SMTP_USER}
SMTP_PASSWORD=${SMTP_PASSWORD}
SMTP_SECURE=${SMTP_SECURE}
SMTP_FROM=${SMTP_FROM}

# Grafana
GRAFANA_PASSWORD=${GRAFANA_PASSWORD}

# Email для алертов Grafana
ALERT_EMAIL=${ALERT_EMAIL}

# mysqld-exporter (read-only пользователь, ALTER USER применяется один раз после старта MariaDB)
MYSQL_EXPORTER_PASSWORD=${MYSQL_EXPORTER_PASSWORD}
EOF

chmod 600 "$INSTALL_DIR/.env"
log ".env создан (chmod 600)"

# ─── Docker secrets ───────────────────────────────────────
# Compose без Swarm bind-mount'ит файлы секретов с правами хоста.
# Контейнерные процессы (www-data uid 33, mysql uid 999, etc.) должны
# мочь читать файлы. Делаем секреты 0644, а саму директорию 0700,
# чтобы доступ извне (не из контейнеров) был только у владельца.
echo -n "$MYSQL_ROOT_PASSWORD" > "$INSTALL_DIR/secrets/db_root_password.txt"
echo -n "$MYSQL_PASSWORD"      > "$INSTALL_DIR/secrets/db_password.txt"

chmod 700 "$INSTALL_DIR/secrets"
chmod 644 "$INSTALL_DIR/secrets/"*.txt
log "Docker secrets созданы (dir 0700, files 0644)"

# ─── Traefik acme.json ────────────────────────────────────
touch "$INSTALL_DIR/volumes/traefik/acme.json"
chmod 600 "$INSTALL_DIR/volumes/traefik/acme.json"
log "acme.json создан (chmod 600)"

# ─── Подстановка email в traefik.yml ─────────────────────
if [[ -f "$INSTALL_DIR/volumes/traefik/traefik.yml" ]]; then
  sed -i "s|__ACME_EMAIL__|${ACME_EMAIL}|g" "$INSTALL_DIR/volumes/traefik/traefik.yml"
  log "Email подставлен в traefik.yml"
fi

# ─── Рендеринг шаблонов Grafana provisioning ─────────────
# Grafana 12.4 не разворачивает env-vars в contactPoints[].settings.addresses,
# поэтому contact-points.yml генерится из шаблона .tpl через envsubst.
if ! command -v envsubst &>/dev/null; then
  info "Установка gettext-base (даёт envsubst)..."
  apt-get update -qq && apt-get install -y --no-install-recommends gettext-base >/dev/null
  log "gettext-base установлен"
fi

CP_TPL="$INSTALL_DIR/volumes/grafana/provisioning/alerting/contact-points.yml.tpl"
CP_OUT="$INSTALL_DIR/volumes/grafana/provisioning/alerting/contact-points.yml"
if [[ -f "$CP_TPL" ]]; then
  ALERT_EMAIL="$ALERT_EMAIL" envsubst '${ALERT_EMAIL}' < "$CP_TPL" > "$CP_OUT"
  chmod 644 "$CP_OUT"
  log "contact-points.yml сгенерирован (ALERT_EMAIL=${ALERT_EMAIL})"
fi

# ─── Создание Docker-сетей ────────────────────────────────
if ! docker network inspect proxy &>/dev/null 2>&1; then
  docker network create proxy
  log "Docker network 'proxy' создана"
else
  log "Docker network 'proxy' уже существует"
fi

if ! docker network inspect db-shared &>/dev/null 2>&1; then
  docker network create db-shared
  log "Docker network 'db-shared' создана"
else
  log "Docker network 'db-shared' уже существует"
fi

# ─── Права на volumes ─────────────────────────────────────
# nginx: uid=101/gid=101 в alpine
# wordpress/php-fpm: uid=33/gid=33 (www-data)
# mariadb: uid=999/gid=999
chown -R 33:33  "$INSTALL_DIR/volumes/wordpress"
chown -R 999:999 "$INSTALL_DIR/volumes/mariadb"
chown -R 101:101 "$INSTALL_DIR/volumes/nginx-logs"
chown -R 101:101 "$INSTALL_DIR/volumes/modsec-logs"
chmod 755 "$INSTALL_DIR/volumes/wordpress"
chmod 755 "$INSTALL_DIR/volumes/mariadb"
chmod 755 "$INSTALL_DIR/volumes/nginx-logs"
chmod 755 "$INSTALL_DIR/volumes/modsec-logs"

log "Права на volumes установлены"

# ─── Владелец проекта = реальный пользователь ─────────────
# Чтобы docker compose работал без sudo
if [[ "$REAL_USER" != "root" ]]; then
  chown "${REAL_USER}:${REAL_GROUP}" "$INSTALL_DIR/.env"
  chown "${REAL_USER}:${REAL_GROUP}" "$INSTALL_DIR/secrets/db_root_password.txt"
  chown "${REAL_USER}:${REAL_GROUP}" "$INSTALL_DIR/secrets/db_password.txt"
  chown "${REAL_USER}:${REAL_GROUP}" "$INSTALL_DIR/secrets"
  chown "${REAL_USER}:${REAL_GROUP}" "$INSTALL_DIR/volumes/traefik/acme.json"
  chown -R "${REAL_USER}:${REAL_GROUP}" "$INSTALL_DIR/volumes/nginx"
  chown -R "${REAL_USER}:${REAL_GROUP}" "$INSTALL_DIR/volumes/php-config"
  chown -R "${REAL_USER}:${REAL_GROUP}" "$INSTALL_DIR/volumes/traefik"
  chown -R "${REAL_USER}:${REAL_GROUP}" "$INSTALL_DIR/volumes/crowdsec"
  chown "${REAL_USER}:${REAL_GROUP}" "$INSTALL_DIR/docker-compose.yml" 2>/dev/null || true
  chown "${REAL_USER}:${REAL_GROUP}" "$INSTALL_DIR/scripts/backup.sh" 2>/dev/null || true
  log "Владелец файлов: ${REAL_USER}:${REAL_GROUP}"
fi

# ─── Backup скрипт ────────────────────────────────────────
chmod +x "$INSTALL_DIR/scripts/backup.sh" 2>/dev/null || true
chmod +x "$INSTALL_DIR/scripts/setup-cron.sh" 2>/dev/null || true
chmod +x "$INSTALL_DIR/scripts/setup-mariadb-users.sh" 2>/dev/null || true
log "backup.sh, setup-cron.sh, setup-mariadb-users.sh готовы"

# ─── Системные лимиты ────────────────────────────────────
info "Настройка системных лимитов..."

# fs.file-max
if ! grep -q 'fs.file-max = 100000' /etc/sysctl.conf 2>/dev/null; then
  cat >> /etc/sysctl.conf <<'SYSCTL'

# ── Cashback Stack Tuning ──
fs.file-max = 100000
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.ip_local_port_range = 1024 65535
vm.swappiness = 10
vm.overcommit_memory = 1
SYSCTL
  sysctl -p > /dev/null 2>&1
  log "Sysctl параметры применены"
fi

# ─── Сборка образов и запуск стека ───────────────────────
info "Сборка custom-образа WordPress (это может занять 1-2 минуты при первом запуске)..."
cd "$INSTALL_DIR"
docker compose build
log "Образы собраны"

info "Запуск стека (docker compose up -d)..."
docker compose up -d
log "Контейнеры запущены"

# ─── Ожидание готовности MariaDB ─────────────────────────
info "Ожидаю готовности MariaDB (до 90 секунд)..."
MARIADB_READY=0
for i in {1..45}; do
  if docker exec mariadb healthcheck.sh --connect --innodb_initialized &>/dev/null; then
    MARIADB_READY=1
    break
  fi
  sleep 2
done

if [[ "$MARIADB_READY" -ne 1 ]]; then
  warn "MariaDB не стала healthy за 90с. Проверь: docker logs mariadb"
  warn "После решения запусти вручную: bash scripts/setup-mariadb-users.sh"
else
  log "MariaDB готова"

  # ─── Установка пароля для mysqld-exporter ──────────────
  info "Установка пароля для mysqld-exporter..."
  bash "${INSTALL_DIR}/scripts/setup-mariadb-users.sh"
fi

# ─── Cron для Action Scheduler + WP-Cron + backup ────────
# Запускается ПОСЛЕ старта стека, чтобы WP-CLI проверка прошла без warning
info "Настройка cron (через setup-cron.sh)..."
bash "${INSTALL_DIR}/scripts/setup-cron.sh"

# ─── Redis Object Cache plugin (идемпотентно) ────────────
# Ждём что WordPress готов отвечать (полная инициализация ~3 мин из-за start_period 180s)
info "Ожидаю готовности WordPress (до 4 минут)..."
WP_READY=0
for i in {1..120}; do
  if docker exec -u www-data wordpress wp core is-installed &>/dev/null; then
    WP_READY=1
    break
  fi
  # WP может быть просто не настроенным — это тоже OK для wp-cli plugin install
  if docker exec -u www-data wordpress wp --info &>/dev/null; then
    WP_READY=1
    break
  fi
  sleep 2
done

if [[ "$WP_READY" -eq 1 ]]; then
  if ! docker exec -u www-data wordpress wp plugin is-active redis-cache &>/dev/null; then
    info "Установка Redis Object Cache plugin..."
    docker exec -u www-data wordpress wp plugin install redis-cache --activate || warn "Не удалось установить redis-cache (возможно WP ещё не инициализирован — выполни вручную)"
    docker exec -u www-data wordpress wp redis enable 2>/dev/null || true
    log "Redis Object Cache установлен"
  else
    log "Redis Object Cache уже активен"
  fi
else
  warn "WP-CLI пока не готов. После завершения инсталляции WordPress выполни вручную:"
  warn "  docker exec -u www-data wordpress wp plugin install redis-cache --activate"
  warn "  docker exec -u www-data wordpress wp redis enable"
fi

# ─── Итог ─────────────────────────────────────────────────
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}   Установка завершена!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""
info "Структура файлов:"
echo "    $INSTALL_DIR/"
echo "    ├── docker-compose.yml"
echo "    ├── .env                   (chmod 600)"
echo "    ├── secrets/"
echo "    │   ├── db_root_password.txt"
echo "    │   └── db_password.txt"
echo "    ├── volumes/"
echo "    │   ├── traefik/"
echo "    │   ├── nginx/"
echo "    │   ├── php-config/"
echo "    │   ├── mariadb/conf.d/"
echo "    │   └── wordpress/"
echo "    └── scripts/"
echo "        └── backup.sh"
echo ""
info "Сохранённые пароли:"
echo "    MariaDB root:  $MYSQL_ROOT_PASSWORD"
echo "    MariaDB user:  $MYSQL_PASSWORD"
echo "    DB name:       $MYSQL_DATABASE"
echo "    DB user:       $MYSQL_USER"
echo "    Grafana admin: $GRAFANA_PASSWORD"
echo ""
info "SMTP:"
echo "    Host:     $SMTP_HOST:$SMTP_PORT ($SMTP_SECURE)"
echo "    User:     $SMTP_USER"
echo "    From:     $SMTP_FROM"
echo ""
warn "ЗАПИШИТЕ ПАРОЛИ! Они также сохранены в .env и secrets/"
echo ""
info "Стек уже запущен. Проверь статус:"
echo ""
echo -e "    ${CYAN}cd $INSTALL_DIR${NC}"
echo -e "    ${CYAN}docker compose ps${NC}"
echo ""
info "Тест что email-алерты ходят (~2 минуты до письма):"
echo -e "    ${CYAN}docker stop nginx; sleep 150; docker start nginx${NC}"
echo ""
info "CrowdSec работает в режиме обучения (без bouncer)."
echo "    Через 1-2 недели проверь алерты и whitelist'ы:"
echo -e "    ${CYAN}docker exec crowdsec cscli alerts list${NC}"
echo -e "    ${CYAN}docker exec crowdsec cscli decisions list${NC}"
echo -e "    ${CYAN}docker exec crowdsec cscli metrics${NC}"
echo "    Подключение к CrowdSec Console (опционально):"
echo -e "    ${CYAN}docker exec crowdsec cscli console enroll <KEY_FROM_app.crowdsec.net>${NC}"
echo ""
info "Webhook-receiver стек (если используется) поднимается отдельно:"
echo -e "    ${CYAN}cd ../webhook-receiver && docker compose build && docker compose up -d${NC}"
echo ""
info "Сайт будет доступен: https://${DOMAIN}"
echo ""
