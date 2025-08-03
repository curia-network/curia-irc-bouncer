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
    /usr/bin/sojuctl -config /etc/soju/soju.conf user create -username "$SOJU_ADMIN_USER" -password "$SOJU_ADMIN_PASS" -nick "$SOJU_ADMIN_USER" -realname "Admin User" -admin 2>/dev/null || {
        echo "Admin user may already exist or creation failed (this is normal)"
    }
    
    # Create default network for admin user
    if [ -n "$ERGO_HOST" ]; then
        echo "Creating default network for admin user..."
        /usr/bin/sojuctl -config /etc/soju/soju.conf user run "$SOJU_ADMIN_USER" network create \
            -addr "irc+insecure://$ERGO_HOST:6667" \
            -name "commonground" \
            -username "$SOJU_ADMIN_USER" \
            -nick "$SOJU_ADMIN_USER" 2>/dev/null || {
            echo "Network creation failed or already exists (this is normal)"
        }
    fi
fi

echo "Admin user initialization complete"