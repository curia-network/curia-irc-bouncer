#!/bin/sh

# Entrypoint script for Soju IRC bouncer
# Handles environment variable substitution and initialization

echo "Starting Soju IRC Bouncer..."

# Set default values
export SOJU_ADMIN_USER=${SOJU_ADMIN_USER:-"admin"}
export SOJU_ADMIN_PASS=${SOJU_ADMIN_PASS:-"adminpass123"}
export ERGO_HOST=${ERGO_HOST:-"ergo"}
export ERGO_PASS=${ERGO_PASS:-"devpass123"}
export SOJU_MULTI_UPSTREAM_MODE=${SOJU_MULTI_UPSTREAM_MODE:-"false"}

# Configure Unix socket admin interface (used by sidecar in both local and production)
echo "Configuring Unix socket admin interface for sidecar access"
export SOJU_ADMIN_SOCKET_LISTEN="listen unix+admin:///var/lib/soju/admin.sock"
export SOJU_ADMIN_TCP_LISTEN=""
export SOJU_ADMIN_TCP_PASSWORD=""

# Ensure directories exist
mkdir -p /etc/soju/certs /var/lib/soju/logs

# Generate self-signed certificates if they don't exist (for development)
if [ ! -f /etc/soju/certs/fullchain.pem ] || [ ! -f /etc/soju/certs/privkey.pem ]; then
    echo "Generating self-signed TLS certificates for Soju..."
    openssl req -x509 -newkey rsa:4096 -keyout /etc/soju/certs/privkey.pem -out /etc/soju/certs/fullchain.pem \
        -days 365 -nodes -subj "/C=US/ST=CA/L=SF/O=CommonGround/CN=irc.curia.network"
    chmod 600 /etc/soju/certs/privkey.pem
    chmod 644 /etc/soju/certs/fullchain.pem
fi

# Debug: Show admin environment variables before substitution
echo "DEBUG - Admin environment variables:"
echo "SOJU_ADMIN_SOCKET_LISTEN='$SOJU_ADMIN_SOCKET_LISTEN'"

# Substitute environment variables in the config
envsubst < /etc/soju/soju.conf > /tmp/soju.conf && mv /tmp/soju.conf /etc/soju/soju.conf

# Debug: Show config after substitution
echo "DEBUG - Config after substitution:"
grep -A 5 -B 2 "Admin" /etc/soju/soju.conf

echo "Configuration prepared"

# Initialize admin user in background after Soju starts
if [ "$1" = "/usr/bin/soju" ]; then
    echo "Starting Soju with user initialization..."
    
    # Start Soju in background
    "$@" &
    SOJU_PID=$!
    
    # Wait a moment for Soju to start
    sleep 5
    
    # Run user initialization
    /usr/bin/init-user.sh
    
    # Wait for Soju process
    wait $SOJU_PID
else
    # Execute the command directly if it's not Soju
    exec "$@"
fi