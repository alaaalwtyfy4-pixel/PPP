#!/bin/bash
# Webhook Tunneling Setup Validation Script

set -e

echo "=========================================="
echo "Webhook Tunneling Configuration Validator"
echo "=========================================="
echo ""

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

check_passed() {
    echo -e "${GREEN}✓${NC} $1"
}

check_failed() {
    echo -e "${RED}✗${NC} $1"
}

check_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

# Check 1: Docker containers running
echo "1. Checking Docker containers..."
if [ $(docker ps --filter "name=agencyos" --quiet | wc -l) -ge 4 ]; then
    check_passed "All containers running"
else
    check_failed "Not all containers running. Run: docker compose up -d"
    exit 1
fi

# Check 2: Port bindings
echo ""
echo "2. Checking port bindings..."
NGINX_PORTS=$(docker inspect agencyos-nginx -f '{{json .NetworkSettings.Ports}}')
if echo "$NGINX_PORTS" | grep -q "0.0.0.0"; then
    check_passed "Nginx bound to 0.0.0.0 (accessible from host)"
else
    check_failed "Nginx not bound to 0.0.0.0"
fi

BACKEND_PORTS=$(docker inspect agencyos-backend -f '{{json .NetworkSettings.Ports}}')
if echo "$BACKEND_PORTS" | grep -q "0.0.0.0"; then
    check_passed "Backend bound to 0.0.0.0 (accessible from host)"
else
    check_failed "Backend not bound to 0.0.0.0"
fi

# Check 3: Extra hosts configuration
echo ""
echo "3. Checking extra_hosts configuration..."
if docker exec agencyos-backend cat /etc/hosts | grep -q "host.docker.internal"; then
    check_passed "host.docker.internal configured in backend"
else
    check_failed "host.docker.internal not configured in backend"
fi

if docker exec agencyos-nginx cat /etc/hosts | grep -q "host.docker.internal"; then
    check_passed "host.docker.internal configured in nginx"
else
    check_failed "host.docker.internal not configured in nginx"
fi

# Check 4: Backend health
echo ""
echo "4. Checking backend health..."
if docker exec agencyos-backend curl -s http://localhost:8000/health > /dev/null 2>&1; then
    check_passed "Backend responding to health check"
else
    check_failed "Backend not responding to health check"
fi

# Check 5: Nginx routing
echo ""
echo "5. Checking Nginx configuration..."
if docker exec agencyos-nginx grep -q "location /api/webhooks/" /etc/nginx/nginx.conf; then
    check_passed "Webhook route configured in Nginx"
else
    check_failed "Webhook route not configured in Nginx"
fi

if docker exec agencyos-nginx grep -q "server_name _;" /etc/nginx/nginx.conf; then
    check_passed "Nginx accepts any Host header (server_name _)"
else
    check_failed "Nginx host validation too strict"
fi

# Check 6: Nginx connectivity to backend
echo ""
echo "6. Checking Nginx → Backend connectivity..."
if docker exec agencyos-nginx curl -s http://agencyos-backend:8000/health > /dev/null 2>&1; then
    check_passed "Nginx can reach backend"
else
    check_failed "Nginx cannot reach backend"
fi

# Check 7: Uvicorn proxy headers
echo ""
echo "7. Checking Uvicorn configuration..."
if docker exec agencyos-backend ps aux | grep -q "proxy-headers"; then
    check_passed "Uvicorn configured with --proxy-headers"
else
    check_warning "Uvicorn proxy headers not explicitly set (may be OK if in startup command)"
fi

if docker exec agencyos-backend ps aux | grep -q "forwarded-allow-ips"; then
    check_passed "Uvicorn configured with --forwarded-allow-ips"
else
    check_warning "Uvicorn forwarded-allow-ips not explicitly set"
fi

# Check 8: Network inspection
echo ""
echo "8. Checking Docker network..."
NETWORK_NAME=$(docker network ls --filter "name=agencyos-net" --quiet)
if [ ! -z "$NETWORK_NAME" ]; then
    check_passed "agencyos-net network exists"
    
    BACKEND_NET=$(docker inspect agencyos-backend --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}')
    if echo "$BACKEND_NET" | grep -q "agencyos"; then
        check_passed "Backend connected to agencyos-net"
    fi
    
    NGINX_NET=$(docker inspect agencyos-nginx --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}')
    if echo "$NGINX_NET" | grep -q "agencyos"; then
        check_passed "Nginx connected to agencyos-net"
    fi
else
    check_failed "agencyos-net network not found"
fi

# Summary
echo ""
echo "=========================================="
echo "✓ Validation complete!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "1. Start ngrok:  ngrok http 80"
echo "2. Get tunnel URL from ngrok output"
echo "3. Configure webhook in service dashboard:"
echo "   URL: https://your-ngrok-domain.ngrok.io/api/webhooks/meta"
echo "   Verify Token: (set in .env)"
echo ""
echo "Test with:"
echo "  curl http://your-ngrok-domain.ngrok.io/health"
echo ""
