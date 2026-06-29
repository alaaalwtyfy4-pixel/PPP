# Exposing Docker Compose to External Webhooks via Tunneling

## Problem Overview

On Windows with Docker Desktop, tunnel services (ngrok, localtunnel) running on the host cannot directly reach the Docker bridge network (172.17.0.0/16 or custom bridge). This causes:
- **502 Bad Gateway** errors
- **Connection Refused** errors
- Host header rejection by Nginx

## Solution Architecture

```
Meta/Facebook Webhooks
         |
         ↓
   ngrok tunnel
         |
         ↓
Host Windows (127.0.0.1:4040 ngrok listener)
         |
         ↓ (routing issue: needs host.docker.internal)
Docker Bridge Network (agencyos-net)
         |
         ├─→ Nginx :80 (reverse proxy)
         │    |
         │    ├─→ Backend :8000
         │    └─→ Frontend :3000
         |
         └─→ PostgreSQL, Redis (internal only)
```

## Key Solutions

### 1. Host-to-Docker Networking on Windows

**Problem:** `localhost` or `127.0.0.1` inside containers doesn't route back to Windows host.

**Solution:** Use Docker Desktop's special DNS name `host.docker.internal`

```yaml
# In docker-compose.yml, add extra_hosts to services that need host access:
services:
  backend:
    extra_hosts:
      - "host.docker.internal:host-gateway"
```

This allows the backend to reach the ngrok listener at `http://host.docker.internal:4040`.

---

### 2. Nginx Configuration for Tunneled Requests

**Problem:** Nginx's `server_name _;` and security headers reject requests with mismatched Host headers.

**Solution:** Allow dynamic Host headers and disable Host validation

```nginx
# In nginx.conf http block:
server {
    listen 80;
    # Allow any host (including ngrok-generated domains)
    server_name _;
    
    # Remove Host header validation
    # Nginx will now accept requests from:
    # - ngrok domains (e.g., abc123.ngrok.io)
    # - localhost:4040
    # - custom tunnel domains
}
```

**For webhook routes specifically, allow additional headers:**

```nginx
location /api/webhooks/ {
    proxy_pass http://backend;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header Connection "";
    proxy_buffering off;
    
    # Allow larger payloads from webhook services
    client_max_body_size 50m;
}
```

---

### 3. FastAPI Backend Configuration

**Problem:** FastAPI's `--proxy-headers` may not trust the forwarded headers from ngrok.

**Solution:** Configure to trust all forwarded headers (OK in dev, lock down in production)

```python
# In app/main.py
from fastapi import FastAPI
from fastapi.middleware.trustedhost import TrustedHostMiddleware

app = FastAPI()

# Allow requests from any origin in dev (lock down in production)
app.add_middleware(
    TrustedHostMiddleware,
    allowed_hosts=[
        "localhost",
        "127.0.0.1",
        "*.ngrok.io",           # Allow ngrok domains
        "*.localtunnel.me",     # Allow localtunnel domains
        "host.docker.internal",
        "backend",
        "nginx",
    ],
)

# Uvicorn is already configured with --proxy-headers --forwarded-allow-ips "*"
```

**Also update your webhooks endpoint to log received headers:**

```python
from fastapi import Request

@app.post("/api/webhooks/meta")
async def handle_meta_webhook(request: Request):
    # Log what we receive
    print(f"Host: {request.headers.get('host')}")
    print(f"X-Forwarded-For: {request.headers.get('x-forwarded-for')}")
    print(f"X-Forwarded-Proto: {request.headers.get('x-forwarded-proto')}")
    print(f"Body: {await request.body()}")
    
    # Process webhook...
    return {"status": "ok"}
```

---

### 4. Docker Compose Networking Setup

**Current Issue:** Backend is only exposed locally

```yaml
# OLD (current)
backend:
  ports:
    - "8000:8000"  # ← only accessible via localhost from host
```

**Improved Setup:**

```yaml
# NEW (recommended for dev)
backend:
  ports:
    - "0.0.0.0:8000:8000"  # ← accessible from anywhere on the host's network
  extra_hosts:
    - "host.docker.internal:host-gateway"
  environment:
    # Tell FastAPI where it's being accessed from (for ngrok)
    BACKEND_URL: "${BACKEND_URL:-http://localhost:8000}"
```

**Alternative: Expose only Nginx to host (recommended for production-like setup)**

```yaml
nginx:
  ports:
    - "0.0.0.0:80:80"      # ← accessible externally
    - "0.0.0.0:443:443"
  extra_hosts:
    - "host.docker.internal:host-gateway"

backend:
  # NO direct port exposure
  extra_hosts:
    - "host.docker.internal:host-gateway"
```

---

## Step-by-Step Implementation

### Step 1: Update docker-compose.yml

Add `extra_hosts` to all services that may need to reach the host:

```yaml
services:
  backend:
    build:
      context: .
      dockerfile: Dockerfile.backend
    container_name: agencyos-backend
    restart: unless-stopped
    env_file:
      - .env
    environment:
      DATABASE_URL: postgresql+asyncpg://${POSTGRES_USER:-agencyos}:${POSTGRES_PASSWORD:-change-me-in-production}@postgres:5432/${POSTGRES_DB:-agency_os}
      REDIS_URL: redis://redis:6379/0
      BACKEND_URL: "${BACKEND_URL:-http://localhost:8000}"
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    volumes:
      - backend-logs:/app/logs
    ports:
      - "0.0.0.0:8000:8000"  # ← Change from 127.0.0.1
    extra_hosts:
      - "host.docker.internal:host-gateway"  # ← ADD THIS
    networks:
      - agencyos-net
    
  frontend:
    # ... existing config ...
    extra_hosts:
      - "host.docker.internal:host-gateway"  # ← ADD THIS
    networks:
      - agencyos-net

  nginx:
    image: nginx:1.27-alpine
    container_name: agencyos-nginx
    restart: unless-stopped
    ports:
      - "0.0.0.0:80:80"      # ← Change from just 80:80
      - "0.0.0.0:443:443"    # ← Change from just 443:443
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - ./certs:/etc/nginx/certs:ro
    depends_on:
      - backend
      - frontend
    extra_hosts:
      - "host.docker.internal:host-gateway"  # ← ADD THIS
    networks:
      - agencyos-net
```

### Step 2: Update Nginx Configuration

Add a dedicated webhook location block:

```nginx
# In nginx.conf, add to the http > server block:

location /api/webhooks/ {
    proxy_pass http://backend;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header Connection "";
    proxy_buffering off;
    
    # Allow larger webhook payloads
    client_max_body_size 50m;
    
    # Webhook services may have strict timeouts
    proxy_connect_timeout 5s;
    proxy_send_timeout 10s;
    proxy_read_timeout 30s;
}
```

### Step 3: Update FastAPI (app/main.py)

```python
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.trustedhost import TrustedHostMiddleware
import os

app = FastAPI(
    title="Agency OS Backend",
    docs_url="/docs",
    openapi_url="/openapi.json",
)

# Trust proxy headers from Nginx + ngrok
app.add_middleware(
    TrustedHostMiddleware,
    allowed_hosts=[
        "localhost",
        "127.0.0.1",
        "backend",
        "nginx",
        "host.docker.internal",
        "*.ngrok.io",
        "*.localtunnel.me",
        "*.loca.lt",  # localtunnel alternative
    ],
)

# CORS for webhook services
app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "http://localhost:3000",
        "http://localhost:8000",
        "http://127.0.0.1",
        "http://host.docker.internal",
    ],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Webhook endpoint with detailed logging
@app.post("/api/webhooks/meta")
async def handle_meta_webhook(request: Request):
    """
    Receives Meta/Facebook webhook events.
    Logs all headers to diagnose tunnel issues.
    """
    headers = {
        "host": request.headers.get("host"),
        "x-forwarded-for": request.headers.get("x-forwarded-for"),
        "x-forwarded-proto": request.headers.get("x-forwarded-proto"),
        "x-real-ip": request.headers.get("x-real-ip"),
        "user-agent": request.headers.get("user-agent"),
    }
    
    body = await request.json()
    
    print(f"Received Meta webhook from {headers}")
    print(f"Body: {body}")
    
    # Process webhook...
    # TODO: validate signature, save to DB, trigger jobs
    
    return {"status": "received", "message_id": body.get("entry", [{}])[0].get("id")}

@app.get("/health")
async def health_check():
    return {"status": "healthy"}
```

### Step 4: Set Environment Variables

Create or update `.env`:

```env
# Backend configuration
BACKEND_URL=http://localhost:8000

# For ngrok tunneled webhooks
NGROK_TUNNEL_URL=${NGROK_TUNNEL_URL:-http://localhost:8000}

# Database
POSTGRES_USER=agencyos
POSTGRES_PASSWORD=your-secure-password-here
POSTGRES_DB=agency_os

# Redis
REDIS_URL=redis://redis:6379/0
```

### Step 5: Start ngrok and Connect

```bash
# Terminal 1: Start Docker Compose
docker compose up -d

# Terminal 2: Start ngrok tunnel
ngrok http 80  # OR 8000 if exposing backend directly

# You'll see output like:
# Web Interface                 http://127.0.0.1:4040
# Forwarding                    http://abc123.ngrok.io -> http://localhost:80
# Forwarding                    https://abc123.ngrok.io -> http://localhost:80
```

### Step 6: Test the Tunnel

```bash
# From your Windows host:
curl -X GET http://abc123.ngrok.io/health

# Should return:
# {"status":"healthy"}

# Test webhook endpoint:
curl -X POST http://abc123.ngrok.io/api/webhooks/meta \
  -H "Content-Type: application/json" \
  -d '{"test": "data"}'

# Should return:
# {"status":"received"}
```

### Step 7: Configure Meta Webhooks

In Meta's App Dashboard → Settings → Webhooks:

```
Callback URL: https://abc123.ngrok.io/api/webhooks/meta
Verify Token: your-secure-token-here
```

---

## Debugging Checklist

### 502 Bad Gateway

1. **Check Nginx logs:**
   ```bash
   docker logs agencyos-nginx | tail -50
   ```

2. **Verify backend is running:**
   ```bash
   docker ps | grep backend
   docker logs agencyos-backend | tail -50
   ```

3. **Test backend directly from host:**
   ```bash
   curl -v http://localhost:8000/health
   ```

4. **Check Docker network:**
   ```bash
   docker network inspect agencyos-net
   ```

### Host Header Rejection

1. **Check what Host header the tunnel is sending:**
   ```bash
   curl -v http://abc123.ngrok.io/health
   # Look for > Host: header in verbose output
   ```

2. **Verify Nginx is accepting it:**
   ```bash
   docker exec agencyos-nginx cat /etc/nginx/nginx.conf | grep server_name
   # Should see: server_name _;
   ```

3. **Check Nginx access logs:**
   ```bash
   docker exec agencyos-nginx tail -f /var/log/nginx/access.log
   ```

### Backend Not Receiving Forwarded Headers

1. **Check FastAPI logs for request origin:**
   ```bash
   docker logs agencyos-backend | grep "X-Forwarded"
   ```

2. **Verify Uvicorn is configured for proxy headers:**
   ```bash
   docker exec agencyos-backend ps aux | grep uvicorn
   # Should see: --proxy-headers --forwarded-allow-ips "*"
   ```

---

## Production Recommendations

⚠️ **For production, do NOT use `0.0.0.0` port bindings or overly permissive CORS.**

1. **Use a reverse proxy on the host** (e.g., HAProxy, Traefik) instead of ngrok
2. **Lock down CORS** to specific webhook service IPs
3. **Validate webhook signatures** (e.g., Meta's X-Hub-Signature header)
4. **Use environment-specific configs** (dev: permissive, prod: restrictive)
5. **Enable HTTPS with valid certificates** (not self-signed)
6. **Rate-limit webhook endpoints** to prevent abuse
7. **Use a message queue** (Redis, RabbitMQ) for async webhook processing

---

## Summary

| Issue | Solution |
|-------|----------|
| Host unreachable from Docker | Use `host.docker.internal` in `extra_hosts` |
| Host header rejection | Use `server_name _;` in Nginx |
| Port binding restricted to localhost | Change `127.0.0.1:PORT` to `0.0.0.0:PORT` |
| Forwarded headers not trusted | Add `TrustedHostMiddleware` + `--forwarded-allow-ips "*"` |
| Large webhook payloads | Increase `client_max_body_size` in Nginx |
| Connection timeouts | Add specific proxy timeout settings per route |

---

## References

- [Docker Desktop Networking](https://docs.docker.com/desktop/networking/)
- [ngrok Documentation](https://ngrok.com/docs)
- [Nginx Proxy Headers](https://nginx.org/en/docs/http/ngx_http_proxy_module.html)
- [FastAPI Middleware](https://fastapi.tiangolo.com/tutorial/middleware/)
- [Meta Webhook Setup](https://developers.facebook.com/docs/messenger-platform/webhooks)
