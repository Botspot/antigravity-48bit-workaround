#!/bin/bash

# Create a fully isolated instance directory to prevent environment corruption
INSTANCE_ID=$$
INSTANCE_DIR="$HOME/.cache/antigravity-48bit-workaround/$INSTANCE_ID"
mkdir -p "$INSTANCE_DIR"

# Clean up stale directories older than 1 day so your cache doesn't fill up
find "$HOME/.cache/antigravity-48bit-workaround" -mindepth 1 -maxdepth 1 -type d -mmin +1440 -exec rm -rf {} + 2>/dev/null

KERNEL="/usr/share/antigravity/resources/antigravity-48bit-workaround/linux-kernel-image"
GUEST_INIT="/usr/share/antigravity/resources/antigravity-48bit-workaround/guest-wrapper.sh"
LOGFILE="$INSTANCE_DIR/host.log"

# Function to safely request guaranteed-open ephemeral ports from the OS
get_free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("", 0)); print(s.getsockname()[1]); s.close()'
}

export STDIO_PORT=$(get_free_port)
export PIPE_PORT=$(get_free_port)
export HTTP_PORT=$(get_free_port)
export HTTPS_PORT=$(get_free_port)
export LSP_PORT=$(get_free_port)
export API_PORT=$(get_free_port)
HOST_TIME=$(date +%s)

echo "Host Wrapper: Starting instance $INSTANCE_ID with flags: $*" >> "$LOGFILE"

# Forward all environment variables to this specific guest securely
export -p > "$INSTANCE_DIR/lsp_env.sh"

# Forward the Unix Pipe 
PIPE_PATH=$(echo "$@" | sed -n 's/.*--parent_pipe_path \([^ ]*\).*/\1/p')
if [ -n "$PIPE_PATH" ]; then
  socat TCP-LISTEN:$PIPE_PORT,bind=127.0.0.1,reuseaddr,fork UNIX-CONNECT:"$PIPE_PATH" 2>/dev/null &
  SOCAT_PIPE=$!
fi

# Dynamically map all ports so multiple QEMU guests don't collide on the host interface
HOSTFWD="hostfwd=tcp::${HTTP_PORT}-:${HTTP_PORT},hostfwd=tcp::${HTTPS_PORT}-:${HTTPS_PORT},hostfwd=tcp::${LSP_PORT}-:${LSP_PORT},hostfwd=tcp::${API_PORT}-:${API_PORT}"

## Boot QEMU 
qemu-system-aarch64 \
  -machine virt,gic-version=max -cpu host -enable-kvm -m 1024 -smp 4 \
  -no-reboot \
  -kernel "$KERNEL" \
  -fsdev local,security_model=none,id=fsdev0,path=/ \
  -device virtio-9p-pci,fsdev=fsdev0,mount_tag=hostroot \
  -netdev user,id=net0,$HOSTFWD \
  -device virtio-net-pci,netdev=net0 \
  -display none -serial null -monitor none \
  -append "quiet loglevel=0 rw ip=dhcp panic=-1 root=hostroot rootfstype=9p rootflags=trans=virtio,version=9p2000.L HOME=$HOME USER=$USER INSTANCE_DIR=$INSTANCE_DIR HOST_TIME=$HOST_TIME init=$GUEST_INIT -- $*" > "$LOGFILE" 2>&1 &
QEMU_PID=$!

# Define a ruthless cleanup function
cleanup() {
  kill -9 $QEMU_PID $SOCAT_PIPE $SOCAT_STDIO_PID $WATCHDOG_PID 2>/dev/null
  pkill -P $$ 2>/dev/null
}

# Trigger cleanup on normal script exit AND any interruption signals
trap cleanup EXIT INT TERM HUP

# --- THE WATCHDOG ---
# Monitors the IDE. If the IDE process dies, it nukes this script.
ORIG_PPID=$PPID
(
  while kill -0 $ORIG_PPID 2>/dev/null; do
    sleep 2
  done
  kill -TERM $$ 2>/dev/null
) &
WATCHDOG_PID=$!

# The Main LSP Stream
# We explicitly bind <&0 (STDIN) and >&1 (STDOUT) so Bash does not reroute
# the background process to /dev/null, which would trigger a false disconnect.
socat STDIO TCP-LISTEN:$STDIO_PORT,bind=127.0.0.1,reuseaddr <&0 >&1 &
SOCAT_STDIO_PID=$!

# Suspend execution safely.
wait $QEMU_PID
