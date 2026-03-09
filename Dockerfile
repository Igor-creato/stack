FROM wordpress:php8.4-fpm

# msmtp — lightweight sendmail replacement for SMTP relay
RUN apt-get update \
    && apt-get install -y --no-install-recommends msmtp msmtp-mta ca-certificates \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Entrypoint wrapper: generates /etc/msmtprc from env vars
COPY docker-entrypoint-msmtp.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint-msmtp.sh

# WP-CLI
RUN curl -o /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
    && chmod +x /usr/local/bin/wp \
    && mkdir -p /var/www/.wp-cli/cache \
    && chown -R www-data:www-data /var/www/.wp-cli

ENTRYPOINT ["docker-entrypoint-msmtp.sh"]
CMD ["php-fpm"]
