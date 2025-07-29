#!/bin/bash
# entrypoint.sh – build Postfix configuration at runtime
set -euo pipefail

# ─── Defaults and Environment Parsing ───
RELAY_MYHOSTNAME=${RELAY_MYHOSTNAME:-$(hostname -f 2>/dev/null || hostname)}
if [[ -z "${RELAY_DOMAIN:-}" ]]; then
  RELAY_DOMAIN="${RELAY_MYHOSTNAME#*.}"
  RELAY_DOMAIN=${RELAY_DOMAIN:-localdomain}
fi
ALLOWED_NETWORKS=${ALLOWED_NETWORKS:-"127.0.0.0/8 [::1]/128"}
RELAYHOST=${RELAYHOST:-""}
RELAYHOST_USERNAME=${RELAYHOST_USERNAME:-""}
RELAYHOST_PASSWORD=${RELAYHOST_PASSWORD:-""}
ENABLE_TLS=${ENABLE_TLS:-"true"}
TLS_CERT=${TLS_CERT:-"/etc/postfix/certs/relay-cert.pem"}
TLS_KEY=${TLS_KEY:-"/etc/postfix/certs/relay-key.pem"}
TLS_CA=${TLS_CA:-"/etc/ssl/certs/ca-certificates.crt"}
ENABLE_SASL=${ENABLE_SASL:-"false"}
SMTP_USERNAME=${SMTP_USERNAME:-""}
SMTP_PASSWORD=${SMTP_PASSWORD:-""}
MESSAGE_SIZE_LIMIT=${MESSAGE_SIZE_LIMIT:-10485760}
POSTFIX_MAIN_CF="/etc/postfix/main.cf"

# ─── Disable chroot for smtpd ───
sed -ri '
  s|^(smtp\s+inet\s+n\s+-\s+)[yn](\s+-\s+-\s+smtpd)|\1n\2|
' /etc/postfix/master.cf

# ─── Ensure alias DB exists ───
touch /etc/postfix/aliases
newaliases

# ─── Recreate SASL DB if needed ───
if [[ "${ENABLE_SASL,,}" == "true" && -n "$SMTP_USERNAME" && -n "$SMTP_PASSWORD" ]]; then
  rm -f /etc/sasl2/sasldb2.mdb
  echo "[INFO] Re-creating SASL user database at /etc/sasl2/sasldb2.mdb"
  echo "$SMTP_PASSWORD" \
  | saslpasswd2 -c -p -f /etc/sasl2/sasldb2.mdb -u "$RELAY_DOMAIN" "$SMTP_USERNAME"
  #echo "$SMTP_PASSWORD" \
  #  | saslpasswd2 -c -p -f /etc/sasl2/sasldb2.mdb -u "$RELAY_DOMAIN" "$SMTP_USERNAME"
  chown postfix:postfix /etc/sasl2/sasldb2.mdb
  chmod 600 /etc/sasl2/sasldb2.mdb

  echo "[DEBUG] SASL DB file details: $(ls -lh /etc/sasl2/sasldb2.mdb)"
  echo "[DEBUG] SASL users:"
  sasldblistusers2 -f /etc/sasl2/sasldb2.mdb || echo "[DEBUG] Failed to list users"
fi

# ─── Helper: update postconf only if changed ───
update_postconf() {
  local key="$1" value="$2"
  if postconf -h "$key" 2>/dev/null | grep -q "^$value$"; then return; fi
  postconf -e "$key = $value"
}

# ─── Generate self-signed TLS certificates if enabled ───
maybe_generate_certs() {
  if [[ "${ENABLE_TLS,,}" != "true" ]]; then return; fi
  if [[ ! -f "$TLS_CERT" || ! -f "$TLS_KEY" ]]; then
    echo "[INFO] Generating self‑signed TLS certificate for $RELAY_MYHOSTNAME"
    mkdir -p "$(dirname "$TLS_CERT")"
    openssl req -new -nodes -x509 -days 3650 \
      -subj "/CN=$RELAY_MYHOSTNAME" \
      -newkey rsa:4096 \
      -keyout "$TLS_KEY" -out "$TLS_CERT"
    chmod 600 "$TLS_KEY"
  fi
}

# ─── Configure SASL if enabled ───
maybe_setup_sasl() {
  if [[ "${ENABLE_SASL,,}" != "true" ]]; then
    update_postconf smtpd_sasl_auth_enable no
    return
  fi
  update_postconf smtpd_sasl_auth_enable yes
  update_postconf smtpd_sasl_type cyrus
  update_postconf smtpd_sasl_path smtpd
  update_postconf smtpd_sasl_local_domain "$RELAY_DOMAIN"
  update_postconf smtpd_sasl_security_options noanonymous
  update_postconf smtpd_tls_auth_only no
  cat > /etc/sasl2/smtpd.conf <<EOF
pwcheck_method: auxprop
auxprop_plugin: sasldb
mech_list: PLAIN LOGIN CRAM-MD5 DIGEST-MD5
sasldb_path: /etc/sasl2/sasldb2.mdb #/etc/sasl2/sasldb2
EOF
}

# ─── Configure relayhost auth if provided ───
maybe_setup_relayhost_auth() {
  if [[ -z "$RELAYHOST" ]]; then
    update_postconf relayhost ""
    return
  fi
  update_postconf relayhost "$RELAYHOST"
  if [[ -n "$RELAYHOST_USERNAME" && -n "$RELAYHOST_PASSWORD" ]]; then
    echo "$RELAYHOST $RELAYHOST_USERNAME:$RELAYHOST_PASSWORD" > /etc/postfix/sasl_passwd
    postmap hash:/etc/postfix/sasl_passwd
    rm -f /etc/postfix/sasl_passwd
    update_postconf smtp_sasl_auth_enable yes
    update_postconf smtp_sasl_password_maps hash:/etc/postfix/sasl_passwd.db
    update_postconf smtp_sasl_security_options noanonymous
    update_postconf smtp_sasl_tls_security_options noanonymous
  fi
}

# ─── Apply base Postfix configuration ───
apply_base_configuration() {
  update_postconf myhostname "$RELAY_MYHOSTNAME"
  update_postconf mydomain "$RELAY_DOMAIN"
  update_postconf myorigin "$RELAY_DOMAIN"
  update_postconf mydestination "localhost.localdomain, localhost"
  update_postconf mynetworks "${ALLOWED_NETWORKS//,/ }"
  update_postconf inet_interfaces all
  update_postconf inet_protocols all
  update_postconf message_size_limit "$MESSAGE_SIZE_LIMIT"
  update_postconf smtpd_recipient_restrictions "permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination"
  update_postconf smtpd_helo_required yes
  update_postconf smtpd_banner "$RELAY_MYHOSTNAME ESMTP"
  update_postconf maillog_file /dev/stdout
  if [[ "${ENABLE_TLS,,}" == "true" ]]; then
    update_postconf smtpd_tls_cert_file "$TLS_CERT"
    update_postconf smtpd_tls_key_file "$TLS_KEY"
    update_postconf smtpd_tls_CAfile "$TLS_CA"
    update_postconf smtpd_use_tls yes
    update_postconf smtpd_tls_security_level may
    update_postconf smtp_tls_security_level may
  else
    update_postconf smtpd_use_tls no
    update_postconf smtpd_tls_security_level none
  fi
}

# ─── Entrypoint ───
main() {
  maybe_generate_certs
  apply_base_configuration
  maybe_setup_sasl
  maybe_setup_relayhost_auth
  postfix check
  echo "[INFO] Starting Postfix in foreground…"
  exec postfix start-fg
}

main "$@"
