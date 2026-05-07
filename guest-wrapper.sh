#!/bin/bash

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
TARGET_BIN="/usr/share/antigravity/resources/antigravity-48bit-workaround/language_server_linux_arm"

# Isolate /tmp and fix DNS
mount -t tmpfs tmpfs /tmp
echo "nameserver 10.0.2.3" > /tmp/resolv.conf
mount --bind /tmp/resolv.conf /etc/resolv.conf

# Fix SLIRP MTU Blackholing natively
iptables -t mangle -A OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1160

# Extract our isolated sandbox path from the kernel arguments
for arg in $(cat /proc/cmdline); do
  case "$arg" in
    INSTANCE_DIR=*) INSTANCE_DIR="${arg#*=}" ;;
  esac
done

source "$INSTANCE_DIR/lsp_env.sh"
date -s "@$HOST_TIME" > /dev/null
HOST_IP="10.0.2.2"

echo "guest-wrapper: executing with flags: $*" >> "$INSTANCE_DIR/vm-stderr.log"

# Map the extension server out to the host IDE
EXTENSION_SERVER_PORT=$(echo "$@" | sed -n 's/.*--extension_server_port \([^ ]*\).*/\1/p')
if [ -n "$EXTENSION_SERVER_PORT" ]; then
  socat TCP-LISTEN:$EXTENSION_SERVER_PORT,bind=127.0.0.1,fork TCP:$HOST_IP:$EXTENSION_SERVER_PORT 2>/dev/null &
fi

# Bridge incoming QEMU traffic strictly from the SLIRP interface to the Go localhost bindings
GUEST_IP="10.0.2.15"
socat TCP-LISTEN:$HTTP_PORT,bind=$GUEST_IP,fork TCP:127.0.0.1:$HTTP_PORT 2>/dev/null &
socat TCP-LISTEN:$HTTPS_PORT,bind=$GUEST_IP,fork TCP:127.0.0.1:$HTTPS_PORT 2>/dev/null &
socat TCP-LISTEN:$LSP_PORT,bind=$GUEST_IP,fork TCP:127.0.0.1:$LSP_PORT 2>/dev/null &
socat TCP-LISTEN:$API_PORT,bind=$GUEST_IP,fork TCP:127.0.0.1:$API_PORT 2>/dev/null &

# Map the internal Unix pipe out to the host
PIPE_PATH=$(echo "$@" | sed -n 's/.*--parent_pipe_path \([^ ]*\).*/\1/p')
if [ -n "$PIPE_PATH" ] && [ -n "$PIPE_PORT" ]; then
  socat UNIX-LISTEN:"$PIPE_PATH",fork TCP:$HOST_IP:$PIPE_PORT 2>/dev/null &
fi

# Wait for host socket natively
echo -n "Waiting for host socket /dev/tcp/$HOST_IP/$STDIO_PORT..." >>"$INSTANCE_DIR/vm-stderr.log"
while ! exec 3<>/dev/tcp/$HOST_IP/$STDIO_PORT 2>/dev/null; do
  sleep 0.1
done
echo "done" >>"$INSTANCE_DIR/vm-stderr.log"

# Execute directly through the file descriptors, mapping all assigned ports correctly
"$TARGET_BIN" "$@" -http_server_port=$HTTP_PORT -https_server_port=$HTTPS_PORT -lsp_port=$LSP_PORT -api_server_url="http://127.0.0.1:$API_PORT" <&3 >&3 2>>"$INSTANCE_DIR/vm-stderr.log"
echo "exit code was $?" >>"$INSTANCE_DIR/vm-stderr.log"

exit 0
