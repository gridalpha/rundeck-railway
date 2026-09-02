# Rundeck on Railway
#
# Three things the published rundeck/rundeck image cannot do on its own, and this
# layer supplies each of them:
#
#  1. The first admin is baked into server/config/realm.properties as admin/admin
#     and no environment variable replaces it. entrypoint.sh writes a bcrypt line
#     from RUNDECK_ADMIN_USER / RUNDECK_ADMIN_PASSWORD onto the volume instead.
#  2. Its remco template for the S3 execution-log plugin renders only `bucket` and
#     `region`, so the endpoint, path-style flag and credentials that a non-AWS
#     S3 endpoint needs have to be appended as a framework.properties partial.
#  3. The image runs as the non-root `rundeck` user, which cannot write a
#     root-owned Railway volume; the entrypoint chowns it and drops back.
#
# The S3 execution-log plugin is not bundled with Rundeck; it is dropped into
# container-plugins/, which the image's own 110_sideload_container_plugins.sh
# copies into libext/ on every boot.

FROM rundeck/rundeck:6.1.0

# RUN/COPY inherit the base image's USER, which is `rundeck`.
USER root

ARG S3_LOG_PLUGIN_VERSION=3.0.5

RUN apt-get update \
    && apt-get install -y --no-install-recommends apache2-utils \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL -o /home/rundeck/container-plugins/rundeck-s3-log-plugin.jar \
        "https://github.com/rundeck-plugins/rundeck-s3-log-plugin/releases/download/${S3_LOG_PLUGIN_VERSION}/rundeck-s3-log-plugin-${S3_LOG_PLUGIN_VERSION}.jar" \
    && chown rundeck:root /home/rundeck/container-plugins/rundeck-s3-log-plugin.jar \
    && chmod 0644 /home/rundeck/container-plugins/rundeck-s3-log-plugin.jar

COPY entrypoint.sh /usr/local/bin/railway-entrypoint.sh
RUN chmod 0755 /usr/local/bin/railway-entrypoint.sh \
    && bash -n /usr/local/bin/railway-entrypoint.sh \
    && command -v setpriv >/dev/null \
    && command -v htpasswd >/dev/null

EXPOSE 4440

# The base image declares no CMD, so replacing ENTRYPOINT loses nothing.
# -s registers tini as a child subreaper: Railway's runtime owns PID 1.
ENTRYPOINT ["/tini", "-s", "--", "/usr/local/bin/railway-entrypoint.sh"]
