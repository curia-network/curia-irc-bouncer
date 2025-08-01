#!/bin/sh

# Initialize Soju admin user if it doesn't exist
# Called during container startup

echo "Checking for admin user initialization..."

# Wait for database to be available
echo "Waiting for database connection..."
until pg_isready -d "$DATABASE_URL" >/dev/null 2>&1; do
    echo "Database not ready, waiting..."
    sleep 2
done

echo "Database is ready"

# Check if admin user exists
if [ -n "$SOJU_ADMIN_USER" ] && [ -n "$SOJU_ADMIN_PASS" ]; then
    echo "Checking if admin user $SOJU_ADMIN_USER exists..."
    
    # Try to create admin user (will fail silently if user already exists)
    printf "%s\n" "$SOJU_ADMIN_PASS" | /usr/bin/sojuctl -config /etc/soju/soju.conf create-user "$SOJU_ADMIN_USER" -admin 2>/dev/null || {
        echo "Admin user may already exist or creation failed (this is normal)"
    }
    
    # Create default network for admin user
    if [ -n "$ERGO_HOST" ] && [ -n "$ERGO_PASS" ]; then
        echo "Creating default network for admin user..."
        /usr/bin/sojuctl -config /etc/soju/soju.conf user update "$SOJU_ADMIN_USER" create-network \
            -addr "$ERGO_HOST:6697" \
            -name "CommonGround" \
            -nick "$SOJU_ADMIN_USER" \
            -pass "$ERGO_PASS" \
            -tls 2>/dev/null || {
            echo "Network creation failed or already exists (this is normal)"
        }
    fi
fi

echo "Admin user initialization complete"