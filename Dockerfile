# Dockerfile for Soju IRC Bouncer
FROM golang:1.21-alpine AS build

# Install build dependencies
RUN apk add --no-cache git build-base sqlite-dev

# Set Soju version (use latest stable)
ENV SOJU_VERSION=v0.8.0

# Download and build Soju
RUN git clone https://codeberg.org/emersion/soju.git /src && \
    cd /src && \
    git checkout $SOJU_VERSION && \
    go build -ldflags "-s -w" -o soju ./cmd/soju && \
    go build -ldflags "-s -w" -o sojuctl ./cmd/sojuctl && \
    go build -ldflags "-s -w" -o sojudb ./cmd/sojudb

# Production stage
FROM alpine:3.19

# Install runtime dependencies
RUN apk add --no-cache ca-certificates sqlite postgresql-client envsubst openssl

# Create soju user and directories
RUN addgroup -g 1000 soju && \
    adduser -D -s /bin/sh -u 1000 -G soju soju && \
    mkdir -p /etc/soju /var/lib/soju /etc/soju/certs && \
    chown -R soju:soju /etc/soju /var/lib/soju

# Copy binaries from build stage
COPY --from=build /src/soju /usr/bin/soju
COPY --from=build /src/sojuctl /usr/bin/sojuctl
COPY --from=build /src/sojudb /usr/bin/sojudb

# Copy configuration files
COPY soju.conf /etc/soju/soju.conf
COPY init-user.sh /usr/bin/init-user.sh
COPY entrypoint.sh /usr/bin/entrypoint.sh

# Make scripts executable
RUN chmod +x /usr/bin/init-user.sh /usr/bin/entrypoint.sh

# Expose ports
EXPOSE 6697 443

# Switch to soju user
USER soju

# Set working directory
WORKDIR /var/lib/soju

# Use custom entrypoint
ENTRYPOINT ["/usr/bin/entrypoint.sh"]
CMD ["/usr/bin/soju", "-config", "/etc/soju/soju.conf"]