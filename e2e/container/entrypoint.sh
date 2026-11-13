#!/bin/bash
# The container's entrypoint: as root, set up the egress firewall, hand the files the driver copied in to
# the session user, then run the command as that user with no capability left and no way to gain one.
set -euo pipefail
SESSION_PATH="$PATH"
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin   # root never looks in the session's PATH
/usr/local/sbin/init-firewall.sh >&2
chown -R node:node /work /home/node
chown -R root:root /opt/km-e2e /etc/claude-code
chmod -R a+rX,go-w /opt/km-e2e /etc/claude-code
exec /usr/bin/setpriv --reuid=node --regid=node --init-groups --inh-caps=-all --bounding-set=-all --no-new-privs -- \
  /usr/bin/env HOME=/home/node USER=node LOGNAME=node PATH="$SESSION_PATH" "$@"
