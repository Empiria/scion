# Scion Overview

Scion is a container-based orchestration tool designed to manage concurrent LLM-based code agents across your local machine and remote clusters. It enables developers to run specialized sub-agents with isolated identities, credentials, and workspaces, allowing for parallel execution of tasks such as coding, auditing, and testing.

## Key Features

- **Parallelism**: Run multiple agents concurrently as independent processes either locally or remote.
- **Isolation**: Each agent runs in its own container with strict separation of credentials, configuration, and environment.
- **Context Management**: Scion uses `git worktree` to provide each agent with a dedicated workspace, preventing merge conflicts and ensuring clean separation of concerns.
- **Specialization**: Agents can be customized via templates (e.g., "Security Auditor", "QA Tester") to perform specific roles.
- **Interactivity**: Agents support "detached" background operation, but users can "attach" to any running agent for human-in-the-loop interaction.

## Architecture

Scion follows a Manager-Worker architecture:

- **scion**: A host-side CLI that orchestrates the lifecycle of agents. It manages the "Grove" (the project workspace).
- **Agents**: Isolated runtime containers (e.g., Docker) running the agent software (like Gemini CLI or Claude Code).

### Resource Isolation

Each agent is provisioned with:
- **Dedicated Filesystem**: A unique home directory and workspace.
- **Network Isolation**: Agents share a bridge network but are otherwise isolated.
- **Credential Projection**: API keys and cloud credentials (e.g., Google Application Default Credentials) are securely projected into the container.

## Getting Started

Scion is designed to be easy to start with.

1.  **Initialize**: Run `scion grove init` in your project root to create a `.scion` directory.
2.  **Start an Agent**: Use `scion start <agent-name> "<task>"` to launch an agent.
3.  **Interact**: Use `scion attach <agent-name>` to interact with the agent's session, or `scion logs <agent-name>` to view its output.
