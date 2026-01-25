# Development Authentication Design

## Status
**Proposed** (Interim Solution)

## 1. Overview

This document specifies a simple, interim authentication mechanism for development and local testing of the Scion Hub and Runtime Host APIs. This solution bridges the gap until full OAuth-based authentication (Google, GitHub, OIDC) is implemented.

### Goals

1. **Zero-config local development** - Start the server and immediately use the CLI
2. **Persistent tokens** - Tokens survive server restarts
3. **Environment variable override** - Easy integration with CI/testing
4. **Clear security boundary** - Obvious when running in dev mode
5. **Builds on existing auth** - Uses the `BearerAuth` mechanism already designed

### Non-Goals

- Production-ready security
- Multi-user support
- Token expiration/rotation
- Fine-grained permissions

---

## 2. Design

### 2.1 Token Generation and Storage

When the server starts with development authentication enabled:

1. Check if a token is explicitly configured (`server.auth.devToken`)
2. If not, check for an existing token file at `~/.scion/dev-token`
3. If no file exists, generate a new cryptographically secure token
4. Store the token in `~/.scion/dev-token` with `0600` permissions
5. Log the token to stdout for easy copy/paste

**Token Format:**
```
scion_dev_<32-character-hex-string>
```

Example: `scion_dev_a1b2c3d4e5f6789012345678901234567890abcd`

The `scion_dev_` prefix makes tokens easily identifiable and grep-able in logs.

### 2.2 Server Configuration

```yaml
server:
  auth:
    # Enable development authentication mode
    # WARNING: Not for production use
    devMode: false  # Default: disabled

    # Explicit token (optional)
    # If empty and devMode=true, auto-generate and persist
    devToken: ""

    # Path to token file (optional)
    # Default: ~/.scion/dev-token
    devTokenFile: ""
```

**Environment Variable Mapping:**

| Variable | Maps To |
|----------|---------|
| `SCION_SERVER_AUTH_DEV_MODE` | `server.auth.devMode` |
| `SCION_SERVER_AUTH_DEV_TOKEN` | `server.auth.devToken` |
| `SCION_SERVER_AUTH_DEV_TOKEN_FILE` | `server.auth.devTokenFile` |

### 2.3 Server Startup Behavior

```
┌─────────────────────────────────────────────────────────────────┐
│                     Server Startup                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  devMode enabled?                                                │
│       │                                                          │
│       ├── No ──▶ Use standard auth (OAuth, API keys, etc.)      │
│       │                                                          │
│       └── Yes                                                    │
│             │                                                    │
│             ▼                                                    │
│      devToken configured?                                        │
│             │                                                    │
│             ├── Yes ──▶ Use configured token                     │
│             │                                                    │
│             └── No                                               │
│                   │                                              │
│                   ▼                                              │
│            Token file exists?                                    │
│                   │                                              │
│                   ├── Yes ──▶ Load token from file               │
│                   │                                              │
│                   └── No ──▶ Generate new token                  │
│                                    │                             │
│                                    ▼                             │
│                              Save to file                        │
│                                    │                             │
│                                    ▼                             │
│                         Log token to stdout                      │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

**Startup Log Output:**

```
2025-01-24T10:30:00Z INFO  server starting port=9810 api=hub
2025-01-24T10:30:00Z WARN  development authentication enabled - not for production use
2025-01-24T10:30:00Z INFO  dev token: scion_dev_a1b2c3d4e5f6789012345678901234567890abcd
2025-01-24T10:30:00Z INFO  export SCION_DEV_TOKEN=scion_dev_a1b2c3d4e5f6789012345678901234567890abcd
```

### 2.4 Client Authentication

The client checks for development tokens in the following order:

1. **Explicit option** - `hubclient.WithBearerToken(token)` or `hubclient.WithDevToken(token)`
2. **Environment variable** - `SCION_DEV_TOKEN`
3. **Token file** - `~/.scion/dev-token`

**Client Configuration:**

```yaml
# In ~/.scion/settings.yaml or .scion/settings.yaml
hub:
  # Explicit token (overrides file/env)
  devToken: ""

  # Or use the token file
  devTokenFile: "~/.scion/dev-token"
```

**Environment Variables:**

| Variable | Purpose |
|----------|---------|
| `SCION_DEV_TOKEN` | Development token value |
| `SCION_DEV_TOKEN_FILE` | Path to token file (default: `~/.scion/dev-token`) |

### 2.5 Wire Protocol

Development tokens use the standard Bearer authentication scheme:

```http
GET /api/v1/agents HTTP/1.1
Host: localhost:9810
Authorization: Bearer scion_dev_a1b2c3d4e5f6789012345678901234567890abcd
```

This is identical to production Bearer token authentication, ensuring no code path differences between dev and production auth flows.

---

## 3. Implementation

### 3.1 Server-Side Token Management

```go
package auth

import (
    "crypto/rand"
    "encoding/hex"
    "fmt"
    "os"
    "path/filepath"
    "strings"
)

const (
    devTokenPrefix = "scion_dev_"
    devTokenLength = 32 // bytes, results in 64 hex chars
)

// DevAuthConfig holds development authentication settings.
type DevAuthConfig struct {
    Enabled   bool   `koanf:"devMode"`
    Token     string `koanf:"devToken"`
    TokenFile string `koanf:"devTokenFile"`
}

// InitDevAuth initializes development authentication.
// Returns the token to use and any error encountered.
func InitDevAuth(cfg DevAuthConfig, scionDir string) (string, error) {
    if !cfg.Enabled {
        return "", nil
    }

    // Priority 1: Explicit token in config
    if cfg.Token != "" {
        return cfg.Token, nil
    }

    // Determine token file path
    tokenFile := cfg.TokenFile
    if tokenFile == "" {
        tokenFile = filepath.Join(scionDir, "dev-token")
    }

    // Priority 2: Existing token file
    if data, err := os.ReadFile(tokenFile); err == nil {
        token := strings.TrimSpace(string(data))
        if token != "" {
            return token, nil
        }
    }

    // Priority 3: Generate new token
    token, err := generateDevToken()
    if err != nil {
        return "", fmt.Errorf("failed to generate dev token: %w", err)
    }

    // Persist token
    if err := os.WriteFile(tokenFile, []byte(token+"\n"), 0600); err != nil {
        return "", fmt.Errorf("failed to write dev token file: %w", err)
    }

    return token, nil
}

// generateDevToken creates a new cryptographically secure development token.
func generateDevToken() (string, error) {
    bytes := make([]byte, devTokenLength)
    if _, err := rand.Read(bytes); err != nil {
        return "", err
    }
    return devTokenPrefix + hex.EncodeToString(bytes), nil
}

// IsDevToken returns true if the token appears to be a development token.
func IsDevToken(token string) bool {
    return strings.HasPrefix(token, devTokenPrefix)
}
```

### 3.2 Server-Side Token Validation

```go
package auth

import (
    "context"
    "net/http"
    "strings"
)

// DevAuthMiddleware validates development tokens.
func DevAuthMiddleware(validToken string) func(http.Handler) http.Handler {
    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            // Extract token from Authorization header
            authHeader := r.Header.Get("Authorization")
            if authHeader == "" {
                http.Error(w, "missing authorization header", http.StatusUnauthorized)
                return
            }

            parts := strings.SplitN(authHeader, " ", 2)
            if len(parts) != 2 || !strings.EqualFold(parts[0], "bearer") {
                http.Error(w, "invalid authorization header format", http.StatusUnauthorized)
                return
            }

            token := parts[1]

            // Validate token (constant-time comparison)
            if !secureCompare(token, validToken) {
                http.Error(w, "invalid token", http.StatusUnauthorized)
                return
            }

            // Add dev user context
            ctx := context.WithValue(r.Context(), userContextKey, &DevUser{})
            next.ServeHTTP(w, r.WithContext(ctx))
        })
    }
}

// DevUser represents the pseudo-user for development authentication.
type DevUser struct{}

func (u *DevUser) ID() string          { return "dev-user" }
func (u *DevUser) Email() string       { return "dev@localhost" }
func (u *DevUser) DisplayName() string { return "Development User" }
func (u *DevUser) Role() string        { return "admin" }
```

### 3.3 Client-Side Token Resolution

```go
package hubclient

import (
    "os"
    "path/filepath"
    "strings"

    "github.com/ptone/scion-agent/pkg/apiclient"
)

// WithDevToken sets a development token for authentication.
func WithDevToken(token string) Option {
    return func(c *client) {
        c.auth = &apiclient.BearerAuth{Token: token}
    }
}

// WithAutoDevAuth attempts to load a development token automatically.
// Checks SCION_DEV_TOKEN env var, then ~/.scion/dev-token file.
func WithAutoDevAuth() Option {
    return func(c *client) {
        token := resolveDevToken()
        if token != "" {
            c.auth = &apiclient.BearerAuth{Token: token}
        }
    }
}

// resolveDevToken finds a development token from environment or file.
func resolveDevToken() string {
    // Priority 1: Environment variable
    if token := os.Getenv("SCION_DEV_TOKEN"); token != "" {
        return token
    }

    // Priority 2: Custom token file from env
    if tokenFile := os.Getenv("SCION_DEV_TOKEN_FILE"); tokenFile != "" {
        if data, err := os.ReadFile(tokenFile); err == nil {
            return strings.TrimSpace(string(data))
        }
    }

    // Priority 3: Default token file
    home, err := os.UserHomeDir()
    if err != nil {
        return ""
    }

    tokenFile := filepath.Join(home, ".scion", "dev-token")
    if data, err := os.ReadFile(tokenFile); err == nil {
        return strings.TrimSpace(string(data))
    }

    return ""
}
```

---

## 4. Usage Examples

### 4.1 Starting the Server

```bash
# Start Hub with dev auth (token auto-generated)
scion server start --enable-hub --dev-auth

# Or via config
cat > ~/.scion/server.yaml << EOF
server:
  hub:
    enabled: true
  auth:
    devMode: true
EOF

scion server start --config ~/.scion/server.yaml
```

**Output:**
```
Scion Hub API starting on :9810
WARNING: Development authentication enabled - not for production use
Dev token: scion_dev_a1b2c3d4e5f6789012345678901234567890abcd

To authenticate CLI commands, run:
  export SCION_DEV_TOKEN=scion_dev_a1b2c3d4e5f6789012345678901234567890abcd

Or the token has been saved to: ~/.scion/dev-token
```

### 4.2 Using the CLI

```bash
# Option 1: Set environment variable (explicit)
export SCION_DEV_TOKEN=scion_dev_a1b2c3d4e5f6789012345678901234567890abcd
scion agent list --hub http://localhost:9810

# Option 2: Automatic (reads from ~/.scion/dev-token)
scion agent list --hub http://localhost:9810

# Option 3: One-liner
SCION_DEV_TOKEN=$(cat ~/.scion/dev-token) scion agent list --hub http://localhost:9810
```

### 4.3 Using the Client Library

```go
package main

import (
    "context"
    "fmt"
    "log"

    "github.com/ptone/scion-agent/pkg/hubclient"
)

func main() {
    ctx := context.Background()

    // Option 1: Explicit token
    client, err := hubclient.New(
        "http://localhost:9810",
        hubclient.WithDevToken("scion_dev_a1b2c3d4e5f6789012345678901234567890abcd"),
    )

    // Option 2: Auto-resolve from env/file
    client, err := hubclient.New(
        "http://localhost:9810",
        hubclient.WithAutoDevAuth(),
    )

    if err != nil {
        log.Fatal(err)
    }

    // Use the client
    agents, err := client.Agents().List(ctx, nil)
    if err != nil {
        log.Fatal(err)
    }

    fmt.Printf("Found %d agents\n", len(agents.Agents))
}
```

### 4.4 CI/Testing

```yaml
# GitHub Actions example
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Start Scion Hub
        run: |
          scion server start --enable-hub --dev-auth --background
          echo "SCION_DEV_TOKEN=$(cat ~/.scion/dev-token)" >> $GITHUB_ENV

      - name: Run integration tests
        run: go test ./integration/...
        env:
          SCION_HUB_URL: http://localhost:9810
          # SCION_DEV_TOKEN already set above
```

---

## 5. Security Considerations

### 5.1 Development Mode Warnings

The server MUST:

1. Log a clear warning when dev auth is enabled
2. Refuse to start with dev auth if binding to non-localhost AND TLS is disabled
3. Include "dev-mode" in health check responses

```go
func validateDevAuthConfig(cfg *ServerConfig) error {
    if !cfg.Auth.DevMode {
        return nil
    }

    // Warn about dev mode
    log.Warn("Development authentication enabled - not for production use")

    // Block dangerous configurations
    if !cfg.TLS.Enabled && !isLocalhost(cfg.Host) {
        return fmt.Errorf("dev auth requires TLS when binding to non-localhost address")
    }

    return nil
}
```

### 5.2 Token File Permissions

- Token file MUST be created with `0600` permissions (owner read/write only)
- Client SHOULD warn if token file has overly permissive permissions

### 5.3 Token Entropy

- Tokens use 32 bytes (256 bits) of cryptographic randomness
- This provides sufficient entropy to prevent brute-force attacks even in dev scenarios

### 5.4 No Token in URLs

- Tokens MUST NOT be passed in URL query parameters
- This prevents token leakage in server logs, browser history, and referrer headers

---

## 6. Migration to Production Auth

When OAuth authentication is implemented:

1. Dev auth remains available but disabled by default
2. Production deployments set `devMode: false` explicitly
3. The `WithAutoDevAuth()` client option becomes a no-op when `SCION_DEV_TOKEN` is unset and no token file exists
4. Dev tokens are rejected by production servers (check for `scion_dev_` prefix)

---

## 7. Implementation Checklist

### Server

- [ ] Add `auth.devMode`, `auth.devToken`, `auth.devTokenFile` to config schema
- [ ] Implement `InitDevAuth()` function
- [ ] Add `--dev-auth` flag to `scion server start`
- [ ] Implement `DevAuthMiddleware`
- [ ] Add startup logging for dev token
- [ ] Add validation to block non-localhost + no-TLS + devMode

### Client Library

- [ ] Add `WithDevToken()` option to `hubclient`
- [ ] Add `WithAutoDevAuth()` option to `hubclient`
- [ ] Add `resolveDevToken()` helper
- [ ] Add same options to `hostclient`

### CLI

- [ ] Add `SCION_DEV_TOKEN` environment variable support
- [ ] Auto-detect dev token when `--hub` is localhost
- [ ] Add `--dev-token` flag for explicit token passing

### Documentation

- [ ] Update server-implementation-design.md with dev auth config
- [ ] Add dev auth section to client-design.md
- [ ] Create getting-started guide mentioning dev auth

---

## 8. References

- **Client Design:** `client-design.md`
- **Server Implementation:** `server-implementation-design.md`
- **Hub API Specification:** `hub-api.md`
