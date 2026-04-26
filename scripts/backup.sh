#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════
# Backup Script — MariaDB + WordPress + Certs
# Запуск: через cron каждые 6 часов
# ═══════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STACK_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_ROOT="/opt/backups"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}"
RETENTION_DAYS=7

# Textfile collector для node-exporter — алерт backup-stale смотрит сюда
TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"

# Загрузить переменные
if [[ -f "${STACK_DIR}/.env" ]]; then
  set -a
  source "${STACK_DIR}/.env"
  set +a
fi

# Пароль из secrets
DB_ROOT_PASS=""
if [[ -f "${STACK_DIR}/secrets/db_root_password.txt" ]]; then
  DB_ROOT_PASS="$(cat "${STACK_DIR}/secrets/db_root_password.txt")"
fi

if [[ -z "$DB_ROOT_PASS" && -n "${MYSQL_ROOT_PASSWORD:-}" ]]; then
  DB_ROOT_PASS="$MYSQL_ROOT_PASSWORD"
fi

if [[ -z "$DB_ROOT_PASS" ]]; then
  echo "[ERROR] $(date): Не удалось получить пароль MariaDB"
  exit 1
fi

mkdir -p "$BACKUP_DIR"

echo "[INFO] $(date): Начало backup в ${BACKUP_DIR}"

# ── MariaDB dump ──
# MYSQL_PWD через env — пароль НЕ попадает в `ps`/cmdline (в отличие от -p<pw>).
echo "[INFO] $(date): Дамп MariaDB..."
if docker exec -e MYSQL_PWD="${DB_ROOT_PASS}" mariadb mariadb-dump \
  -u root \
  --single-transaction \
  --routines \
  --triggers \
  --events \
  --quick \
  --lock-tables=false \
  "${MYSQL_DATABASE:-cashback_db}" 2>/dev/null | gzip > "${BACKUP_DIR}/db.sql.gz"; then
  echo "[OK] $(date): MariaDB dump: $(du -sh "${BACKUP_DIR}/db.sql.gz" | cut -f1)"
else
  echo "[ERROR] $(date): MariaDB dump failed"
fi

# ── WordPress wp-content ──
echo "[INFO] $(date): Архивация wp-content..."
WP_VOLUME="$(docker volume inspect --format '{{ .Mountpoint }}' "$(basename "$STACK_DIR")_wordpress_data" 2>/dev/null || echo "")"

if [[ -n "$WP_VOLUME" && -d "${WP_VOLUME}/wp-content" ]]; then
  tar czf "${BACKUP_DIR}/wp-content.tar.gz" \
    -C "${WP_VOLUME}" wp-content/ \
    --exclude='wp-content/cache' \
    --exclude='wp-content/upgrade' \
    --exclude='wp-content/ai1wm-backups' 2>/dev/null
  echo "[OK] $(date): wp-content: $(du -sh "${BACKUP_DIR}/wp-content.tar.gz" | cut -f1)"
else
  echo "[WARN] $(date): WordPress volume не найден, пропускаю wp-content"
fi

# ── Traefik certificates ──
if [[ -f "${STACK_DIR}/volumes/traefik/acme.json" ]]; then
  cp "${STACK_DIR}/volumes/traefik/acme.json" "${BACKUP_DIR}/acme.json"
  echo "[OK] $(date): acme.json скопирован"
fi

# ── Конфигурации ──
tar czf "${BACKUP_DIR}/configs.tar.gz" \
  -C "${STACK_DIR}" \
  docker-compose.yml \
  .env \
  volumes/traefik/ \
  volumes/nginx/ \
  volumes/php-config/ \
  volumes/mariadb/conf.d/ 2>/dev/null
echo "[OK] $(date): Конфигурации заархивированы"

# ── Ротация старых бэкапов ──
DELETED=$(find "${BACKUP_ROOT}" -maxdepth 1 -mindepth 1 -type d -mtime +${RETENTION_DAYS} -exec rm -rf {} \; -print | wc -l)
if [[ "$DELETED" -gt 0 ]]; then
  echo "[INFO] $(date): Удалено старых бэкапов: ${DELETED}"
fi

# ── Итог ──
TOTAL_SIZE="$(du -sh "${BACKUP_DIR}" | cut -f1)"
echo "[DONE] $(date): Backup завершён. Размер: ${TOTAL_SIZE}. Путь: ${BACKUP_DIR}"

# ── Textfile collector — записываем таймстамп успеха ──
# node-exporter монтирует /var/lib/node_exporter/textfile_collector → /host/textfile_collector
# и выставляет --collector.textfile.directory на эту директорию
if [[ -d "${TEXTFILE_DIR}" ]] && [[ -s "${BACKUP_DIR}/db.sql.gz" ]]; then
  TMP="$(mktemp "${TEXTFILE_DIR}/cashback_backup.prom.XXXXXX")"
  cat > "${TMP}" <<EOF
# HELP cashback_backup_last_success_timestamp_seconds Unix ts последнего успешного бэкапа MariaDB
# TYPE cashback_backup_last_success_timestamp_seconds gauge
cashback_backup_last_success_timestamp_seconds $(date +%s)
# HELP cashback_backup_size_bytes Размер последнего бэкапа в байтах
# TYPE cashback_backup_size_bytes gauge
cashback_backup_size_bytes $(du -sb "${BACKUP_DIR}" | cut -f1)
EOF
  mv "${TMP}" "${TEXTFILE_DIR}/cashback_backup.prom"
  chmod 644 "${TEXTFILE_DIR}/cashback_backup.prom"
fi
