# Cashback Stack — Production Deployment

## Требования

- Ubuntu 22.04 / 24.04
- 4+ GB RAM (рекомендуется 8 GB)
- 2+ CPU cores
- SSD (обязательно для MariaDB)
- Docker 24+ с Compose V2

## Быстрый старт

```bash
# 1. Загрузить файлы на сервер
scp -r stack/ root@your-server:/opt/cashback/

# 2. Запустить установщик
ssh root@your-server
cd /opt/cashback
chmod +x install.sh
bash install.sh

# 3. Запустить стек
docker compose up -d

# 4. Дождаться полного запуска (~60-90 сек)
docker compose ps
docker compose logs -f

# 5. Установить WordPress через браузер
# https://your-domain.com

# 6. Включить Redis Object Cache
docker exec -u www-data wordpress wp plugin install redis-cache --activate
docker exec -u www-data wordpress wp redis enable
```

## Структура

```
├── docker-compose.yml          # Главный compose-файл
├── .env                        # Переменные (генерируется install.sh)
├── .env.example                # Шаблон переменных
├── install.sh                  # Установщик
├── secrets/
│   ├── db_root_password.txt    # MariaDB root пароль
│   └── db_password.txt         # MariaDB user пароль
├── volumes/
│   ├── traefik/
│   │   ├── traefik.yml         # Основной конфиг Traefik
│   │   ├── config.yml          # Динамический конфиг
│   │   └── acme.json           # SSL-сертификаты Let's Encrypt
│   ├── nginx/
│   │   ├── nginx.conf          # Основной конфиг Nginx
│   │   └── default.conf        # Virtual host + FastCGI cache
│   ├── php-config/
│   │   ├── wordpress.ini       # PHP настройки
│   │   └── www.conf            # PHP-FPM pool
│   └── mariadb/
│       └── conf.d/
│           └── custom.cnf      # MariaDB тюнинг
└── scripts/
    └── backup.sh               # Бэкап БД + файлов
```

## Команды управления

```bash
# Статус
docker compose ps

# Логи
docker compose logs -f nginx
docker compose logs -f wordpress
docker compose logs -f mariadb

# Перезапуск сервиса
docker compose restart wordpress

# Обновление образов
docker compose pull
docker compose up -d

# Бэкап вручную
bash scripts/backup.sh

# Очистка FastCGI cache
docker exec nginx sh -c "rm -rf /var/cache/nginx/fastcgi/*"

# Сброс OPcache (после деплоя плагинов)
docker exec wordpress php -r "opcache_reset();"

# WP-CLI
docker exec -u www-data wordpress wp plugin list
docker exec -u www-data wordpress wp cache flush
```

## Мониторинг

```bash
# PHP-FPM status
docker exec nginx curl -s http://127.0.0.1/fpm-status

# MariaDB connections
docker exec mariadb mariadb -u root -p"$(cat secrets/db_root_password.txt)" -e "SHOW STATUS LIKE 'Threads_connected';"

# Redis stats
docker exec redis redis-cli info stats | grep -E 'hits|misses|used_memory_human'

# FastCGI cache hit rate (из логов nginx)
docker exec nginx tail -100 /var/log/nginx/access.log | grep -oP 'cache=\K\w+' | sort | uniq -c
```

## Важные замечания

1. **OPcache `validate_timestamps = 0`** — после установки/обновления плагинов нужно сбросить OPcache:
   ```bash
   docker exec wordpress php -r "opcache_reset();"
   ```

2. **PHP-FPM `disable_functions`** — отключены exec, shell_exec и т.д. Если плагин требует их — убрать из www.conf.

3. **Бэкапы** — автоматически каждые 6 часов в `/opt/backups/`, хранение 7 дней.

4. **SSL** — автоматически через Let's Encrypt. Перед запуском убедитесь, что DNS A-запись указывает на сервер.
