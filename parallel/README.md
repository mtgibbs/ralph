# Ralph Parallel Mode

Run N containerized Claude Code agents simultaneously against the same PRD. Each agent is sandboxed in Docker with network restrictions, resource limits, and no host access.

## How It Works

1. **Orchestrator** (`ralph-parallel.sh`) builds a Docker image, creates networks, and launches N containers
2. Each container runs the **agent loop** (`docker/agent-loop.sh`) which:
   - Clones the project from a bind-mounted directory
   - Claims a story in `prd.json` via git atomic push
   - Runs Claude Code with the parallel prompt
   - Pushes results and picks the next story
3. The orchestrator monitors container health, recovers stale claims, and handles token refresh
4. When all stories have `passes: true`, everything shuts down

## Prerequisites

- Docker installed and running
- A Claude Code auth token
- `jq` installed (`brew install jq` on macOS)
- A `prd.json` in the ralph root directory

## Quick Start

```bash
# Set your Claude auth token
export RALPH_CLAUDE_TOKEN='<your-oauth-token-json>'

# Run with 3 builder agents
./parallel/ralph-parallel.sh --agents 3

# Check status
./parallel/status.sh

# Graceful shutdown
./parallel/stop.sh
```

## CLI Options

```
./parallel/ralph-parallel.sh [options] [max_iterations]

Options:
  --agents N        Number of builder agents (default: 2)
  --researcher N    Number of researcher agents with full internet (default: 0)
  --model MODEL     Claude model (default: claude-sonnet-4-5-20250929)
  --memory SIZE     Per-container memory limit (default: 4g)
  --cpus N          Per-container CPU limit (default: 2)

Arguments:
  max_iterations    Per-agent iteration cap (default: 0 = until PRD complete)
```

## Authentication

Token retrieval priority (first wins):

1. **`RALPH_CLAUDE_TOKEN` env var** — set before running
2. **`.ralph/token` file** — write your token here
3. **1Password** via `op read` — interactive, startup only

### Mid-Run Token Refresh

Write a new token to `.ralph/token_refresh`. The orchestrator detects it within 30 seconds and restarts all containers with the new token.

## Story Claiming

Agents claim stories by modifying `prd.json` and using git's atomic push as a lock:

1. Agent finds highest-priority unclaimed story (`passes: false`, `claimed_by` empty)
2. Sets `claimed_by` and `claimed_at` fields
3. Commits and pushes
4. If push fails (another agent pushed first), rebase and pick a different story

### Stale Claim Recovery

The orchestrator checks for claims older than 30 minutes where the agent's container is no longer running. Stale claims are automatically cleared so other agents can pick up the work.

## Agent Roles

| Role | Network | Purpose |
|------|---------|---------|
| `builder` | API + npm only | Feature implementation, testing, code changes |
| `researcher` | Full internet | Web research, documentation lookup |

Builder agents are restricted via iptables to only reach:
- `api.anthropic.com` (Claude API)
- `statsig.anthropic.com` (telemetry)
- `registry.npmjs.org` (npm packages)

## File Layout

```
docker/
├── Dockerfile                      # Container image: node:20-slim + claude-code
├── agent-loop.sh                   # Container entrypoint: firewall → auth → clone → loop
├── init-firewall-builder.sh        # iptables: whitelist API + npm only
└── init-firewall-researcher.sh     # No-op (full internet)

parallel/
├── ralph-parallel.sh               # Host orchestrator: launch, monitor, restart
├── stop.sh                         # Graceful shutdown
├── status.sh                       # Container status + story board + logs
├── CLAUDE-parallel.md              # Parallel-aware prompt for agents
├── README.md                       # This file
└── lib/
    ├── auth.sh                     # Token retrieval: env > file > 1Password
    ├── network-setup.sh            # Docker network create/teardown
    ├── docker-helpers.sh           # Container launch/stop/restart
    └── logging.sh                  # Timestamped log helpers
```

## Per-Agent Progress Files

Instead of all agents appending to one `progress.txt` (merge conflict risk), each agent writes to `progress-<agent-id>.txt`. The parallel prompt instructs agents to read ALL progress files for context and write only to their own.

## Differences from `ralph.sh`

| | `ralph.sh` (original) | `ralph-parallel.sh` (new) |
|---|---|---|
| Runs on | Host, bare metal | Host, launches Docker containers |
| Agents | 1, sequential | N, parallel |
| Prompt | `CLAUDE.md` | `parallel/CLAUDE-parallel.md` |
| Auth | Delegates to CLI | Env var / file / 1Password |
| Network | Unrestricted | iptables firewall per container |
| Progress | `progress.txt` | `progress-<agent-id>.txt` per agent |
| Config | CLI args | CLI args |

## Debugging

```bash
# Check container status
./parallel/status.sh

# View container logs directly
docker logs ralph-agent-1

# View agent log files
ls -lt agent_logs/

# Check prd.json story status
cat prd.json | jq '.userStories[] | {id, title, passes, claimed_by}'

# Force rebuild the Docker image
docker rmi ralph-agent:latest
./parallel/ralph-parallel.sh --agents 1
```
