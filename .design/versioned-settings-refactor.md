# Versioned Settings Refactor: Design & Transition Plan

## Status: Draft
## Date: 2026-02-15
## Supersedes: `.design/_archive/settings-refactor.md`

---

## 1. Motivation

The current settings system evolved organically and has several structural problems:

1. **Ambiguous grouping.** Settings like `active_profile`, `default_template`, `grove_id`, and `bucket` sit at the top level without a clear domain owner. Some are CLI concerns, some are profile concerns, some are hub concerns.

2. **No schema or versioning.** There is no machine-readable schema for settings. Typos, missing fields, and structural errors are only discovered at runtime (or never). There is no way to determine which features a given settings file supports.

3. **Two disjoint config systems.** The CLI/agent settings (`settings.yaml`) and the server config (`server.yaml`, `GlobalConfig`) use separate loading paths, separate structs, and separate env-var conventions, even though they share concepts like `brokerID`.

4. **Missing feature support.** Upcoming features (interactive mode, max agent duration, max turns, named harness configs) need settings support that doesn't exist in the current flat model.

5. **No deprecation path.** Changing the settings structure would silently break existing users. There is no mechanism to detect legacy vs modern settings, warn about deprecated fields, or guide migration.

---

## 2. Target Settings Groups

The new settings structure recognizes these primary domain groups:

### 2.1 `server` (global-only)

Server/broker process configuration. Only valid at the global level (`~/.scion/settings.yaml`), never in grove-level settings.

```yaml
server:
  broker_id: "uuid-string"
  env: prod                        # deployment environment label
  hub:                             # hub server settings (when running scion-server)
    port: 9810
    host: "0.0.0.0"
    endpoint: "https://hub.example.com"
    read_timeout: 30s
    write_timeout: 60s
    cors:
      enabled: true
      allowed_origins: ["*"]
      allowed_methods: ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]
      allowed_headers: ["Authorization", "Content-Type"]
      max_age: 3600
    admin_emails: []
  runtime_broker:
    enabled: false
    port: 9800
    host: "0.0.0.0"
    hub_endpoint: ""
    broker_name: ""
  database:
    driver: sqlite
    url: ""
  auth:
    dev_mode: false
    dev_token: ""
    dev_token_file: ""
    authorized_domains: []
  oauth:
    web:
      google: { client_id: "", client_secret: "" }
      github: { client_id: "", client_secret: "" }
    cli:
      google: { client_id: "", client_secret: "" }
      github: { client_id: "", client_secret: "" }
    device:
      google: { client_id: "", client_secret: "" }
      github: { client_id: "", client_secret: "" }
  storage:
    provider: local
    bucket: ""
    local_path: ""
  secrets:
    backend: local
    gcp_project_id: ""
    gcp_credentials: ""
  log_level: info
  log_format: text
```

**Rationale:** This consolidates the current `GlobalConfig`/`server.yaml` system into the unified settings file. The separate `server.yaml` continues to work during the transition but the canonical location becomes `settings.yaml` under the `server` key.

### 2.2 `hub` (hub client)

Settings for connecting to a remote Scion Hub as a client. Valid at global or grove level (grove overrides global).

```yaml
hub:
  enabled: true
  endpoint: "https://hub.example.com"
  token: ""
  api_key: ""
  grove_id: ""
  broker_id: ""
  broker_nickname: ""
  broker_token: ""
  local_only: false
```

### 2.3 `cli`

Controls CLI behavior. Valid at global or grove level.

```yaml
cli:
  autohelp: true
  interactive_disabled: false      # new: disable interactive prompts
```

### 2.4 `runtimes` (named map)

Container runtime definitions. Valid at global or grove level.

```yaml
runtimes:
  docker:
    type: docker
    host: ""
    env: {}
    sync: ""
  container:
    type: container
    tmux: true
  kubernetes:
    type: kubernetes
    context: ""
    namespace: ""
```

**Change from current:** An explicit `type` field is added to each runtime. This was implicit before (the runtime name *was* the type). With the `type` field, users can define `my-docker-staging: { type: docker, host: "..." }` without conflating name and type. The legacy names-as-types behavior is preserved for backward compatibility (if `type` is absent, the name is used).

### 2.5 `harness_configs` (named map)

Named harness configurations. This replaces the current `harnesses` map. Multiple configs can exist for the same harness type.

```yaml
harness_configs:
  gemini:                          # default config for gemini harness
    harness: gemini
    image: "us-central1-docker.pkg.dev/.../scion-gemini:latest"
    user: scion
    model: ""
    args: []
    env: {}
    volumes: []
  claude:                          # default config for claude harness
    harness: claude
    image: "us-central1-docker.pkg.dev/.../scion-claude:latest"
    user: scion
    model: ""
    args: []
    env: {}
    volumes: []
  gemini-high-security:            # named variant
    harness: gemini
    image: "us-central1-docker.pkg.dev/.../scion-gemini:hardened"
    user: scion
    model: "gemini-2.5-pro"
    args: ["--sandbox=strict"]
    env:
      GEMINI_SAFETY: "maximum"
```

**Change from current:** The `harnesses` map only allowed one entry per harness type (keyed by harness name). The new `harness_configs` map is keyed by an arbitrary config name, with an explicit `harness` field specifying the harness type. There is a convention that each harness has a "default" config whose name matches the harness (e.g., config named `gemini` with `harness: gemini`).

### 2.6 `profiles` (named map)

Named environment profiles. Valid at global or grove level.

```yaml
profiles:
  local:
    runtime: container
    default_template: gemini
    default_harness_config: gemini  # which harness_config to use by default
    tmux: true
    env: {}
    volumes: []
    resources: null
    harness_overrides:              # per-harness-config overrides
      gemini:
        image: "custom:dev"
  remote:
    runtime: kubernetes
    default_template: gemini
    default_harness_config: gemini
    tmux: false
```

**Change from current:** `default_template` and `default_harness_config` are added to profiles. The top-level `default_template` and `active_profile` remain for backward compatibility but profiles can now be self-describing.

### 2.7 `agent` (template configuration)

Agent/template-level settings. These live in `scion-agent.yaml` within template directories, not in `settings.yaml`.

```yaml
# In .scion/templates/<name>/scion-agent.yaml
harness: gemini
env: {}
volumes: []
resources:
  requests:
    cpu: "500m"
    memory: "512Mi"
  limits:
    cpu: "2"
    memory: "2Gi"
  disk: "10Gi"
max_turns: 50                      # new
max_duration: "2h"                 # new
services:                          # sidecar services
  - name: browser
    command: ["chromium", "--headless"]
    restart: on-failure
    ready_check:
      type: tcp
      target: "localhost:9222"
      timeout: "10s"
```

### 2.8 Top-level metadata

```yaml
$schema: "https://scion.dev/schemas/settings/v1.json"
schema_version: "1"

active_profile: local
```

---

## 3. JSON Schema

### 3.1 Schema Location and Naming

Schemas are stored in the repository at `pkg/config/schemas/` and embedded into the binary.

```
pkg/config/schemas/
  settings-v1.schema.json          # settings.yaml schema
  agent-v1.schema.json             # scion-agent.yaml schema
```

### 3.2 Schema Standard

JSON Schema Draft 2020-12 (`https://json-schema.org/draft/2020-12/schema`).

### 3.3 Custom Annotations

Each schema property that can be set via environment variable includes:

```json
{
  "x-env-var": "SCION_HUB_ENDPOINT",
  "x-env-var-prefix": "SCION_"
}
```

Each schema property includes scope metadata:

```json
{
  "x-scope": "global",          // "global" = global-only, "any" = global or grove
  "x-since": "1",               // schema version that introduced this field
  "x-deprecated-by": "2"        // schema version that deprecated this field (if applicable)
}
```

### 3.4 Versioning Strategy

- The schema version is a simple monotonic integer (`"1"`, `"2"`, `"3"`, ...).
- The `schema_version` field in settings.yaml declares which schema version the file conforms to.
- The binary embeds all supported schema versions and validates against the declared version.
- Feature gates can check `schema_version >= N` to determine if a feature's settings are available.

### 3.5 Schema Sketch (v1)

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://scion.dev/schemas/settings/v1.json",
  "title": "Scion Settings",
  "description": "Configuration for the Scion agent orchestration platform (v1).",
  "type": "object",
  "properties": {
    "$schema": {
      "type": "string",
      "description": "JSON Schema URI for IDE support."
    },
    "schema_version": {
      "type": "string",
      "const": "1",
      "description": "Settings schema version. Required for versioned settings.",
      "x-since": "1"
    },
    "active_profile": {
      "type": "string",
      "default": "local",
      "description": "Name of the active profile.",
      "x-env-var": "SCION_ACTIVE_PROFILE",
      "x-scope": "any",
      "x-since": "1"
    },
    "server": {
      "type": "object",
      "description": "Server/broker process configuration. Global-only.",
      "x-scope": "global",
      "x-since": "1",
      "properties": {
        "broker_id": {
          "type": "string",
          "description": "Unique broker identifier (UUID).",
          "x-env-var": "SCION_SERVER_BROKER_ID",
          "x-since": "1"
        },
        "env": {
          "type": "string",
          "description": "Deployment environment label (e.g., dev, staging, prod).",
          "x-env-var": "SCION_SERVER_ENV",
          "x-since": "1"
        },
        "hub": { "$ref": "#/$defs/serverHub" },
        "runtime_broker": { "$ref": "#/$defs/serverRuntimeBroker" },
        "database": { "$ref": "#/$defs/serverDatabase" },
        "auth": { "$ref": "#/$defs/serverAuth" },
        "oauth": { "$ref": "#/$defs/serverOAuth" },
        "storage": { "$ref": "#/$defs/serverStorage" },
        "secrets": { "$ref": "#/$defs/serverSecrets" },
        "log_level": {
          "type": "string",
          "enum": ["debug", "info", "warn", "error"],
          "default": "info",
          "x-env-var": "SCION_SERVER_LOG_LEVEL",
          "x-since": "1"
        },
        "log_format": {
          "type": "string",
          "enum": ["text", "json"],
          "default": "text",
          "x-env-var": "SCION_SERVER_LOG_FORMAT",
          "x-since": "1"
        }
      },
      "additionalProperties": false
    },
    "hub": {
      "type": "object",
      "description": "Hub client connection settings.",
      "x-scope": "any",
      "x-since": "1",
      "properties": {
        "enabled": {
          "type": "boolean",
          "description": "Enable Hub integration.",
          "x-env-var": "SCION_HUB_ENABLED",
          "x-since": "1"
        },
        "endpoint": {
          "type": "string",
          "format": "uri",
          "description": "Hub API endpoint URL.",
          "x-env-var": "SCION_HUB_ENDPOINT",
          "x-since": "1"
        },
        "token": {
          "type": "string",
          "description": "Bearer token for Hub authentication.",
          "x-env-var": "SCION_HUB_TOKEN",
          "x-sensitive": true,
          "x-since": "1"
        },
        "api_key": {
          "type": "string",
          "description": "API key for Hub authentication.",
          "x-env-var": "SCION_HUB_API_KEY",
          "x-sensitive": true,
          "x-since": "1"
        },
        "grove_id": {
          "type": "string",
          "description": "Grove identifier when registered with the Hub.",
          "x-env-var": "SCION_HUB_GROVE_ID",
          "x-since": "1"
        },
        "broker_id": {
          "type": "string",
          "description": "Broker identifier when registered with the Hub.",
          "x-env-var": "SCION_HUB_BROKER_ID",
          "x-since": "1"
        },
        "broker_nickname": {
          "type": "string",
          "description": "Human-readable broker name.",
          "x-env-var": "SCION_HUB_BROKER_NICKNAME",
          "x-since": "1"
        },
        "broker_token": {
          "type": "string",
          "description": "Token received when registering broker with Hub.",
          "x-env-var": "SCION_HUB_BROKER_TOKEN",
          "x-sensitive": true,
          "x-since": "1"
        },
        "local_only": {
          "type": "boolean",
          "description": "Operate in local-only mode even when Hub is configured.",
          "x-env-var": "SCION_HUB_LOCAL_ONLY",
          "x-since": "1"
        }
      },
      "additionalProperties": false
    },
    "cli": {
      "type": "object",
      "description": "CLI behavior settings.",
      "x-scope": "any",
      "x-since": "1",
      "properties": {
        "autohelp": {
          "type": "boolean",
          "default": true,
          "description": "Print usage help on errors.",
          "x-env-var": "SCION_CLI_AUTOHELP",
          "x-since": "1"
        },
        "interactive_disabled": {
          "type": "boolean",
          "default": false,
          "description": "Disable interactive prompts (useful for CI/scripts).",
          "x-env-var": "SCION_CLI_INTERACTIVE_DISABLED",
          "x-since": "1"
        }
      },
      "additionalProperties": false
    },
    "runtimes": {
      "type": "object",
      "description": "Named container runtime definitions.",
      "x-scope": "any",
      "x-since": "1",
      "additionalProperties": {
        "$ref": "#/$defs/runtimeConfig"
      }
    },
    "harness_configs": {
      "type": "object",
      "description": "Named harness configurations. Multiple configs may share a harness type.",
      "x-scope": "any",
      "x-since": "1",
      "additionalProperties": {
        "$ref": "#/$defs/harnessConfig"
      }
    },
    "profiles": {
      "type": "object",
      "description": "Named environment profiles.",
      "x-scope": "any",
      "x-since": "1",
      "additionalProperties": {
        "$ref": "#/$defs/profileConfig"
      }
    }
  },
  "additionalProperties": false,
  "$defs": {
    "runtimeConfig": {
      "type": "object",
      "properties": {
        "type": {
          "type": "string",
          "enum": ["docker", "container", "kubernetes"],
          "description": "Runtime type. Defaults to the runtime entry name if omitted."
        },
        "host": { "type": "string" },
        "context": { "type": "string" },
        "namespace": { "type": "string" },
        "tmux": { "type": "boolean" },
        "env": {
          "type": "object",
          "additionalProperties": { "type": "string" }
        },
        "sync": { "type": "string" }
      },
      "additionalProperties": false
    },
    "harnessConfig": {
      "type": "object",
      "required": ["harness"],
      "properties": {
        "harness": {
          "type": "string",
          "enum": ["gemini", "claude", "opencode", "codex", "generic"],
          "description": "The harness type this config applies to."
        },
        "image": {
          "type": "string",
          "description": "Container image URI."
        },
        "user": {
          "type": "string",
          "description": "Unix user inside the container."
        },
        "model": {
          "type": "string",
          "description": "LLM model identifier."
        },
        "args": {
          "type": "array",
          "items": { "type": "string" },
          "description": "Additional harness CLI arguments."
        },
        "env": {
          "type": "object",
          "additionalProperties": { "type": "string" }
        },
        "volumes": {
          "type": "array",
          "items": { "$ref": "#/$defs/volumeMount" }
        },
        "auth_selected_type": {
          "type": "string",
          "description": "Authentication mechanism to use."
        }
      },
      "additionalProperties": false
    },
    "profileConfig": {
      "type": "object",
      "required": ["runtime"],
      "properties": {
        "runtime": {
          "type": "string",
          "description": "Name of the runtime (key in runtimes map) to use."
        },
        "default_template": {
          "type": "string",
          "description": "Default template for agents created under this profile."
        },
        "default_harness_config": {
          "type": "string",
          "description": "Default harness config name for agents under this profile."
        },
        "tmux": { "type": "boolean" },
        "env": {
          "type": "object",
          "additionalProperties": { "type": "string" }
        },
        "volumes": {
          "type": "array",
          "items": { "$ref": "#/$defs/volumeMount" }
        },
        "resources": { "$ref": "#/$defs/resourceSpec" },
        "harness_overrides": {
          "type": "object",
          "description": "Per-harness-config overrides applied when using this profile.",
          "additionalProperties": { "$ref": "#/$defs/harnessOverride" }
        }
      },
      "additionalProperties": false
    },
    "harnessOverride": {
      "type": "object",
      "properties": {
        "image": { "type": "string" },
        "user": { "type": "string" },
        "env": {
          "type": "object",
          "additionalProperties": { "type": "string" }
        },
        "volumes": {
          "type": "array",
          "items": { "$ref": "#/$defs/volumeMount" }
        },
        "resources": { "$ref": "#/$defs/resourceSpec" },
        "auth_selected_type": { "type": "string" }
      },
      "additionalProperties": false
    },
    "volumeMount": {
      "type": "object",
      "required": ["target"],
      "properties": {
        "source": { "type": "string" },
        "target": { "type": "string" },
        "read_only": { "type": "boolean", "default": false },
        "type": { "type": "string", "enum": ["local", "gcs"], "default": "local" },
        "bucket": { "type": "string" },
        "prefix": { "type": "string" },
        "mode": { "type": "string" }
      }
    },
    "resourceSpec": {
      "type": "object",
      "properties": {
        "requests": {
          "type": "object",
          "properties": {
            "cpu": { "type": "string" },
            "memory": { "type": "string" }
          }
        },
        "limits": {
          "type": "object",
          "properties": {
            "cpu": { "type": "string" },
            "memory": { "type": "string" }
          }
        },
        "disk": { "type": "string" }
      }
    },
    "serverHub": {
      "type": "object",
      "properties": {
        "port": { "type": "integer", "default": 9810 },
        "host": { "type": "string", "default": "0.0.0.0" },
        "endpoint": { "type": "string", "format": "uri" },
        "read_timeout": { "type": "string", "default": "30s" },
        "write_timeout": { "type": "string", "default": "60s" },
        "cors": { "$ref": "#/$defs/corsConfig" },
        "admin_emails": {
          "type": "array",
          "items": { "type": "string", "format": "email" }
        }
      }
    },
    "serverRuntimeBroker": {
      "type": "object",
      "properties": {
        "enabled": { "type": "boolean", "default": false },
        "port": { "type": "integer", "default": 9800 },
        "host": { "type": "string", "default": "0.0.0.0" },
        "hub_endpoint": { "type": "string", "format": "uri" },
        "broker_name": { "type": "string" },
        "read_timeout": { "type": "string", "default": "30s" },
        "write_timeout": { "type": "string", "default": "120s" },
        "cors": { "$ref": "#/$defs/corsConfig" }
      }
    },
    "corsConfig": {
      "type": "object",
      "properties": {
        "enabled": { "type": "boolean", "default": true },
        "allowed_origins": {
          "type": "array",
          "items": { "type": "string" },
          "default": ["*"]
        },
        "allowed_methods": {
          "type": "array",
          "items": { "type": "string" }
        },
        "allowed_headers": {
          "type": "array",
          "items": { "type": "string" }
        },
        "max_age": { "type": "integer", "default": 3600 }
      }
    },
    "serverDatabase": {
      "type": "object",
      "properties": {
        "driver": { "type": "string", "enum": ["sqlite", "postgres"], "default": "sqlite" },
        "url": { "type": "string" }
      }
    },
    "serverAuth": {
      "type": "object",
      "properties": {
        "dev_mode": { "type": "boolean", "default": false },
        "dev_token": { "type": "string", "x-sensitive": true },
        "dev_token_file": { "type": "string" },
        "authorized_domains": {
          "type": "array",
          "items": { "type": "string" }
        }
      }
    },
    "serverOAuth": {
      "type": "object",
      "properties": {
        "web": { "$ref": "#/$defs/oauthClientConfig" },
        "cli": { "$ref": "#/$defs/oauthClientConfig" },
        "device": { "$ref": "#/$defs/oauthClientConfig" }
      }
    },
    "oauthClientConfig": {
      "type": "object",
      "properties": {
        "google": { "$ref": "#/$defs/oauthProviderConfig" },
        "github": { "$ref": "#/$defs/oauthProviderConfig" }
      }
    },
    "oauthProviderConfig": {
      "type": "object",
      "properties": {
        "client_id": { "type": "string" },
        "client_secret": { "type": "string", "x-sensitive": true }
      }
    },
    "serverStorage": {
      "type": "object",
      "properties": {
        "provider": { "type": "string", "enum": ["local", "gcs"], "default": "local" },
        "bucket": { "type": "string" },
        "local_path": { "type": "string" }
      }
    },
    "serverSecrets": {
      "type": "object",
      "properties": {
        "backend": { "type": "string", "enum": ["local", "gcpsm"], "default": "local" },
        "gcp_project_id": { "type": "string" },
        "gcp_credentials": { "type": "string" }
      }
    }
  }
}
```

A separate agent schema (`agent-v1.schema.json`) will be defined for `scion-agent.yaml` files. Its structure mirrors the existing `ScionConfig` with additions:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://scion.dev/schemas/agent/v1.json",
  "title": "Scion Agent Configuration",
  "type": "object",
  "properties": {
    "schema_version": { "type": "string", "const": "1" },
    "harness": { "type": "string" },
    "env": { "type": "object", "additionalProperties": { "type": "string" } },
    "volumes": { "type": "array", "items": { "$ref": "#/$defs/volumeMount" } },
    "resources": { "$ref": "#/$defs/resourceSpec" },
    "max_turns": {
      "type": "integer",
      "minimum": 1,
      "description": "Maximum number of LLM turns before the agent is stopped.",
      "x-since": "1"
    },
    "max_duration": {
      "type": "string",
      "pattern": "^[0-9]+(s|m|h)$",
      "description": "Maximum wall-clock duration before the agent is stopped (e.g., '2h', '30m').",
      "x-since": "1"
    },
    "services": {
      "type": "array",
      "items": { "$ref": "#/$defs/serviceSpec" }
    },
    "image": { "type": "string" },
    "user": { "type": "string" },
    "model": { "type": "string" },
    "args": { "type": "array", "items": { "type": "string" } },
    "detached": { "type": "boolean" }
  }
}
```

---

## 4. Environment Variable Mapping

### 4.1 Convention

All environment variables use the `SCION_` prefix. Nesting is represented by underscores. The schema's `x-env-var` annotation is the canonical source of truth.

### 4.2 Settings Env Vars

| Settings Path | Env Var | Type |
|---|---|---|
| `active_profile` | `SCION_ACTIVE_PROFILE` | string |
| `hub.enabled` | `SCION_HUB_ENABLED` | bool |
| `hub.endpoint` | `SCION_HUB_ENDPOINT` | string |
| `hub.token` | `SCION_HUB_TOKEN` | string |
| `hub.api_key` | `SCION_HUB_API_KEY` | string |
| `hub.grove_id` | `SCION_HUB_GROVE_ID` | string |
| `hub.broker_id` | `SCION_HUB_BROKER_ID` | string |
| `hub.broker_nickname` | `SCION_HUB_BROKER_NICKNAME` | string |
| `hub.broker_token` | `SCION_HUB_BROKER_TOKEN` | string |
| `hub.local_only` | `SCION_HUB_LOCAL_ONLY` | bool |
| `cli.autohelp` | `SCION_CLI_AUTOHELP` | bool |
| `cli.interactive_disabled` | `SCION_CLI_INTERACTIVE_DISABLED` | bool |

### 4.3 Server Env Vars

Server settings use the `SCION_SERVER_` prefix (unchanged from current behavior).

| Settings Path | Env Var |
|---|---|
| `server.hub.port` | `SCION_SERVER_HUB_PORT` |
| `server.hub.host` | `SCION_SERVER_HUB_HOST` |
| `server.hub.endpoint` | `SCION_SERVER_HUB_ENDPOINT` |
| `server.database.driver` | `SCION_SERVER_DATABASE_DRIVER` |
| `server.database.url` | `SCION_SERVER_DATABASE_URL` |
| `server.auth.dev_mode` | `SCION_SERVER_AUTH_DEV_MODE` |
| `server.log_level` | `SCION_SERVER_LOG_LEVEL` |
| `server.log_format` | `SCION_SERVER_LOG_FORMAT` |
| ... | ... (follows `SCION_SERVER_` + path convention) |

---

## 5. Detection & Transition Strategy

### 5.1 How Legacy vs Versioned Settings Are Detected

```
if file contains "schema_version" key:
    → versioned settings: validate against declared schema, use new loader
else if file contains top-level "harnesses" key:
    → legacy settings (current format): load via legacy path, emit deprecation warning
else if file is empty or missing:
    → no settings: use embedded defaults (versioned format)
```

### 5.2 Legacy Compatibility Layer

A `LegacySettingsAdapter` converts legacy `Settings` into the new versioned structure:

```go
func AdaptLegacySettings(legacy *LegacySettings) (*VersionedSettings, []string) {
    // Returns adapted settings + list of deprecation warnings
    // Mapping:
    //   legacy.Harnesses → versioned.HarnessConfigs (name = harness type, harness = name)
    //   legacy.Bucket → moved under server.storage or dropped with warning
    //   legacy.GroveID → preserved as-is
    //   legacy.DefaultTemplate → preserved as-is
    //   All other fields map 1:1
}
```

### 5.3 Deprecation Warning Format

```
WARNING: Legacy settings format detected in /path/to/settings.yaml
  The following fields are deprecated and will be removed in a future version:
    - "harnesses" → use "harness_configs" with explicit "harness" field
    - "bucket" → use "server.storage" (global) or remove (grove)
  Run 'scion config migrate' to automatically update your settings.
```

---

## 6. Phased Implementation Plan

### Phase 1: Schema Foundation

**Goal:** Introduce the JSON Schema, versioned settings struct, and detection/validation infrastructure without changing any runtime behavior.

**Deliverables:**
1. Create `pkg/config/schemas/settings-v1.schema.json` (the full schema from Section 3.5).
2. Create `pkg/config/schemas/agent-v1.schema.json`.
3. Embed schemas via `//go:embed` in a new `pkg/config/schema.go`.
4. Implement `DetectSettingsFormat(data []byte) (version string, isLegacy bool)` — inspects a settings file to determine if it's versioned or legacy.
5. Implement `ValidateSettings(data []byte, schemaVersion string) []ValidationError` — validates a settings file against its declared schema using an embedded JSON Schema validator.
6. Add a `scion config validate` command that validates the current effective settings and reports errors.
7. Write tests for schema validation with valid, invalid, and legacy input.

**No behavior changes.** Existing settings loading continues to use the legacy path.

### Phase 2: New Settings Structs & Loader

**Goal:** Implement the new Go structs and a parallel loading path that can load versioned settings files.

**Deliverables:**
1. Define `VersionedSettings` struct in `pkg/config/settings_v1.go` with all new groups (`Server`, `Hub`, `CLI`, `Runtimes`, `HarnessConfigs`, `Profiles`).
2. Define `HarnessConfigEntry` struct (the `harness_configs` value type with its explicit `harness` field).
3. Implement `LoadVersionedSettings(grovePath string) (*VersionedSettings, error)` using Koanf, loading with the same hierarchy (defaults → global → grove → env vars).
4. Implement `AdaptLegacySettings(legacy *Settings) (*VersionedSettings, []string)` that converts the current `Settings` struct to `VersionedSettings`, returning deprecation warnings.
5. Create a unified `LoadEffectiveSettings(grovePath string) (*VersionedSettings, []string, error)` that:
   - Detects format.
   - If versioned: validates and loads via the new path.
   - If legacy: loads via old path, adapts, emits warnings.
6. Update `pkg/config/embeds/default_settings.yaml` to use the versioned format (with `schema_version: "1"`).
7. Write comprehensive tests for both loading paths and the adapter.

**No consumer changes yet.** All existing code still uses the legacy `Settings` struct. The new loader exists but is not wired in.

### Phase 3: Consumer Migration — Core Resolution

**Goal:** Wire the new settings into the core resolution and provisioning paths.

**Deliverables:**
1. Add `ResolveHarnessConfig(profileName, harnessConfigName string) (HarnessConfigEntry, error)` to `VersionedSettings` — replaces `ResolveHarness` with support for named configs.
2. Add `ResolveRuntime(profileName string) (RuntimeConfig, string, error)` to `VersionedSettings` — same semantics, now uses `type` field.
3. Update `pkg/agent/provision.go` to accept `*VersionedSettings`. The function receives a `*VersionedSettings` and uses `ResolveHarnessConfig` instead of `ResolveHarness`.
4. Update `pkg/agent/run.go` to use `*VersionedSettings` for image, user, tmux resolution.
5. Update `cmd/create.go`, `cmd/start.go`, and other commands to call `LoadEffectiveSettings` and pass the result through.
6. Introduce a `--harness-config` flag to `scion create` (in addition to existing `--harness`) to select a named harness config.
7. Wire deprecation warnings to stderr output when legacy settings are detected.
8. Test that existing settings files (legacy format) produce identical behavior.

### Phase 4: Server Config Consolidation

**Goal:** Merge `server.yaml` / `GlobalConfig` into the unified settings under the `server` key.

**Deliverables:**
1. Update `LoadGlobalConfig` to check for `server` key in `settings.yaml` first, falling back to `server.yaml` for backward compatibility.
2. Add `ServerConfig` struct (mirrors current `GlobalConfig`) to `VersionedSettings`.
3. Map `SCION_SERVER_*` env vars to `server.*` paths in the unified Koanf loader.
4. When both `server.yaml` and `settings.yaml.server` exist, emit a warning and prefer `settings.yaml`.
5. Add `scion config migrate --server` to merge `server.yaml` into `settings.yaml`.
6. Update `scion server` and `scion broker` commands to read from the unified config.
7. Document that `server.yaml` is deprecated in favor of `settings.yaml` `server` section.

### Phase 5: New Feature Gates

**Goal:** Implement features that are gated on versioned settings.

**Deliverables:**
1. **`max_turns`**: In the agent runner, check `scionConfig.MaxTurns`. Only available when `schema_version >= 1` in the agent template. If the agent's harness supports turn counting (requires harness-level support), enforce the limit by sending a stop signal.
2. **`max_duration`**: In the agent runner, start a timer based on `scionConfig.MaxDuration`. Terminate the agent container after the duration elapses. Only available when `schema_version >= 1`.
3. **`cli.interactive_disabled`**: Check this setting in interactive prompts (attach, confirmations). When `true`, skip prompts and use defaults or fail with an error.
4. **Named harness configs**: With `harness_configs` fully wired, users can create agents with `scion create --harness-config gemini-high-security myagent`.
5. **Runtime type field**: Runtimes with explicit `type` fields resolve correctly through the factory.

### Phase 6: Migration Tooling & Cleanup

**Goal:** Provide automated migration and remove legacy code paths.

**Deliverables:**
1. Implement `scion config migrate` command:
   - Reads legacy settings file.
   - Produces versioned settings file.
   - Backs up the original as `settings.yaml.bak`.
   - Reports changes made.
2. Implement `scion config migrate --server` to fold `server.yaml` into `settings.yaml`.
3. Implement `scion config migrate --dry-run` for preview.
4. Update documentation (`docs-site/`) with new settings reference.
5. After a release cycle, remove the `LegacySettingsAdapter` and legacy loading path (Phase 2 code), making versioned settings the only supported format.

---

## 7. File Layout Changes

### Before (legacy)
```
~/.scion/
  settings.yaml              # flat Settings struct
  server.yaml                # separate GlobalConfig
.scion/
  settings.yaml              # grove-level Settings
  templates/
    gemini/
      scion-agent.json       # agent config (no schema)
```

### After (versioned)
```
~/.scion/
  settings.yaml              # VersionedSettings with schema_version, includes server section
.scion/
  settings.yaml              # grove-level VersionedSettings (no server section)
  templates/
    gemini/
      scion-agent.yaml       # agent config with schema_version
```

---

## 8. Key Decisions

### 8.1 Why not separate files per group?

A single `settings.yaml` with clear top-level groups is simpler to manage than multiple files. The Koanf merge hierarchy (defaults → global → grove → env) already handles layering. Splitting into `hub.yaml`, `runtimes.yaml`, etc. would multiply the number of files users must manage and complicate the merge logic.

### 8.2 Why absorb `server.yaml`?

The server config shares infrastructure with settings (Koanf loading, env vars, YAML format). Having two separate files with two separate loading paths is a maintenance burden. The `server` key is scoped to global-only, so there is no ambiguity about where it can appear.

### 8.3 Why `harness_configs` instead of extending `harnesses`?

The current `harnesses` map is keyed by harness type name, enforcing a 1:1 relationship between name and type. The new `harness_configs` map breaks this constraint, allowing multiple configurations for the same harness type. This is a semantic change that warrants a new key name to avoid confusion during the transition.

### 8.4 Why integer versioning?

Semantic versioning (major.minor.patch) is overkill for a settings schema. A simple monotonic integer is sufficient. Each increment represents a set of additive changes. The schema itself uses `x-since` annotations to track which version introduced each field, and `x-deprecated-by` to track removals.

### 8.5 Why JSON Schema instead of Go-only validation?

JSON Schema is language-neutral and can be used by IDEs (via `$schema` in YAML) for autocompletion and validation. It serves as documentation, validation specification, and tooling integration in one artifact. Go code validates against it at runtime using an embedded validator library.

---

## 9. Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Legacy adapter produces different behavior than direct legacy loading | Agents behave differently after upgrade | Comprehensive comparison tests: load legacy file both ways, diff the resolved configs |
| Schema validation rejects valid-but-unusual settings | Blocks users on upgrade | `additionalProperties: false` is strict by design but the migrate command preserves all known fields. Unknown fields are reported as warnings, not errors, during the transition period |
| `server.yaml` users don't notice the deprecation | Two config files drift out of sync | Emit a deprecation warning on every server start when `server.yaml` exists |
| Named harness configs break profile override resolution | Wrong harness config selected | Profile `harness_overrides` keys match harness-config names, not harness types. Document this clearly |
| Koanf deep merge behavior changes between legacy and versioned structs | Subtle config differences | Test merge behavior exhaustively with multi-layer configs |

---

## 10. Testing Strategy

### Unit Tests
- Schema validation: valid v1 file passes, missing required fields fail, unknown fields fail.
- Legacy detection: files with/without `schema_version` classified correctly.
- Legacy adapter: every field in `Settings` maps correctly to `VersionedSettings`.
- Resolution: `ResolveHarnessConfig` with default names, named variants, profile overrides.
- Env var mapping: every `x-env-var` in the schema is honored by the Koanf loader.

### Integration Tests
- Round-trip: write a `VersionedSettings` to YAML, reload it, compare.
- Migration: take a legacy `settings.yaml`, run the adapter, validate the output against the schema.
- Feature gates: `max_duration` and `max_turns` are only active when `schema_version >= 1`.
- Server consolidation: `server` key in `settings.yaml` produces the same `GlobalConfig` as a standalone `server.yaml`.

### Compatibility Tests
- The default embedded settings (upgraded to versioned format) produce the same resolved configs as the current embedded defaults.
- Existing grove-level settings (legacy format) work without modification and emit a deprecation warning.
