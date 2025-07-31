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
# Allow overriding of Dovecot authentication mechanisms.  By default we
# advertise only the PLAIN and LOGIN mechanisms, which are universally
# supported and work with passwords stored in plain text.  The
# previous implementation always advertised CRAM‑MD5 and DIGEST‑MD5 as
# well, which caused authentication errors when using plain‑text
# passwords【763605965413718†L197-L227】.  Administrators can override this
# setting via AUTH_MECHANISMS in the environment if they need to
# explicitly enable additional mechanisms.  For example:
#   AUTH_MECHANISMS="plain login cram‑md5"
# Note that non‑plaintext mechanisms require that the password be
# stored either in plain text or using the mechanism's own scheme.
AUTH_MECHANISMS=${AUTH_MECHANISMS:-"plain login"}

# Support specifying multiple SMTP users via a single environment
# variable.  Set SMTP_USERS to a comma‑separated list of
# "username:password" pairs.  When provided this takes precedence over
# SMTP_USERNAME/SMTP_PASSWORD and allows creating multiple relay
# accounts without rebuilding the image.  Example:
#   SMTP_USERS="user1:secret1,user2:secret2"
SMTP_USERS=${SMTP_USERS:-""}
MESSAGE_SIZE_LIMIT=${MESSAGE_SIZE_LIMIT:-10485760}
POSTFIX_MAIN_CF="/etc/postfix/main.cf"

# ─── Disable chroot for smtpd ───
sed -ri '
  s|^(smtp\s+inet\s+n\s+-\s+)[yn](\s+-\s+-\s+smtpd)|\1n\2|
' /etc/postfix/master.cf

# ─── Ensure alias DB exists ───
touch /etc/postfix/aliases
newaliases


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
  update_postconf smtpd_sasl_type dovecot
  update_postconf smtpd_sasl_path private/auth
  update_postconf smtpd_sasl_local_domain "$RELAY_DOMAIN"
  update_postconf smtpd_sasl_security_options noanonymous
  update_postconf smtpd_tls_auth_only no
  mkdir -p /etc/dovecot
  # Write a minimal Dovecot configuration for SASL auth.  We expand
  # AUTH_MECHANISMS here to allow administrators to control which
  # mechanisms are advertised.  See AUTH_MECHANISMS above for details.
  cat > /etc/dovecot/dovecot.conf <<EOF
disable_plaintext_auth = no
auth_mechanisms = ${AUTH_MECHANISMS}
passdb {
  driver = passwd-file
  args = /etc/dovecot/users
}
userdb {
  driver = static
  args = uid=postfix gid=postfix home=/var/spool/postfix/home/mailcowrelay
}
service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0660
    user = postfix
    group = postfix
  }
}

EOF
mkdir -p /var/spool/postfix/home/mailcowrelay
chown postfix:postfix /var/spool/postfix/home/mailcowrelay

  # Build the user database.  Prefer SMTP_USERS for multiple
  # accounts; fall back to single SMTP_USERNAME/SMTP_PASSWORD.  Each
  # entry is stored with the {PLAIN} scheme so Dovecot can derive
  # responses for non‑plaintext mechanisms【763605965413718†L197-L227】.  If no
  # credentials are provided the relay will still start, but
  # authentication attempts will fail.
  : > /etc/dovecot/users  # truncate or create file
  if [[ -n "$SMTP_USERS" ]]; then
    IFS=',' read -ra _user_arr <<< "$SMTP_USERS"
    for _entry in "${_user_arr[@]}"; do
      IFS=':' read -r _user _pass <<< "$_entry"
      if [[ -n "$_user" && -n "$_pass" ]]; then
        echo "${_user}:{PLAIN}${_pass}" >> /etc/dovecot/users
      fi
    done
  elif [[ -n "$SMTP_USERNAME" && -n "$SMTP_PASSWORD" ]]; then
    echo "$SMTP_USERNAME:{PLAIN}$SMTP_PASSWORD" >> /etc/dovecot/users
  fi
  if [[ -s /etc/dovecot/users ]]; then
    chown root:root /etc/dovecot/users
    chmod 600 /etc/dovecot/users
  else
    echo "[WARN] SASL enabled but no SMTP_USERS or SMTP_USERNAME/SMTP_PASSWORD provided; clients will be unable to authenticate"
  fi
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
    # Explicitly build the map using LMDB to avoid the gdbm backend
    postmap lmdb:/etc/postfix/sasl_passwd
    rm -f /etc/postfix/sasl_passwd
    update_postconf smtp_sasl_auth_enable yes
    update_postconf smtp_sasl_password_maps lmdb:/etc/postfix/sasl_passwd.db
    update_postconf smtp_sasl_security_options noanonymous
    update_postconf smtp_sasl_tls_security_options noanonymous
  fi
}


# ─── Start Dovecot if SASL enabled ───
start_dovecot() {
  if [[ "${ENABLE_SASL,,}" != "true" ]]; then return; fi
  echo "[INFO] Starting Dovecot for SASL authentication"
  dovecot

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

  start_dovecot

  postfix check
  echo "[INFO] Starting Postfix in foreground…"
  exec postfix start-fg
}

main "$@"
