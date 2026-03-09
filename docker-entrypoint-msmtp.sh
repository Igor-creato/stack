#!/bin/bash
set -e

# ── Generate msmtp config from environment ──────────────
if [ -n "$SMTP_HOST" ]; then
  # tls_starttls: on for STARTTLS (port 587), off for implicit TLS (port 465)
  STARTTLS="on"
  if [ "$SMTP_SECURE" = "ssl" ]; then
    STARTTLS="off"
  fi

  cat > /etc/msmtprc <<EOF
defaults
auth           on
tls            on
tls_starttls   ${STARTTLS}
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /dev/stderr

account        default
host           ${SMTP_HOST}
port           ${SMTP_PORT:-587}
from           ${SMTP_FROM:-noreply@localhost}
user           ${SMTP_USER}
password       ${SMTP_PASSWORD}
EOF

  chmod 600 /etc/msmtprc
fi

# ── Delegate to the original WordPress entrypoint ───────
exec docker-entrypoint.sh "$@"
