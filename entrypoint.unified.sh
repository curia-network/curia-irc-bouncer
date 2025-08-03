#!/bin/sh

# Unified entrypoint script for Soju IRC bouncer + Admin Sidecar
# Handles initialization and starts both services via supervisord

echo "Starting Soju IRC Bouncer + Admin Sidecar..."

# Set default values (preserve from original entrypoint)
export SOJU_ADMIN_USER=${SOJU_ADMIN_USER:-"admin"}
export SOJU_ADMIN_PASS=${SOJU_ADMIN_PASS:-"adminpass123"}
export ERGO_HOST=${ERGO_HOST:-"ergo"}
export ERGO_PASS=${ERGO_PASS:-"devpass123"}
export SOJU_MULTI_UPSTREAM_MODE=${SOJU_MULTI_UPSTREAM_MODE:-"false"}

# Configure Unix socket admin interface (used by sidecar)
echo "Configuring Unix socket admin interface for sidecar access"
export SOJU_ADMIN_SOCKET_LISTEN="listen unix+admin:///var/lib/soju/admin.sock"
export SOJU_ADMIN_TCP_LISTEN=""
export SOJU_ADMIN_TCP_PASSWORD=""

# Sidecar configuration
export PORT=${PORT:-"3000"}
export NODE_ENV=${NODE_ENV:-"production"}
export SOJU_CONFIG_PATH="/etc/soju/soju.conf"

# Ensure directories exist
mkdir -p /etc/soju/certs /var/lib/soju/logs
chown -R soju:soju /var/lib/soju

# Generate self-signed certificates if they don't exist
if [ ! -f /etc/soju/certs/fullchain.pem ] || [ ! -f /etc/soju/certs/privkey.pem ]; then
    echo "Generating self-signed TLS certificates for Soju..."
    openssl req -x509 -newkey rsa:4096 -keyout /etc/soju/certs/privkey.pem -out /etc/soju/certs/fullchain.pem \
        -days 365 -nodes -subj "/C=US/ST=CA/L=SF/O=CommonGround/CN=irc.curia.network"
    chmod 600 /etc/soju/certs/privkey.pem
    chmod 644 /etc/soju/certs/fullchain.pem
    chown soju:soju /etc/soju/certs/*
fi

# Debug: Show admin environment variables
echo "DEBUG - Admin environment variables:"
echo "SOJU_ADMIN_SOCKET_LISTEN='$SOJU_ADMIN_SOCKET_LISTEN'"
echo "SIDECAR_PORT='$PORT'"

# Substitute environment variables in the config
envsubst < /etc/soju/soju.conf > /tmp/soju.conf && mv /tmp/soju.conf /etc/soju/soju.conf

# Debug: Show config after substitution
echo "DEBUG - Config after substitution:"
grep -A 5 -B 2 "Admin" /etc/soju/soju.conf

echo "Configuration prepared"

# Clean up any stale Unix socket from previous runs
if [ -S /var/lib/soju/admin.sock ]; then
    echo "Removing stale admin socket..."
    rm -f /var/lib/soju/admin.sock
fi

# Create a script to handle user initialization after Soju starts
cat > /tmp/init-after-start.sh << 'EOF'
#!/bin/sh
# Wait for Soju to start and create admin socket
echo "Waiting for Soju admin socket..."
timeout=30
while [ $timeout -gt 0 ] && [ ! -S /var/lib/soju/admin.sock ]; do
    sleep 1
    timeout=$((timeout - 1))
done

if [ -S /var/lib/soju/admin.sock ]; then
    echo "Admin socket found, initializing user..."
    # Wait a bit more for Soju to be ready
    sleep 2
    /usr/bin/init-user.sh
    echo "User initialization complete"
else
    echo "WARNING: Admin socket not found after 30 seconds"
fi
EOF

chmod +x /tmp/init-after-start.sh

# Create a script to handle graceful shutdown
cat > /usr/bin/quit-on-failure.sh << 'EOF'
#!/bin/sh
# If Soju fails, exit the container
printf "READY\n"
while read line; do
    echo "Received event: $line" >&2
    if echo "$line" | grep -q "PROCESS_STATE_FATAL" && echo "$line" | grep -q "soju"; then
        echo "Soju failed, exiting container" >&2
        supervisorctl shutdown
        exit 1
    fi
    printf "RESULT 2\nOK"
done < /dev/stdin
EOF

chmod +x /usr/bin/quit-on-failure.sh

# Start user initialization in background (after supervisord starts)
/tmp/init-after-start.sh &

echo "Starting supervisord to manage Soju and Sidecar processes..."
exec /usr/bin/supervisord -c /etc/supervisord.conf