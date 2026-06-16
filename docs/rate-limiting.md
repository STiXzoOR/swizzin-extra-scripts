# Rate Limiting Strategies for Streaming

This document outlines rate limiting strategies for nginx reverse proxies serving streaming media applications. Rate limiting is **not implemented by default** in swizzin-scripts but may be added when abuse or resource exhaustion becomes an issue.

## When to Implement Rate Limiting

Consider rate limiting when:
- Multiple users share the same server
- Public-facing streaming endpoints are exposed
- Bandwidth or connection limits need enforcement
- DDoS protection is required

## Strategy Comparison

| Strategy | Use Case | Pros | Cons |
|----------|----------|------|------|
| Per-IP | Public endpoints | Simple, prevents abuse | Blocks NAT/shared networks |
| Per-User | Authenticated apps | Fair distribution | Requires auth headers |
| Per-Connection | Multi-streaming | Limits concurrent streams | Doesn't limit request rate |
| Bandwidth | Prevent bandwidth hogs | Fine-grained control | Complex to tune |

## Implementation Examples

### 1. Per-IP Rate Limiting

Limits requests per IP address. Good for general abuse prevention.

```nginx
# In http block (nginx.conf)
limit_req_zone $binary_remote_addr zone=ip_limit:10m rate=10r/s;

# In server/location block
location / {
    limit_req zone=ip_limit burst=20 nodelay;
    proxy_pass http://backend;
}
```

**Parameters:**
- `rate=10r/s` - 10 requests per second baseline
- `burst=20` - Allow 20 requests burst before limiting
- `nodelay` - Process burst requests immediately (vs queuing)

### 2. Per-User Rate Limiting (with Organizr/Plex Token)

Limits based on authentication tokens for fair per-user distribution.

```nginx
# In http block
# Using Plex token
limit_req_zone $http_x_plex_token zone=plex_user:10m rate=5r/s;

# Using Organizr user
limit_req_zone $http_x_organizr_user zone=organizr_user:10m rate=5r/s;

# In location block
location / {
    limit_req zone=plex_user burst=10 nodelay;
    proxy_pass http://127.0.0.1:32400;
}
```

### 3. Connection Limiting

Limits concurrent connections per IP. Ideal for streaming where each stream is one connection.

```nginx
# In http block
limit_conn_zone $binary_remote_addr zone=addr:10m;

# In server/location block
location / {
    limit_conn addr 20;  # Max 20 concurrent connections per IP
    proxy_pass http://backend;
}
```

**Recommended for streaming:** Allows multi-device streaming while preventing resource exhaustion.

### 4. Bandwidth Throttling

Limits download speed after initial burst. Prevents single users from saturating bandwidth.

```nginx
location / {
    # Allow first 100MB at full speed, then throttle to 10MB/s
    limit_rate_after 100m;
    limit_rate 10m;

    proxy_pass http://backend;
}
```

## Streaming-Specific Configuration

For media servers, combine strategies:

```nginx
# In http block
limit_conn_zone $binary_remote_addr zone=stream_conn:10m;
limit_req_zone $binary_remote_addr zone=api_limit:10m rate=30r/s;

# Media streaming location
location ~ ^/(library|video|stream)/ {
    limit_conn stream_conn 10;  # Max 10 concurrent streams per IP
    proxy_pass http://backend;
}

# API endpoints (higher rate allowed)
location /api {
    limit_req zone=api_limit burst=50 nodelay;
    proxy_pass http://backend;
}
```

## Error Response Customization

Configure custom error pages for rate-limited requests:

```nginx
# Custom error response
limit_req_status 429;
limit_conn_status 429;

error_page 429 /rate_limit.html;

location = /rate_limit.html {
    internal;
    return 429 '{"error": "Too many requests. Please try again later."}';
    add_header Content-Type application/json;
}
```

## Logging Rate Limited Requests

Monitor rate limiting effectiveness:

```nginx
# Log format including limit status
log_format rate_limit '$remote_addr - $remote_user [$time_local] '
                      '"$request" $status $body_bytes_sent '
                      '"$http_referer" "$http_user_agent" '
                      'limit_req=$limit_req_status';

# Enable logging
access_log /var/log/nginx/rate_limit.log rate_limit;
```

## Testing Rate Limits

Use `ab` (Apache Bench) or `wrk` to test:

```bash
# Test 100 requests with 10 concurrent connections
ab -n 100 -c 10 https://your-server/endpoint

# Watch nginx error log for limit messages
tail -f /var/log/nginx/error.log | grep -i limit
```

## Considerations

1. **Streaming Burst Behavior**: Initial video loading requires many requests (thumbnails, metadata, chunks). Set generous burst values.

2. **WebSocket Connections**: WebSockets are long-lived single connections. Connection limits work well; request limits don't apply after upgrade.

3. **CDN/Proxy Clients**: If behind a CDN, use `$http_x_forwarded_for` instead of `$binary_remote_addr`.

4. **Whitelist Internal Networks**:
   ```nginx
   geo $limit_exempt {
       default 0;
       192.168.0.0/16 1;
       10.0.0.0/8 1;
       127.0.0.0/8 1;
   }

   map $limit_exempt $limit_key {
       0 $binary_remote_addr;
       1 "";  # Empty key = no limit
   }

   limit_req_zone $limit_key zone=external:10m rate=10r/s;
   ```

## Not Recommended for Streaming

- **Very low rate limits** (`rate=1r/s`) - Video players make many parallel requests
- **Small connection limits** (`limit_conn 2`) - Prevents normal multi-device usage
- **Strict bandwidth limits** - Causes buffering and poor user experience

## Further Reading

- [nginx Rate Limiting Documentation](https://nginx.org/en/docs/http/ngx_http_limit_req_module.html)
- [nginx Connection Limiting Documentation](https://nginx.org/en/docs/http/ngx_http_limit_conn_module.html)
