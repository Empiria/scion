package hub

import (
	"context"
	"net/http"
	"strings"

	"github.com/ptone/scion-agent/pkg/apiclient"
)

// DevUser represents the pseudo-user for development authentication.
type DevUser struct {
	id string
}

// ID returns the user ID.
func (u *DevUser) ID() string { return u.id }

// Email returns the user email.
func (u *DevUser) Email() string { return "dev@localhost" }

// DisplayName returns the user display name.
func (u *DevUser) DisplayName() string { return "Development User" }

// Role returns the user role.
func (u *DevUser) Role() string { return "admin" }

// userContextKey is the key for storing the user in the request context.
type userContextKey struct{}

// DevAuthMiddleware creates middleware that validates development tokens.
// If the token is valid, it adds a DevUser to the request context.
func DevAuthMiddleware(validToken string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			// Skip auth for health endpoints
			if r.URL.Path == "/healthz" || r.URL.Path == "/readyz" {
				next.ServeHTTP(w, r)
				return
			}

			// Extract token from Authorization header
			authHeader := r.Header.Get("Authorization")
			if authHeader == "" {
				writeError(w, http.StatusUnauthorized, ErrCodeUnauthorized,
					"missing authorization header", nil)
				return
			}

			parts := strings.SplitN(authHeader, " ", 2)
			if len(parts) != 2 || !strings.EqualFold(parts[0], "bearer") {
				writeError(w, http.StatusUnauthorized, ErrCodeUnauthorized,
					"invalid authorization header format", nil)
				return
			}

			token := parts[1]

			// Validate token (constant-time comparison)
			if !apiclient.ValidateDevToken(token, validToken) {
				writeError(w, http.StatusUnauthorized, ErrCodeUnauthorized,
					"invalid token", nil)
				return
			}

			// Add dev user context
			ctx := context.WithValue(r.Context(), userContextKey{}, &DevUser{id: "dev-user"})
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

// GetUserFromContext retrieves the user from the request context.
func GetUserFromContext(ctx context.Context) *DevUser {
	if user, ok := ctx.Value(userContextKey{}).(*DevUser); ok {
		return user
	}
	return nil
}
