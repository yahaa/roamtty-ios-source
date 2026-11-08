#!/bin/sh
set -eu
printf 'itermux_test:%s\n' "$(cat /run/fixture/password)" | chpasswd
# A fresh host key per container; the suite trusts it on first use.
ssh-keygen -A >/dev/null
exec /usr/sbin/sshd -D -e
