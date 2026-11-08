# A disposable sshd for the UI suite: the dedicated test account with tmux, mosh and SFTP.
# The password is never baked in; serve-container-fixture.sh mounts it at /run/fixture/password.
FROM debian:bookworm-slim
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openssh-server tmux mosh python3 iproute2 locales ca-certificates \
 && sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen \
 && echo 'LANG=en_US.UTF-8' > /etc/default/locale \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --create-home --shell /bin/bash itermux_test \
 && sed -i 's|^Subsystem.*sftp.*|Subsystem sftp internal-sftp|' /etc/ssh/sshd_config \
 && mkdir -p /run/sshd
# ENV reaches sshd only; SSH sessions take their locale from PAM's /etc/default/locale, as on a Debian server.
ENV LANG=en_US.UTF-8
COPY sshd_config /etc/ssh/sshd_config.d/roamtty.conf
COPY entrypoint.sh /entrypoint.sh
EXPOSE 22
ENTRYPOINT ["/bin/sh", "/entrypoint.sh"]
