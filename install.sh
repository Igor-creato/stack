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

echo ""
info "Домен:  $DOMAIN"
info "Email:  $ACME_EMAIL"
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
  "$INSTALL_DIR/volumes/php-config"
  "$INSTALL_DIR/volumes/mariadb/conf.d"
  "$INSTALL_DIR/volumes/wordpress"
  "$INSTALL_DIR/secrets"
  "$INSTALL_DIR/scripts"
  "/opt/backups"
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
EOF

chmod 600 "$INSTALL_DIR/.env"
log ".env создан (chmod 600)"

# ─── Docker secrets ───────────────────────────────────────
echo -n "$MYSQL_ROOT_PASSWORD" > "$INSTALL_DIR/secrets/db_root_password.txt"
echo -n "$MYSQL_PASSWORD"      > "$INSTALL_DIR/secrets/db_password.txt"

chmod 600 "$INSTALL_DIR/secrets/"*.txt
log "Docker secrets созданы (chmod 600)"

# ─── Traefik acme.json ────────────────────────────────────
touch "$INSTALL_DIR/volumes/traefik/acme.json"
chmod 600 "$INSTALL_DIR/volumes/traefik/acme.json"
log "acme.json создан (chmod 600)"

# ─── Подстановка email в traefik.yml ─────────────────────
if [[ -f "$INSTALL_DIR/volumes/traefik/traefik.yml" ]]; then
  sed -i "s|__ACME_EMAIL__|${ACME_EMAIL}|g" "$INSTALL_DIR/volumes/traefik/traefik.yml"
  log "Email подставлен в traefik.yml"
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
chmod 755 "$INSTALL_DIR/volumes/wordpress"
chmod 755 "$INSTALL_DIR/volumes/mariadb"

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
  chown "${REAL_USER}:${REAL_GROUP}" "$INSTALL_DIR/docker-compose.yml" 2>/dev/null || true
  chown "${REAL_USER}:${REAL_GROUP}" "$INSTALL_DIR/scripts/backup.sh" 2>/dev/null || true
  log "Владелец файлов: ${REAL_USER}:${REAL_GROUP}"
fi

# ─── Backup скрипт ────────────────────────────────────────
chmod +x "$INSTALL_DIR/scripts/backup.sh" 2>/dev/null || true
log "backup.sh готов"

# ─── Cron для WP-Cron + backup ───────────────────────────
CRON_WP="*/5 * * * * docker exec -u www-data wordpress php /var/www/html/wp-cron.php > /dev/null 2>&1"
CRON_BACKUP="0 */6 * * * bash ${INSTALL_DIR}/scripts/backup.sh >> /var/log/backup.log 2>&1"

# Добавляем в crontab реального пользователя (у него доступ к docker)
CRON_USER="$REAL_USER"
(crontab -u "$CRON_USER" -l 2>/dev/null | grep -v 'wp-cron.php' | grep -v 'backup.sh'; echo "$CRON_WP"; echo "$CRON_BACKUP") | sort -u | crontab -u "$CRON_USER" -
log "Cron задачи установлены для ${CRON_USER} (wp-cron каждые 5 мин, backup каждые 6 часов)"

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
echo ""
warn "ЗАПИШИТЕ ПАРОЛИ! Они также сохранены в .env и secrets/"
echo ""
info "Следующий шаг — запуск стека:"
echo ""
echo -e "    ${CYAN}cd $INSTALL_DIR${NC}"
echo -e "    ${CYAN}docker compose up -d${NC}"
echo ""
info "После первого запуска установите Redis Object Cache:"
echo ""
echo -e "    ${CYAN}docker exec -u www-data wordpress wp plugin install redis-cache --activate${NC}"
echo -e "    ${CYAN}docker exec -u www-data wordpress wp redis enable${NC}"
echo ""
info "Сайт будет доступен: https://${DOMAIN}"
echo ""
