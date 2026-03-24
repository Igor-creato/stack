FROM wordpress:6.9.4-php8.4-fpm

RUN apt-get update \
    && apt-get install -y --no-install-recommends msmtp msmtp-mta ca-certificates \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

COPY docker-entrypoint-msmtp.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint-msmtp.sh

RUN curl -o /usr/local/bin/wp https://github.com/wp-cli/wp-cli/releases/download/v2.12.0/wp-cli-2.12.0.phar \
    && chmod +x /usr/local/bin/wp \
    && mkdir -p /var/www/.wp-cli/cache \
    && chown -R www-data:www-data /var/www/.wp-cli

ENTRYPOINT ["docker-entrypoint-msmtp.sh"]
CMD ["php-fpm"]
