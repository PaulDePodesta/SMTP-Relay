#!/bin/bash
#
# entrypoint.sh – build Postfix configuration at runtime
#
# This script is executed as the container entrypoint.  It reads a
# series of environment variables, creates or updates Postfix
# configuration accordingly, optionally generates self‑signed TLS
# certificates and SASL user databases, and finally launches
# Postfix in the foreground.  By performing all configuration at
# container startup rather than during image build we make it
# possible to adjust the relay’s behaviour purely via a .env file
# without rebuilding or modifying the image.
#
# References:
#  * Postfix 3.3 introduces the `start‑fg` command, which allows
#    Postfix to run as PID 1 inside a container【219023648407850†L19-L23】.
#  * To log directly to stdout, Postfix 3.4+ supports the
#    `maillog_file` parameter.  Setting `maillog_file = /dev/stdout`
#    and using `postfix start-fg` eliminates the need for an
#    additional syslog daemon【819524448154663†L49-L64】.

set -euo pipefail

# Default values.  These can be overridden in the docker-compose
# environment.  Most values correspond directly to Postfix
# parameters documented in postconf(5).

# Hostname of this relay.  A fully qualified domain name is
# recommended (e.g. relay.example.com).  If not set we fall back
# to the container’s own hostname.
RELAY_MYHOSTNAME=${RELAY_MYHOSTNAME:-$(hostname -f 2>/dev/null || hostname)}

# Domain this relay will pretend to originate mail from.  Used for
# $myorigin and for SASL realm.  If not provided, derive from
# RELAY_MYHOSTNAME by stripping the first label.
if [[ -n "${RELAY_DOMAIN:-}" ]]; then
    RELAY_DOMAIN="${RELAY_DOMAIN}"
else
    # Extract domain by removing everything up to the first dot
    RELAY_DOMAIN="${RELAY_MYHOSTNAME#*.}" || RELAY_DOMAIN="localdomain"
fi

# The networks allowed to relay without authentication.  Specify
# subnets or individual IP addresses, separated by spaces or commas.
# The default allows only localhost.  You should explicitly list
# the IP/subnet of your dynamic mail server here (e.g. 192.168.1.0/24).
ALLOWED_NETWORKS=${ALLOWED_NETWORKS:-"127.0.0.0/8 [::1]/128"}

# Relayhost – optional upstream SMTP smarthost.  Leave empty if
# this relay should deliver mail directly.  Syntax: [hostname]:port
# For example: "[smtp.example.com]:587".  When set, you can also
# specify RELAYHOST_USERNAME and RELAYHOST_PASSWORD to enable
# authentication to the upstream server.
RELAYHOST=${RELAYHOST:-""}
RELAYHOST_USERNAME=${RELAYHOST_USERNAME:-""}
RELAYHOST_PASSWORD=${RELAYHOST_PASSWORD:-""}

# Enable or disable TLS (STARTTLS) for incoming connections.  When
# set to "true" (case‑insensitive), the container will ensure that
# the certificates referenced by TLS_CERT and TLS_KEY exist,
# generating self‑signed ones if necessary.  See also TLS_* variables.
ENABLE_TLS=${ENABLE_TLS:-"true"}
TLS_CERT=${TLS_CERT:-"/etc/postfix/certs/relay-cert.pem"}
TLS_KEY=${TLS_KEY:-"/etc/postfix/certs/relay-key.pem"}
TLS_CA=${TLS_CA:-"/etc/ssl/certs/ca-certificates.crt"}

# When authentication of clients is required you can enable SASL.
# The username/password specified here will be used to create the
# Cyrus SASL database on first run.  If SASL is disabled (default),
# clients are expected to be part of ALLOWED_NETWORKS.  Set
# ENABLE_SASL=true to enforce authentication.
ENABLE_SASL=${ENABLE_SASL:-"false"}
SMTP_USERNAME=${SMTP_USERNAME:-""}
SMTP_PASSWORD=${SMTP_PASSWORD:-""}

# Message size limit (in bytes).  Default to 10 MiB.  Set to 0 to
# disable the limit.  The Postfix default is 10 MiB; we allow
# override for larger attachments.
MESSAGE_SIZE_LIMIT=${MESSAGE_SIZE_LIMIT:-10485760}

# Path to the Postfix main configuration file
POSTFIX_MAIN_CF="/etc/postfix/main.cf"

# Function: update a Postfix configuration parameter if it is not
# already set to the desired value.  This avoids appending the same
# key multiple times when the container restarts.
update_postconf() {
    local key="$1"
    local value="$2"
    if postconf -h "$key" 2>/dev/null | grep -q "^$value$"; then
        return
    fi
    postconf -e "$key = $value"
}

# Ensure TLS certificates exist when TLS is enabled.
maybe_generate_certs() {
    if [[ "${ENABLE_TLS,,}" != "true" ]]; then
        return
    fi
    if [[ ! -f "$TLS_CERT" || ! -f "$TLS_KEY" ]]; then
        echo "[INFO] Generating self‑signed TLS certificate for $RELAY_MYHOSTNAME"
        mkdir -p "$(dirname "$TLS_CERT")"
        openssl req -new -nodes -x509 -days 3650 \
            -subj "/CN=${RELAY_MYHOSTNAME}" \
            -newkey rsa:4096 \
            -keyout "$TLS_KEY" -out "$TLS_CERT"
        chmod 600 "$TLS_KEY"
    fi
}

# Configure SASL database if authentication is enabled.  We only
# recreate the database if the file does not exist or if the user
# environment has changed.  The file /etc/sasldb2 will be used.
maybe_setup_sasl() {
    if [[ "${ENABLE_SASL,,}" != "true" ]]; then
        update_postconf smtpd_sasl_auth_enable "no"
        return
    fi
    update_postconf smtpd_sasl_auth_enable "yes"
    update_postconf smtpd_sasl_type "cyrus"
    update_postconf smtpd_sasl_path "smtpd"
    update_postconf smtpd_sasl_local_domain "$RELAY_DOMAIN"
    update_postconf smtpd_sasl_security_options "noanonymous"
    update_postconf smtpd_tls_auth_only "no"
    # Cyrus SASL config for smtpd
    cat > /etc/sasl2/smtpd.conf <<EOF
pwcheck_method: auxprop
auxprop_plugin: sasldb
mech_list: PLAIN LOGIN CRAM-MD5 DIGEST-MD5
EOF
    local db="/etc/sasldb2"
    if [[ -n "$SMTP_USERNAME" && -n "$SMTP_PASSWORD" ]]; then
        if [[ ! -f "$db" ]]; then
            echo "[INFO] Creating SASL user database"
        else
            echo "[INFO] Updating SASL credentials for user $SMTP_USERNAME"
        fi
        echo "$SMTP_PASSWORD" | saslpasswd2 -p -c -f "$db" -u "$RELAY_DOMAIN" "$SMTP_USERNAME"
        chown root:mail "$db"
        chmod 640 "$db"
    else
        echo "[WARN] SASL enabled but SMTP_USERNAME/SMTP_PASSWORD not provided; clients will be unable to authenticate"
    fi
}

# Configure relayhost authentication if user provided upstream credentials.
maybe_setup_relayhost_auth() {
    if [[ -z "$RELAYHOST" ]]; then
        # ensure we don’t accidentally reuse old settings
        update_postconf relayhost ""
        return
    fi
    update_postconf relayhost "$RELAYHOST"
    if [[ -n "$RELAYHOST_USERNAME" && -n "$RELAYHOST_PASSWORD" ]]; then
        local passfile="/etc/postfix/sasl_passwd"
        echo "$RELAYHOST $RELAYHOST_USERNAME:$RELAYHOST_PASSWORD" > "$passfile"
        postmap hash:"$passfile"
        rm -f "$passfile"
        update_postconf smtp_sasl_auth_enable "yes"
        update_postconf smtp_sasl_password_maps "hash:/etc/postfix/sasl_passwd.db"
        update_postconf smtp_sasl_security_options "noanonymous"
        update_postconf smtp_sasl_tls_security_options "noanonymous"
    fi
}

# Apply base Postfix configuration.  We intentionally do not
# overwrite user modifications when restarting; instead we update
# specific keys via postconf.  Many of these settings are required
# for a functioning relay in a container environment.
apply_base_configuration() {
    update_postconf myhostname "$RELAY_MYHOSTNAME"
    update_postconf mydomain "$RELAY_DOMAIN"
    update_postconf myorigin "$RELAY_DOMAIN"
    update_postconf mydestination "localhost.localdomain, localhost"
    # Convert comma separated networks to space separated list expected by Postfix
    local networks="${ALLOWED_NETWORKS//,/ }"
    update_postconf mynetworks "$networks"
    update_postconf inet_interfaces "all"
    update_postconf inet_protocols "all"
    update_postconf message_size_limit "$MESSAGE_SIZE_LIMIT"
    update_postconf smtpd_recipient_restrictions "permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination"
    update_postconf smtpd_helo_required "yes"
    update_postconf smtpd_banner "$RELAY_MYHOSTNAME ESMTP"
    # log to stdout via postlogd; requires Postfix ≥3.4 and maillog_file
    update_postconf maillog_file "/dev/stdout"
    # TLS configuration for inbound SMTP
    if [[ "${ENABLE_TLS,,}" == "true" ]]; then
        update_postconf smtpd_tls_cert_file "$TLS_CERT"
        update_postconf smtpd_tls_key_file "$TLS_KEY"
        update_postconf smtpd_tls_CAfile "$TLS_CA"
        update_postconf smtpd_use_tls "yes"
        update_postconf smtpd_tls_security_level "may"
        update_postconf smtp_tls_security_level "may"
    else
        update_postconf smtpd_use_tls "no"
        update_postconf smtpd_tls_security_level "none"
    fi
}

main() {
    maybe_generate_certs
    apply_base_configuration
    maybe_setup_sasl
    maybe_setup_relayhost_auth
    # Ensure Postfix spools and configuration are up to date
    postfix check
    echo "[INFO] Starting Postfix in foreground…"
    exec postfix start-fg
}

main "$@"