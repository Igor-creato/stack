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

## Cron и Action Scheduler

Плагин использует Action Scheduler (через WooCommerce) для трёх критичных задач:
- `cashback_broadcast_process` — массовая email-рассылка (каждую минуту)
- `cashback_notification_process_queue` — очередь транзакционных email (каждую минуту)
- `cashback_api_sync_statuses` — синхронизация статусов CPA-сетей (каждые 2ч)

Плюс 4 лёгких WP-Cron задачи (fraud/support/health-check, daily/hourly).

`DISABLE_WP_CRON = true` в docker-compose, поэтому всё гоняется через host-crontab. Настройка автоматическая:

```bash
sudo bash scripts/setup-cron.sh
```

Ставит три задачи в crontab `$SUDO_USER`:

```cron
# cashback-stack: managed by setup-cron.sh
* * * * * /usr/bin/flock -n /var/lock/cashback-as.lock -c 'docker exec -u www-data wordpress wp action-scheduler run --batch-size=50 --batches=1 --group=cashback --quiet' >> /var/log/wp-cron/action-scheduler.log 2>&1
*/5 * * * * /usr/bin/flock -n /var/lock/cashback-wpcron.lock -c 'docker exec -u www-data wordpress wp cron event run --due-now --quiet' >> /var/log/wp-cron/wp-cron.log 2>&1
0 */6 * * * bash /opt/cashback/scripts/backup.sh >> /var/log/backup.log 2>&1
```

Логи ротируются через `/etc/logrotate.d/cashback-wp-cron` (daily, 7 дней, compress).

### Проверка

```bash
# Живой лог AS
tail -f /var/log/wp-cron/action-scheduler.log

# Запланированные AS-задачи группы cashback
docker exec -u www-data wordpress wp action-scheduler action list --group=cashback --status=pending --per_page=10 2>/dev/null

# Завершённые последние 10 по нашей группе
docker exec -u www-data wordpress wp action-scheduler action list --group=cashback --status=complete --per_page=10 2>/dev/null

# Общая сводка по AS (pending/in-progress/complete/failed)
docker exec -u www-data wordpress wp action-scheduler status 2>/dev/null

# Оставшиеся WP-Cron хуки
docker exec -u www-data wordpress wp cron event list

# Crontab пользователя
crontab -l -u <user>

# Проверка logrotate (dry-run)
logrotate -d /etc/logrotate.d/cashback-wp-cron
```

### Ручной запуск

```bash
# Обработать очередь AS прямо сейчас
docker exec -u www-data wordpress wp action-scheduler run --group=cashback

# Прогнать все due WP-Cron задачи
docker exec -u www-data wordpress wp cron event run --due-now
```

### Удаление cron

`crontab -e -u <user>` → удалить блок от маркера `# cashback-stack: managed by setup-cron.sh` до пустой строки. Либо `crontab -r -u <user>` для полной очистки.

---

## Миграция со старой версии (на уже запущенном сервере)

Если у вас уже развёрнут стек без WP-CLI в wordpress-образе и/или со старой cron-строкой `*/5 wp-cron.php`, выполните следующее:

```bash
cd /opt/cashback

# 1. Получить новые файлы (Dockerfile, scripts/setup-cron.sh, install.sh, docker-compose.yml)
git pull        # или scp -r stack/ root@host:/opt/cashback/

# 2. Пересобрать wordpress-образ (добавляется WP-CLI)
docker compose build wordpress

# 3. Пересоздать контейнер wordpress (даунтайм ~15-30 с — healthcheck start_period)
docker compose up -d wordpress

# 4. Убедиться, что WP-CLI теперь доступен в основном контейнере
docker exec -u www-data wordpress wp --info

# 5. Убрать одноразовый сервис wp-cli (если он был в старом compose)
docker rm -f wp-cli 2>/dev/null || true
docker compose up -d

# 6. Применить новый cron (старая */5 wp-cron.php снимается автоматически
#    через legacy-patterns в setup-cron.sh)
sudo bash /opt/cashback/scripts/setup-cron.sh

# 7. Проверить
crontab -l -u <real_user>
tail -f /var/log/wp-cron/action-scheduler.log
docker exec -u www-data wordpress wp action-scheduler list --status=complete --group=cashback --per_page=5
logrotate -d /etc/logrotate.d/cashback-wp-cron
```

**Про даунтайм**: шаг 3 пересоздаёт контейнер wordpress, Traefik на это время вернёт 502. Выполнять в low-traffic окно. Билд (`build`) можно сделать заранее — тогда `up -d` только подменит контейнер.

**Rollback**, если что-то пошло не так:
```bash
crontab -u <user> -r                                # снять весь crontab
git checkout HEAD~1 -- Dockerfile docker-compose.yml
docker compose build wordpress && docker compose up -d wordpress
```

---

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
