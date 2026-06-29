# Quick Start: Local Webhook Tunneling with Docker Compose + ngrok

## What Changed?

Your Docker Compose stack is now configured for webhook tunneling:

1. **docker-compose.yml**: 
   - Backend + Nginx now bind to `0.0.0.0` (accessible from host + external)
   - All services have `extra_hosts: host.docker.internal:host-gateway`

2. **nginx.conf**:
   - Accepts any Host header (`server_name _;`)
   - Dedicated `/api/webhooks/` location with larger payload size (50MB)
   - Proper forwarding headers (`X-Forwarded-*`)

3. **app/main_webhook_example.py**:
   - Template FastAPI app with Meta webhook verification & handling
   - Trusted hosts middleware configured for ngrok + tunnel services
   - Request logging for debugging

## One-Command Setup

```bash
# 1. Rebuild with new config
docker compose up -d --build

# 2. In another terminal, start ngrok
ngrok http 80

# 3. You'll see:
# Forwarding    http://abc123.ngrok.io -> http://localhost:80
```

## Test the Setup

### From Windows Host:

```bash
# Test backend directly
curl -v http://localhost:8000/health

# Test via Nginx
curl -v http://localhost:80/health

# Test via ngrok tunnel
curl -v http://abc123.ngrok.io/health
```

### All should return:
```json
{"status":"healthy"}
```

## Configure Meta Webhooks

1. Go to https://developers.facebook.com/
2. App → Settings → Webhooks
3. Set:
   - **Callback URL**: `https://abc123.ngrok.io/api/webhooks/meta`
   - **Verify Token**: `your-secure-token-here`
4. Click "Verify and Save"

## Verify Webhook Signature (Production)

Add to `.env`:

```env
META_WEBHOOK_VERIFY_TOKEN=your-secure-token-here
META_WEBHOOK_SECRET=your-webhook-secret-from-app-settings
```

Then implement signature verification in your handler:

```python
import hmac
import hashlib
import json

def verify_meta_signature(request, webhook_secret: str) -> bool:
    """Verify Meta webhook signature."""
    x_hub_signature = request.headers.get("x-hub-signature-256", "")
    body_bytes = await request.body()
    
    expected_signature = hmac.new(
        webhook_secret.encode(),
        body_bytes,
        hashlib.sha256
    ).hexdigest()
    
    received_signature = x_hub_signature.replace("sha256=", "")
    return hmac.compare_digest(received_signature, expected_signature)
```

## Debug Checklist

### If webhook fails:

```bash
# 1. Check ngrok is running
curl http://localhost:4040/api/tunnels

# 2. Check Docker containers
docker ps

# 3. Check logs
docker logs agencyos-nginx
docker logs agencyos-backend

# 4. Test directly
curl -X GET http://localhost:8000/health
curl -X GET http://abc123.ngrok.io/health

# 5. Check host resolution
docker exec agencyos-backend ping host.docker.internal
```

### 502 Bad Gateway?

```bash
# Check if backend is running
docker exec agencyos-backend ps aux | grep uvicorn

# Check if it's listening on 8000
docker exec agencyos-backend netstat -tln | grep 8000

# Check Nginx error log
docker logs agencyos-nginx | grep error
```

### Connection Refused?

```bash
# Make sure ports are exposed (not just to localhost)
docker ps --format "table {{.Names}}\t{{.Ports}}"

# Should see:
# agencyos-backend    0.0.0.0:8000->8000/tcp
# agencyos-nginx      0.0.0.0:80->80/tcp, 0.0.0.0:443->443/tcp
```

## Next Steps

1. Replace `app/main.py` with `app/main_webhook_example.py` structure
2. Implement signature verification for Meta webhooks
3. Set up async webhook processing with Redis + Celery
4. Configure ngrok auth token for stable domains:
   ```bash
   ngrok config add-authtoken YOUR_TOKEN
   ngrok http --domain=your-domain.ngrok.io 80
   ```

## For Production

- Use a real domain + reverse proxy (not ngrok)
- Validate all webhook signatures (security-critical)
- Implement rate limiting on webhook endpoints
- Queue webhooks for async processing (don't block on processing)
- Use environment-specific configs (dev: permissive, prod: restrictive)
