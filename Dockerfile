# A lightweight SMTP relay built on Alpine Linux.
#
# This image installs Postfix and Cyrus SASL on top of a minimal Alpine
# base image.  Configuration is handled at run time via environment
# variables so that the same image can be used in different
# deployments without rebuilding.  See the accompanying `entrypoint.sh`
# for details of how variables are interpreted.
#
# To reduce the size of the image we install only the packages that
# are required for an SMTP relay: postfix itself, a few Cyrus SASL
# modules for authentication, and OpenSSL for certificate generation.
FROM alpine:3.20


# Use the standard repositories; SASL stores credentials in an LMDB database
# to avoid gdbm-related issues on Alpine.

# Metadata
LABEL maintainer="Postfix Relay Maintainer <maintainer@example.com>"
LABEL description="Minimal Postfix SMTP relay with optional TLS and SASL auth support"

# Install postfix and SASL packages.  We also install
# openssl so that the container can generate self‑signed certificates
# when no TLS materials are provided via environment variables.
RUN apk add --no-cache \
#	cyrus-sasl-auxprop \ 
	lmdb-tools \
        strace \
        postfix \
        cyrus-sasl \
        cyrus-sasl-login \
        cyrus-sasl-utils \
        openssl \
        bash

# Prepare directories for certificates and SASL database.  The
# directories under /etc/postfix will be used by the entrypoint
# script to store generated TLS keys and certificates on first run.
RUN mkdir -p /etc/postfix/certs /etc/sasl2

# Copy entrypoint script into the image.  The script will be
# responsible for generating configuration files based on the
# environment and then launching Postfix in the foreground.
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# By default Postfix listens on port 25.  If you choose to expose
# another port (e.g. 587) you can override that in your docker
# compose file.
EXPOSE 25

# Use a bash wrapper as the entrypoint so that environment
# substitutions and command execution can be handled from a single
# script.  We deliberately avoid running multiple services under
# supervisor; instead Postfix runs in the foreground as PID 1 per
# Postfix 3.3+ container support【219023648407850†L19-L25】.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# Default command launches Postfix.  `entrypoint.sh` will rewrite
# this command when appropriate.  Keeping CMD separate allows the
# user to override the command at runtime if they need to debug.
CMD ["postfix", "start-fg"]

