#!/bin/bash
#
# Runs as root, prepares the Railway volume, then drops to the image's own
# `rundeck` user and hands off to the stock docker-lib/entry.sh.
set -euo pipefail

log() { echo "railway-entrypoint: $*"; }

RUNDECK_HOME="${RUNDECK_HOME:-/home/rundeck}"
DATA="${RUNDECK_RAILWAY_DATA:-${RUNDECK_HOME}/railway-data}"
RD_UID="$(id -u rundeck)"
RD_GID=0

# ---------------------------------------------------------------------------
# Volume layout
# ---------------------------------------------------------------------------
mkdir -p "${DATA}/config" "${DATA}/projects" "${DATA}/var-logs"

# Relocate the two directories whose contents must survive a container recreate.
# Project definitions live in the database, but Rundeck still writes readme/motd
# and resource files under projects/; var/logs is the execution-log cache that
# the S3 plugin uploads from.
# Never fatal: if the path cannot be replaced the app still boots, it just keeps
# that directory on the container filesystem.
relocate() {
    local src="$1" dst="$2"
    if [ -L "${src}" ]; then
        return 0
    fi
    if [ -d "${src}" ] && ! cp -a "${src}/." "${dst}/"; then
        log "WARNING: could not copy ${src} onto the volume; leaving it in place"
        return 0
    fi
    if ! rm -rf "${src}"; then
        log "WARNING: could not replace ${src}; leaving it in place"
        return 0
    fi
    ln -s "${dst}" "${src}"
    log "relocated ${src} -> ${dst}"
}
relocate "${RUNDECK_HOME}/projects" "${DATA}/projects"
relocate "${RUNDECK_HOME}/var/logs" "${DATA}/var-logs"

# ---------------------------------------------------------------------------
# First admin
#
# rundeck.war --installonly bakes `admin:admin,user,admin` into
# server/config/realm.properties at image build time, and the image exposes no
# variable to change it. Keep the real file on the volume so an operator can add
# further users by hand, and rewrite only the admin line, only when the
# configured pair actually changes.
# ---------------------------------------------------------------------------
ADMIN_USER="${RUNDECK_ADMIN_USER:-admin}"
ADMIN_PASSWORD="${RUNDECK_ADMIN_PASSWORD:-}"
ADMIN_ROLES="${RUNDECK_ADMIN_ROLES:-user,admin,architect,deploy,build}"
ADMIN_ENCODING="${RUNDECK_ADMIN_PASSWORD_ENCODING:-bcrypt}"

if [ -z "${ADMIN_PASSWORD}" ]; then
    echo "railway-entrypoint: FATAL: RUNDECK_ADMIN_PASSWORD is empty." >&2
    echo "railway-entrypoint: refusing to start on the image's default admin/admin." >&2
    exit 1
fi

case "${ADMIN_ENCODING}" in
    bcrypt)
        # htpasswd emits ":$2y$..."; Rundeck's verifier wants the $2a$ variant.
        ADMIN_CRED="BCRYPT:$(htpasswd -bnBC 10 "" "${ADMIN_PASSWORD}" \
            | tr -d '\n' | sed -e 's/^://' -e 's/^\$2y\$/\$2a\$/')"
        ;;
    md5)
        ADMIN_CRED="MD5:$(printf '%s' "${ADMIN_PASSWORD}" | md5sum | cut -d' ' -f1)"
        ;;
    plain)
        ADMIN_CRED="${ADMIN_PASSWORD}"
        ;;
    *)
        echo "railway-entrypoint: FATAL: RUNDECK_ADMIN_PASSWORD_ENCODING must be bcrypt, md5 or plain." >&2
        exit 1
        ;;
esac

REALM_VOL="${DATA}/config/realm.properties"
REALM_LIVE="${RUNDECK_HOME}/server/config/realm.properties"
ADMIN_STAMP="${DATA}/config/.admin-stamp"

if [ ! -f "${REALM_VOL}" ]; then
    # Deliberately not seeded from the image's copy, which carries admin/admin.
    {
        echo "# Rundeck users. Managed by the Railway entrypoint."
        echo "# The ${ADMIN_USER} line is rewritten whenever RUNDECK_ADMIN_PASSWORD changes."
        echo "# Additional users added below this line persist across deployments."
    } > "${REALM_VOL}"
    log "created ${REALM_VOL}"
fi

WANT_STAMP="$(printf '%s\n' "${ADMIN_USER}" "${ADMIN_ROLES}" "${ADMIN_ENCODING}" "${ADMIN_PASSWORD}" \
    | sha256sum | cut -d' ' -f1)"
HAVE_STAMP="$(cat "${ADMIN_STAMP}" 2>/dev/null || true)"

if [ "${HAVE_STAMP}" != "${WANT_STAMP}" ] || ! grep -q "^${ADMIN_USER}:" "${REALM_VOL}"; then
    TMP_REALM="$(mktemp)"
    grep -v "^${ADMIN_USER}:" "${REALM_VOL}" > "${TMP_REALM}" || true
    printf '%s: %s,%s\n' "${ADMIN_USER}" "${ADMIN_CRED}" "${ADMIN_ROLES}" >> "${TMP_REALM}"
    cat "${TMP_REALM}" > "${REALM_VOL}"
    rm -f "${TMP_REALM}"
    printf '%s' "${WANT_STAMP}" > "${ADMIN_STAMP}"
    log "wrote ${ADMIN_ENCODING} credential for user '${ADMIN_USER}'"
else
    log "admin credential unchanged; leaving realm.properties alone"
fi

rm -f "${REALM_LIVE}"
ln -s "${REALM_VOL}" "${REALM_LIVE}"

# ---------------------------------------------------------------------------
# S3 execution-log storage
#
# The image's plugin-s3-logstore.properties template renders only `bucket` and
# `region`. Everything a non-AWS endpoint needs is appended here as a second
# framework.properties partial: docker-lib/entry.sh cats every file in
# ${REMCO_TMP_DIR}/framework into etc/framework.properties after remco runs.
# ---------------------------------------------------------------------------
REMCO_TMP_DIR="${REMCO_TMP_DIR:-/tmp/remco-partials}"
mkdir -p "${REMCO_TMP_DIR}/framework"

if [ "${RUNDECK_PLUGIN_EXECUTIONFILESTORAGE_NAME:-}" = "org.rundeck.amazon-s3" ]; then
    S3_STEM="framework.plugin.ExecutionFileStorage.org.rundeck.amazon-s3"
    S3_PARTIAL="${REMCO_TMP_DIR}/framework/zz-railway-s3.properties"
    : > "${S3_PARTIAL}"
    if [ -n "${RUNDECK_PLUGIN_EXECUTIONFILESTORAGE_S3_ENDPOINT:-}" ]; then
        echo "${S3_STEM}.endpoint=${RUNDECK_PLUGIN_EXECUTIONFILESTORAGE_S3_ENDPOINT}" >> "${S3_PARTIAL}"
    fi
    if [ -n "${RUNDECK_PLUGIN_EXECUTIONFILESTORAGE_S3_ACCESSKEY:-}" ]; then
        echo "${S3_STEM}.AWSAccessKeyId=${RUNDECK_PLUGIN_EXECUTIONFILESTORAGE_S3_ACCESSKEY}" >> "${S3_PARTIAL}"
    fi
    if [ -n "${RUNDECK_PLUGIN_EXECUTIONFILESTORAGE_S3_SECRETKEY:-}" ]; then
        echo "${S3_STEM}.AWSSecretKey=${RUNDECK_PLUGIN_EXECUTIONFILESTORAGE_S3_SECRETKEY}" >> "${S3_PARTIAL}"
    fi
    echo "${S3_STEM}.pathStyle=${RUNDECK_PLUGIN_EXECUTIONFILESTORAGE_S3_PATHSTYLE:-true}" >> "${S3_PARTIAL}"
    echo "${S3_STEM}.path=${RUNDECK_PLUGIN_EXECUTIONFILESTORAGE_S3_PATH:-rundeck/\${job.project}/\${job.execid}.log}" >> "${S3_PARTIAL}"
    log "wrote S3 execution-log storage partial"
fi

# ---------------------------------------------------------------------------
# Cross-service defaults
#
# A ${{service.RAILWAY_PRIVATE_DOMAIN}} reference renders empty until that
# service owns a deployment, and Railway never injects an empty variable, so the
# mail host arrives absent on a template's very first deploy. The private
# hostname is deterministic, so default it rather than shipping a broken mailer.
# ---------------------------------------------------------------------------
case "${RUNDECK_MAIL_SMTP_HOST:-}" in
    ""|":"*)
        export RUNDECK_MAIL_SMTP_HOST="${RUNDECK_MAIL_SMTP_HOST_DEFAULT:-mailpit.railway.internal}"
        log "defaulted RUNDECK_MAIL_SMTP_HOST to ${RUNDECK_MAIL_SMTP_HOST}"
        ;;
esac

# Cluster mode is hard-coded on in the image's rundeck-config template, and a
# node that is not named as the primary logs a warning and leaves schedule
# ownership implicit. Single-node here, so this node is the primary.
: "${RUNDECK_PRIMARYSERVERID:=${RUNDECK_SERVER_UUID:-a14bc3e6-75e8-4fe4-a90d-a16dcc976bf6}}"
export RUNDECK_PRIMARYSERVERID

# ---------------------------------------------------------------------------
# Hand off
# ---------------------------------------------------------------------------
chown -R "${RD_UID}:${RD_GID}" "${DATA}" "${REMCO_TMP_DIR}"
chmod 0750 "${DATA}"
chmod 0640 "${REALM_VOL}"

cd "${RUNDECK_HOME}"
export HOME="${RUNDECK_HOME}"

# Arguments land between the JVM options entry.sh sets and `-jar rundeck.war`.
#  * preferIPv6Addresses: Railway's private network resolves peers AAAA-first and
#    a container's 10.x A record is not routable from another service.
#  * server.port: keeps the listener on whatever port Railway probes.
exec setpriv --reuid="${RD_UID}" --regid="${RD_GID}" --init-groups \
    "${RUNDECK_HOME}/docker-lib/entry.sh" \
    -Djava.net.preferIPv6Addresses=true \
    -Dserver.port="${PORT:-4440}"
