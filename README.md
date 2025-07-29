# Lightweight Postfix SMTP Relay

This project provides a minimal, self‑contained SMTP relay running
Postfix inside a Docker container.  The primary use case is to
enable a mail server located behind a dynamic IP (for example, on a
home connection) to send outbound mail through a VPS that has a
static IP address and proper reverse DNS.  By forwarding mail to the
relay you avoid SPF/DKIM failures and the risk of being blocked by
downstream receivers that distrust dynamic address space.

## Features

* **Lightweight:** built on Alpine Linux with Postfix and Cyrus
  SASL via `saslauthd` using an LMDB backend. The resulting image
  is under 100 MB.

* **Runtime configuration:** environment variables control all
  essential parameters.  You never edit `main.cf` or `master.cf`
  directly; the entrypoint script rewrites settings using
  `postconf` on each start.
* **Automatic TLS:** if you don’t provide certificates the relay
  generates a self‑signed TLS keypair on first run so clients can
  connect via STARTTLS.  You can also mount your own certificates
  via a volume.
* **Optional client authentication:** enable SASL by toggling
  `ENABLE_SASL=true` and specifying a client `SMTP_USERNAME` and
  `SMTP_PASSWORD`. Authentication is provided by the `saslauthd`
  daemon. Only authenticated users and hosts listed in
  `ALLOWED_NETWORKS` may relay mail.
* **Smarthost support:** optionally forward all outbound mail to an
  upstream SMTP server (e.g. your ISP) with support for SMTP AUTH.
* **Logging to stdout:** Postfix 3.4+ supports the `maillog_file`
  parameter; logging to `/dev/stdout` eliminates the need for a
  separate syslog daemon in the container【819524448154663†L49-L64】.  You can
  inspect logs with `docker logs`.

## Usage

1. **Clone this repository** (or copy the `smtp-relay` directory) to
   your deployment host.
2. **Create a `.env` file** based on `.env.example` and fill in
   values appropriate for your environment:
   
   ```sh
   cp .env.example .env
   # Edit .env with your preferred values
   ```
   
   At a minimum set `RELAY_MYHOSTNAME` to a fully qualified
   hostname that resolves to your VPS’s static IP and set
   `ALLOWED_NETWORKS` to include the IP range of your dynamic mail
   server.
3. **Build and start the relay** using Docker Compose:
   
   ```sh
   docker compose up -d
   ```

   Compose will build the image, generate TLS keys if needed, and
   launch Postfix in the foreground.  Because `maillog_file` is
   configured to `/dev/stdout`, you can watch logs with
   `docker compose logs -f`.

4. **Point your dynamic mail server** (e.g. Mailcow or Postfix
   running elsewhere) at the relay’s IP/hostname and port.  If you
   enabled SASL, configure the same credentials on your mail server.
   If you disabled SASL, ensure the server’s IP is included in
   `ALLOWED_NETWORKS`.

5. **(Optional) Configure reverse DNS and SPF** records for
   `RELAY_MYHOSTNAME` so that recipients trust mail sent through
   your VPS.  Without correct DNS the relay may still work but
   messages are more likely to be marked as spam.

## How it works

Upon start the container runs `entrypoint.sh`.  This script:

1. Reads environment variables to determine the desired Postfix
   configuration.
2. Generates a self‑signed certificate if TLS is enabled and no
   certificate/key pair already exists in `/etc/postfix/certs`.
3. Writes or updates configuration parameters in `main.cf` via the
   `postconf` command.  For example, the script sets
   `myhostname`, `mydomain`, `mynetworks` and other relay
   essentials.  It also configures `maillog_file` to
   `/dev/stdout`, so that Postfix logs to standard output【819524448154663†L49-L64】.
4. Creates a Cyrus SASL database when `ENABLE_SASL=true` and the
   user and password are provided.  The credentials are stored in
   `/etc/sasldb2` using the LMDB format and persist across restarts
   thanks to the `sasl-db` volume.  Authentication is handled by the
   `saslauthd` daemon rather than direct library access.

5. Optionally creates a `sasl_passwd.db` map (stored as LMDB) for
   authenticating to an upstream smarthost if `RELAYHOST`,
   `RELAYHOST_USERNAME` and `RELAYHOST_PASSWORD` are set.  Postfix
   uses this map via `smtp_sasl_password_maps`.

6. When SASL is enabled the entrypoint launches the `saslauthd`
   daemon so Postfix can verify credentials.
7. Finally executes `postfix start-fg`, which keeps Postfix in the

For further tuning consult the [Postfix documentation](https://www.postfix.org/documentation.html).

