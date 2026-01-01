# Scion

Scion is a container-based orchestration tool designed to manage concurrent LLM-based code agents across your local machine and remote clusters. It enables developers to run specialized sub-agents with isolated identities, credentials, and workspaces, allowing for parallel execution of tasks such as coding, auditing, and testing.

## Key Features

- **Parallelism**: Run multiple agents concurrently as independent processes either locally or remote.
- **Isolation**: Each agent runs in its own container with strict separation of credentials, configuration, and environment.
- **Context Management**: Scion uses `git worktree` to provide each agent with a dedicated workspace, preventing merge conflicts and ensuring clean separation of concerns.
- **Specialization**: Agents can be customized via templates (e.g., "Security Auditor", "QA Tester") to perform specific roles.
- **Interactivity**: Agents support "detached" background operation, but users can "attach" to any running agent for human-in-the-loop interaction.

## Installation

You can install Scion directly from the source using Go:

```bash
go install github.com/ptone/scion-agent@latest
```

Ensure that your `$GOPATH/bin` is in your system `$PATH`.

## Core Concepts

- **Agent**: An isolated container running an LLM-driven task. It acts as an independent worker with its own identity, credentials, and workspace.
- **Grove**: A project workspace where agents live. It corresponds to a `.scion` directory on the filesystem (usually at the root of a git repository).
- **Harness**: Adapts a specific underlying LLM tool (like Gemini CLI or Claude Code) into the Scion ecosystem, handling provisioning and execution inside a container.
- **Template**: A blueprint for an agent, defining its base configuration, system prompt, and tools.
- **Runtime**: The infrastructure layer responsible for executing agent containers (supports Docker, Apple Container, and experimental Kubernetes).

## Architecture & Workspace Strategy

Scion uses **Git Worktrees** to enable multiple agents to work on the same codebase simultaneously without conflicts.
- When an agent starts, Scion creates a new git worktree for it.
- This worktree creates a dedicated branch for the agent, ensuring independent working directories while sharing the same repository history.
- The worktree is mounted into the agent's container as `/workspace`.

### Resource Isolation
Each agent is provisioned with:
- **Dedicated Filesystem**: A unique home directory containing its unique settings and history.
- **Credential Projection**: API keys and cloud credentials (e.g., Google Application Default Credentials) are securely projected into the container.
- **Environment**: Environment variables are explicitly projected into the container.

## Quick Start

### 1. Initialize a Grove

Navigate to your project root and initialize a new Scion grove. This creates the `.scion` directory and seeds default templates.

```bash
cd my-project
scion grove init
```

### 2. Start Agents

You can launch an agent immediately using `start` (or its alias `run`). By default, this runs in the background using the `gemini` template.

```bash
# Start a gemini agent named "coder"
scion start coder "Refactor the authentication middleware in pkg/auth"

# Start a Claude-based agent
scion run auditor "Audit the user input validation" --type claude

# Start and immediately attach to the session
scion start debug "Help me debug this error" --attach
```

### 3. Manage Agents

- **List active agents**: `scion list`
- **Attach to an agent**: `scion attach <agent-name>`
- **View logs**: `scion logs <agent-name>`
- **Stop an agent**: `scion stop <agent-name>`
- **Delete an agent**: `scion delete <agent-name>` (removes container, directory, and worktree)

### 4. Customization Workflow (Create-Then-Start)

The `create` command allows you to provision an agent's directory structure without launching it, allowing for manual customization of the system prompt or tools.

```bash
scion create my-agent --type research-specialist
# Edit files in .scion/agents/my-agent/home/
scion start my-agent "Analyze the codebase"
```

## Configuration

Scion settings are managed in `settings.json` files, following a precedence order: **Grove** (`.scion/settings.json`) > **Global** (`~/.scion/settings.json`) > **Defaults**.

Templates serve as blueprints and can be managed via the `templates` subcommand:
- **List templates**: `scion templates list`
- **Create a template**: `scion templates create <name>`
- Use the `--global` flag to target the global template store in `~/.scion/templates`.

## License

This project is licensed under the Apache License, Version 2.0. See the [LICENSE](LICENSE) file for details.