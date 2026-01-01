# Hosted Scion Architecture Design

## Status
**Proposed**

## 1. Overview
This document outlines the architecture for transforming Scion from a local/hybrid CLI tool into a fully hosted, web-based SaaS platform. The core goal is to enable users to run, manage, and interact with coding agents entirely through a web browser, without local dependencies like Docker or the Scion CLI.

The platform will leverage Kubernetes for agent orchestration and replace local file-based persistence with a centralized database (Firestore).

## 2. Goals & Scope
*   **Fully Hosted:** No local CLI required.
*   **Web-Based PTY:** Users attach to agent shells via a browser-based terminal.
*   **Kubernetes Only:** The runtime will be exclusively Kubernetes to ensure scalability and standard orchestration.
*   **Centralized Templates:** Agent blueprints (templates) are stored and managed on the server.
*   **Git-Centric:** Agents operate primarily by cloning Git repositories.
*   **Zip Export:** Support for downloading the workspace state for non-coding usage.
*   **Persistent State:** Move agent metadata and state from `.scion/` files to a database.

## 3. High-Level Architecture

The system consists of the following core components:

```mermaid
graph TD
    User[User (Browser)] -->|HTTPS| LB[Load Balancer]
    LB -->|REST/gRPC| API[Scion API Server]
    LB -->|WebSocket| API

    API -->|Manage| K8s[Kubernetes Cluster]
    API -->|Read/Write| DB[(Firestore)]
    API -->|Read/Write| Secrets[Secret Manager]

    subgraph Kubernetes Cluster
        AgentPod[Agent Pod]
        InitContainer[Init: Git Clone]
        Sidecar[Optional: Log Streamer]

        AgentPod -->|Events/Status| API
    end

    User -->|WS Stream| API -->|SPDY/Exec| AgentPod
```

## 4. Core Components

### 4.1. Scion API Server
A new Go-based server component responsible for:
*   Implementing the `Manager` interface for centralized control.
*   Handling user authentication and authorization.
*   Proxying PTY connections (WebSockets) to Kubernetes pods.
*   Serving the frontend application.

### 4.2. Persistence Layer (Data Store)
We will transition from local file persistence (`~/.scion`, `.scion/`) to a `Store` interface.

**Interface Definition:**
```go
type Store interface {
    GetAgent(ctx context.Context, id string) (*AgentInfo, error)
    CreateAgent(ctx context.Context, agent *AgentInfo) error
    UpdateAgent(ctx context.Context, agent *AgentInfo) error
    ListAgents(ctx context.Context, filter AgentFilter) ([]*AgentInfo, error)
    GetTemplate(ctx context.Context, name string) (*Template, error)
}
```

**Implementation:**
*   **Initial:** Google Cloud Firestore.
*   **Data Model:**
    *   `Users`: Account info, preferences.
    *   `Projects` (formerly Groves): Logical grouping of agents.
    *   `Agents`: Metadata, status, runtime config, associated Pod name.
    *   `Templates`: Server-side definitions of agent types (replacing local embedded templates).

### 4.3. Runtime (Kubernetes Exclusive)
The existing `KubernetesRuntime` will be adapted to:
*   Remove dependencies on local paths (`grovePath`).
*   Use persistent identifiers (Database IDs) instead of local folder names.
*   **Storage:** Use `PersistentVolumeClaims` (PVCs) dynamically provisioned for each agent to persist `/home/scion`.
*   **Networking:** Ensure pods are reachable by the API server for exec/attach commands.

### 4.4. Scion Tool (Agent-Side)
The `sciontool` (Python script inside the container) currently relies on local hooks. In the hosted model:
*   It will be configured via environment variables: `SCION_API_ENDPOINT`, `SCION_AGENT_ID`.
*   It will communicate status updates, tool use events, and prompts back to the API Server via HTTP/gRPC.
*   **Authentication:** The agent pod will use Workload Identity or an injected token to authenticate with the API Server.

## 5. Detailed Workflows

### 5.1. Agent Creation
1.  **User** selects a Template (e.g., "Claude Code") and provides a Git Repository URL.
2.  **API Server**:
    *   Creates an `Agent` record in Firestore (Status: `PROVISIONING`).
    *   Calls `KubernetesRuntime.Start`.
3.  **KubernetesRuntime**:
    *   Creates a PVC for the agent's home directory.
    *   Launches a Pod with an **Init Container**.
4.  **Init Container**:
    *   Clones the provided Git URL into the shared volume.
5.  **Main Container**:
    *   Starts the agent process (e.g., `claude`).
    *   `sciontool` notifies API that status is `RUNNING`.

### 5.2. Web PTY Attachment
1.  **Frontend** initiates a WebSocket connection to `wss://api.scion.host/agents/{id}/attach`.
2.  **API Server** validates the session.
3.  **API Server** upgrades the connection and establishes a stream to the Kubernetes Pod using `remotecommand.NewSPDYExecutor` (standard K8s API strategy).
4.  **Data Flow:** Browser xterm.js <-> WebSocket <-> API Server <-> K8s SPDY <-> Pod PTY.

### 5.3. Zip Export
1.  **User** requests `GET /agents/{id}/export`.
2.  **API Server** streams a tarball from the Pod:
    *   Executes `tar -czf - /home/scion/workspace` inside the pod.
    *   Pipes the output directly to the HTTP response.

## 6. API Design (Draft)

*   `GET /templates`: List available server-side templates.
*   `POST /agents`: Create a new agent.
    *   Body: `{ templateId, gitUrl, name }`
*   `GET /agents`: List user's agents.
*   `GET /agents/{id}`: Get agent details and status.
*   `POST /agents/{id}/stop`: Stop the pod (retain PVC).
*   `POST /agents/{id}/start`: Resume the agent (attach existing PVC).
*   `DELETE /agents/{id}`: Destroy agent and release PVC.
*   `WS /agents/{id}/attach`: WebSocket endpoint for PTY.

## 7. Security Considerations

*   **Isolation:**
    *   Each user/project could reside in a separate Kubernetes Namespace, or use `NetworkPolicies` to isolate agent pods from each other in a shared namespace.
    *   **Recommendation:** Start with a shared namespace and strict NetworkPolicies denying inter-pod communication.
*   **Authentication:**
    *   User Auth: OAuth2 / OIDC (Google/GitHub).
    *   Agent-to-API Auth: Kubernetes Service Accounts projected as OIDC tokens (Workload Identity) to authenticate API calls from `sciontool`.
*   **Secrets:**
    *   SCM Credentials (GitHub Tokens) should be injected via K8s Secrets or External Secrets Operator, not stored in plain text in Firestore.

## 8. Migration & compatibility
*   The `pkg/agent.Manager` interface will have two implementations:
    1.  `LocalManager`: The current implementation (files + Docker/K8s).
    2.  `ServerManager`: The new implementation for the hosted service (DB + K8s).
*   The CLI can eventually become a client for the API Server, allowing `scion attach` to work against hosted agents.
