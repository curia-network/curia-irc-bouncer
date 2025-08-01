# Curia IRC Bouncer (Soju)

Multi-user IRC bouncer with persistent message storage for the CommonGround chat system. Connects to the Ergo IRC server and provides persistent connections for multiple users and devices.

## Features

- **Multi-user support**: Each CommonGround user gets their own bouncer account
- **Message persistence**: All messages stored in PostgreSQL database
- **Multiple connections**: Users can connect from multiple devices simultaneously
- **WebSocket support**: Web clients can connect via WebSocket (wss://)
- **Authentication integration**: Integrates with CommonGround user system
- **TLS encryption**: Secure connections on port 6697 and 443

## Environment Variables

### Required
- `DATABASE_URL`: PostgreSQL connection string (provided by Railway addon)
- `SOJU_ADMIN_USER`: Admin username for bouncer management
- `SOJU_ADMIN_PASS`: Admin password for bouncer management
- `ERGO_HOST`: Hostname of Ergo IRC server (Railway service name)
- `ERGO_PASS`: Server password for connecting to Ergo

### Optional
- `SOJU_AUTH_URL`: HTTP endpoint for user authentication (production)
- `TLS_CERT`: TLS certificate in PEM format (will generate self-signed if not provided)
- `TLS_KEY`: TLS private key in PEM format (will generate self-signed if not provided)
- `SOJU_MULTI_UPSTREAM_MODE`: Enable multiple upstream networks (default: false)

## Ports

- `6697`: TLS IRC for IRC clients
- `443`: WebSocket over TLS for web clients

## Local Development

```bash
# Build the image
docker build -t curia-soju .

# Run with required environment variables
docker run -p 6697:6697 -p 443:443 \
  -e DATABASE_URL=postgres://soju:soju@db:5432/soju \
  -e SOJU_ADMIN_USER=admin \
  -e SOJU_ADMIN_PASS=adminpass123 \
  -e ERGO_HOST=ergo \
  -e ERGO_PASS=devpass123 \
  curia-soju
```

## Production Deployment (Railway)

1. Add PostgreSQL addon to your Railway project
2. Create a new Railway service from this repository
3. Set the required environment variables in Railway dashboard
4. The service will automatically use the DATABASE_URL from the PostgreSQL addon
5. Deploy using Railway's GitHub integration

## Authentication Modes

### Development (Internal Auth)
For local development, the bouncer uses internal authentication. Create users with:

```bash
# Connect to running container
docker exec -it <container> /bin/sh

# Create a user
echo "password123" | sojuctl -config /etc/soju/soju.conf create-user username

# Create admin user
echo "adminpass" | sojuctl -config /etc/soju/soju.conf create-user admin -admin
```

### Production (HTTP Auth)
In production, set `SOJU_AUTH_URL` to your CommonGround authentication endpoint. The bouncer will verify user credentials by making HTTP requests to this endpoint.

Example endpoint implementation needed in CommonGround:
```
POST /api/irc-auth
Authorization: Basic <base64(username:password)>

Response: 200 OK (valid) or 403 Forbidden (invalid)
```

## User Management

### Create Network for User
```bash
sojuctl -config /etc/soju/soju.conf user update <username> create-network \
  -addr ergo:6697 \
  -name "CommonGround" \
  -nick <username> \
  -pass <ergo-server-password> \
  -tls
```

### List Users
```bash
sojuctl -config /etc/soju/soju.conf user list
```

## Testing

### IRC Client Connection
```
Server: localhost (dev) or irc.curia.network (prod)
Port: 6697
TLS: Enabled
Username: <your-username>
Password: <your-password>
```

### WebSocket Connection
```
URL: wss://localhost:443 (dev) or wss://irc.curia.network (prod)
```

## Integration

This bouncer integrates with:
- **curia-ircd-ergo**: Upstream IRC server
- **curia-irc-client**: The Lounge web client
- **CommonGround**: User authentication and management
- **PostgreSQL**: Message and user storage

## Database Schema

Soju automatically creates the following tables:
- `users`: User accounts and settings
- `networks`: IRC network configurations per user
- `channels`: Channel memberships and settings
- `messages`: Message history and storage