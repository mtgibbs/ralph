#!/usr/bin/env bash
set -euo pipefail
#
# ralph-parallel.sh — Parallel mode orchestrator for Ralph.
#
# Launches N containerized Claude Code agents that work on prd.json stories
# simultaneously. Each agent runs in a Docker container with network restrictions,
# resource limits, and no host access.
#
# Usage: ./parallel/ralph-parallel.sh [options] [max_iterations]
#
# Options:
#   --project DIR     Project directory containing prd.json (default: current dir)
#   --image IMAGE     Custom Docker image (default: ralph-agent:latest, auto-built)
#   --agents N        Number of builder agents (default: 2)
#   --researcher N    Number of researcher agents with full internet (default: 0)
#   --model MODEL     Claude model to use (default: claude-sonnet-4-5-20250929)
#   --memory SIZE     Per-container memory limit (default: 4g)
#   --cpus N          Per-container CPU limit (default: 2)
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RALPH_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source library scripts
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/auth.sh"
source "$SCRIPT_DIR/lib/network-setup.sh"
source "$SCRIPT_DIR/lib/docker-helpers.sh"

# --- Defaults ---
NUM_BUILDERS=2
NUM_RESEARCHERS=0
CLAUDE_MODEL="claude-sonnet-4-5-20250929"
CONTAINER_MEMORY="4g"
CONTAINER_CPUS="2"
MAX_ITERATIONS=0
STALE_CLAIM_MINUTES=30
PROJECT_DIR=""
CUSTOM_IMAGE=""
declare -a EXTRA_DOMAINS=()

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --project)
            PROJECT_DIR="$2"
            shift 2
            ;;
        --project=*)
            PROJECT_DIR="${1#*=}"
            shift
            ;;
        --image)
            CUSTOM_IMAGE="$2"
            shift 2
            ;;
        --image=*)
            CUSTOM_IMAGE="${1#*=}"
            shift
            ;;
        --agents)
            NUM_BUILDERS="$2"
            shift 2
            ;;
        --agents=*)
            NUM_BUILDERS="${1#*=}"
            shift
            ;;
        --researcher)
            NUM_RESEARCHERS="$2"
            shift 2
            ;;
        --researcher=*)
            NUM_RESEARCHERS="${1#*=}"
            shift
            ;;
        --model)
            CLAUDE_MODEL="$2"
            shift 2
            ;;
        --model=*)
            CLAUDE_MODEL="${1#*=}"
            shift
            ;;
        --memory)
            CONTAINER_MEMORY="$2"
            shift 2
            ;;
        --memory=*)
            CONTAINER_MEMORY="${1#*=}"
            shift
            ;;
        --cpus)
            CONTAINER_CPUS="$2"
            shift 2
            ;;
        --cpus=*)
            CONTAINER_CPUS="${1#*=}"
            shift
            ;;
        --allow-domain)
            EXTRA_DOMAINS+=("$2")
            shift 2
            ;;
        --allow-domain=*)
            EXTRA_DOMAINS+=("${1#*=}")
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [options] [max_iterations]"
            echo ""
            echo "Options:"
            echo "  --project DIR     Project directory with prd.json (default: current dir)"
            echo "  --image IMAGE     Custom Docker image (default: ralph-agent:latest)"
            echo "  --agents N        Number of builder agents (default: 2)"
            echo "  --researcher N    Number of researcher agents (default: 0)"
            echo "  --model MODEL     Claude model (default: claude-sonnet-4-5-20250929)"
            echo "  --memory SIZE     Per-container memory limit (default: 4g)"
            echo "  --cpus N          Per-container CPU limit (default: 2)"
            echo "  --allow-domain D  Extra domain to whitelist in firewall (repeatable)"
            echo ""
            echo "Arguments:"
            echo "  max_iterations    Per-agent iteration cap (default: 0 = until PRD complete)"
            exit 0
            ;;
        *)
            if [[ "$1" =~ ^[0-9]+$ ]]; then
                MAX_ITERATIONS="$1"
            else
                log_error "Unknown option: $1"
                exit 1
            fi
            shift
            ;;
    esac
done

TOTAL_AGENTS=$((NUM_BUILDERS + NUM_RESEARCHERS))

if [ "$TOTAL_AGENTS" -eq 0 ]; then
    log_error "No agents configured. Use --agents N and/or --researcher N."
    exit 1
fi

# --- Validate project directory ---
# Default to current working directory if --project not specified
if [ -z "$PROJECT_DIR" ]; then
    PROJECT_DIR="$(pwd)"
fi
# Resolve to absolute path
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
PRD_FILE="$PROJECT_DIR/prd.json"
# CLAUDE-parallel.md lives in the ralph repo, not the project
PARALLEL_PROMPT="$SCRIPT_DIR/CLAUDE-parallel.md"

if [ ! -f "$PRD_FILE" ]; then
    log_error "No prd.json found in $PROJECT_DIR"
    log_error "Create a prd.json first (see prd.json.example)."
    exit 1
fi

if [ ! -f "$PARALLEL_PROMPT" ]; then
    log_error "Missing parallel/CLAUDE-parallel.md prompt file"
    exit 1
fi

if [ ! -d "$PROJECT_DIR/.git" ]; then
    log_error "$PROJECT_DIR is not a git repository"
    exit 1
fi

# --- Display config ---
PROJECT_NAME=$(jq -r '.project // "unknown"' "$PRD_FILE" 2>/dev/null || echo "unknown")
BRANCH_NAME=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
TOTAL_STORIES=$(jq '.userStories | length' "$PRD_FILE" 2>/dev/null || echo "?")
DONE_STORIES=$(jq '[.userStories[] | select(.passes == true)] | length' "$PRD_FILE" 2>/dev/null || echo "?")

log_info "Ralph Parallel Mode"
log_info "===================="
log_info "Project: $PROJECT_NAME"
log_info "Branch: ${BRANCH_NAME:-<not set>}"
log_info "Stories: $DONE_STORIES/$TOTAL_STORIES complete"
log_info "Agents: $NUM_BUILDERS builders, $NUM_RESEARCHERS researchers ($TOTAL_AGENTS total)"
log_info "Image: ${CUSTOM_IMAGE:-$RALPH_IMAGE (default)}"
log_info "Model: $CLAUDE_MODEL"
log_info "Memory: $CONTAINER_MEMORY per container"
log_info "CPUs: $CONTAINER_CPUS per container"
log_info "Max iterations: $MAX_ITERATIONS (0=until PRD complete)"
if [ ${#EXTRA_DOMAINS[@]} -gt 0 ]; then
    RALPH_EXTRA_DOMAINS=$(IFS=,; echo "${EXTRA_DOMAINS[*]}")
    export RALPH_EXTRA_DOMAINS
    log_info "Extra domains: $RALPH_EXTRA_DOMAINS"
else
    RALPH_EXTRA_DOMAINS=""
fi
echo ""

# --- Step 1: Build or verify Docker image ---
if [ -n "$CUSTOM_IMAGE" ]; then
    # User specified a custom image — use it, don't auto-build
    export RALPH_IMAGE="$CUSTOM_IMAGE"
    log_info "Using custom image: $RALPH_IMAGE"
    if ! docker image inspect "$RALPH_IMAGE" &> /dev/null; then
        log_error "Custom image '$RALPH_IMAGE' not found. Build it first."
        exit 1
    fi
else
    log_info "Checking Docker image..."
    if ! docker image inspect "$RALPH_IMAGE" &> /dev/null; then
        build_image "$RALPH_ROOT/docker"
    else
        log_info "Image $RALPH_IMAGE already exists. Use 'docker rmi $RALPH_IMAGE' to force rebuild."
    fi
fi

# --- Step 2: Create Docker networks ---
create_networks

# --- Step 3: Verify Claude auth volume ---
log_info "Checking Claude auth volume..."
if ! check_auth_volume; then
    exit 1
fi
log_info "Claude auth volume verified"

# --- Step 4: Create bare repo for agent coordination ---
# Agents need a shared bare repo to push to — you can't reliably push
# to a non-bare repo's checked-out branch. We create .ralph/repo.git
# as a bare clone of the project, and agents push/pull from this.
BARE_REPO="$PROJECT_DIR/.ralph/repo.git"
if [ ! -d "$BARE_REPO" ]; then
    log_info "Creating bare repo for agent coordination..."
    mkdir -p "$PROJECT_DIR/.ralph"
    git clone --bare --filter=blob:none "$PROJECT_DIR" "$BARE_REPO"
    log_info "Bare repo created at $BARE_REPO"
else
    # Update the bare repo from the working directory
    log_info "Updating bare repo from project..."
    cd "$PROJECT_DIR"
    git push "$BARE_REPO" --all 2>/dev/null || true
    cd - > /dev/null
fi

# Clear any previous stop signal (truncate to empty; file is kept for Docker bind-mount)
: > "$PROJECT_DIR/.ralph/stop_requested"

# --- Step 6: Launch agent containers ---
AGENT_NUM=0
declare -a CONTAINER_NAMES=()

launch_agents_for_role() {
    local role="$1"
    local count="$2"

    [ "$count" -le 0 ] && return

    for i in $(seq 1 "$count"); do
        AGENT_NUM=$((AGENT_NUM + 1))
        local agent_id="agent-${AGENT_NUM}"
        local container_name="ralph-${agent_id}"

        # Stop existing container with same name if present
        if docker inspect "$container_name" &> /dev/null; then
            log_warn "Container $container_name already exists. Removing."
            stop_agent "$container_name" 10
        fi

        launch_agent \
            "$agent_id" \
            "$role" \
            "$PROJECT_DIR" \
            "$CLAUDE_MODEL" \
            "$MAX_ITERATIONS" \
            "$CONTAINER_MEMORY" \
            "$CONTAINER_CPUS"

        CONTAINER_NAMES+=("$container_name")
    done
}

log_info "Launching agents..."
launch_agents_for_role "builder" "$NUM_BUILDERS"
launch_agents_for_role "researcher" "$NUM_RESEARCHERS"

log_info "All $TOTAL_AGENTS agents launched."
echo ""

# --- Step 6: Monitor loop ---
MONITOR_INTERVAL=30
log_info "Entering monitor loop (checking every ${MONITOR_INTERVAL}s)."
log_info "Use ./parallel/stop.sh to stop."
log_info "Use ./parallel/status.sh to check status."
echo ""

# Helper: read a file from the bare repo without a full checkout
read_from_bare_repo() {
    local file="$1"
    local branch="${2:-main}"
    git --git-dir="$BARE_REPO" show "${branch}:${file}" 2>/dev/null \
        || git --git-dir="$BARE_REPO" show "master:${file}" 2>/dev/null \
        || echo ""
}

# Helper: check if all stories are complete in the bare repo
check_all_stories_complete() {
    local prd_content
    prd_content=$(read_from_bare_repo "prd.json" "$BRANCH_NAME")
    [ -z "$prd_content" ] && return 1

    local incomplete
    incomplete=$(echo "$prd_content" | jq '[.userStories[] | select(.passes == false)] | length' 2>/dev/null || echo "1")
    [ "$incomplete" -eq 0 ]
}

recover_stale_claims() {
    # Read prd.json from the bare repo (agents push there, not to project dir)
    local prd_content
    prd_content=$(read_from_bare_repo "prd.json" "$BRANCH_NAME")
    [ -z "$prd_content" ] && return

    local now_epoch
    now_epoch=$(date +%s)
    local stale_seconds=$((STALE_CLAIM_MINUTES * 60))

    local claims
    claims=$(echo "$prd_content" | jq -r '
        .userStories[]
        | select(.passes == false and .claimed_by != null and .claimed_by != "")
        | "\(.id)|\(.claimed_by)|\(.claimed_at // "")"
    ' 2>/dev/null || echo "")

    [ -z "$claims" ] && return

    local cleared=false
    local updated_prd="$prd_content"
    while IFS='|' read -r story_id agent claimed_at; do
        [ -z "$story_id" ] && continue
        [ -z "$claimed_at" ] && continue

        # Parse claimed_at timestamp (macOS date -j, fallback to GNU date -d)
        local claimed_epoch
        claimed_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$claimed_at" +%s 2>/dev/null \
            || date -d "$claimed_at" +%s 2>/dev/null \
            || echo "0")

        if [ "$claimed_epoch" -eq 0 ]; then
            continue
        fi

        local age=$((now_epoch - claimed_epoch))
        if [ "$age" -gt "$stale_seconds" ]; then
            local container_name="ralph-${agent}"
            if ! is_agent_running "$container_name"; then
                log_warn "Stale claim detected: $story_id by $agent (${age}s old, container not running). Clearing."
                updated_prd=$(echo "$updated_prd" | jq --arg sid "$story_id" '
                    .userStories |= map(
                        if .id == $sid then
                            del(.claimed_by) | del(.claimed_at)
                        else . end
                    )
                ')
                cleared=true
            fi
        fi
    done <<< "$claims"

    if $cleared; then
        # Commit the cleared claims to the bare repo via a temp checkout
        local temp_dir
        temp_dir=$(mktemp -d)
        git clone "$BARE_REPO" "$temp_dir/work" 2>/dev/null
        cd "$temp_dir/work"
        git config user.name "ralph-orchestrator"
        git config user.email "orchestrator@ralph-agent.local"
        if [ -n "$BRANCH_NAME" ]; then
            git checkout "$BRANCH_NAME" 2>/dev/null || true
        fi
        echo "$updated_prd" | jq '.' > prd.json
        git add prd.json
        git commit -m "[orchestrator] Clear stale claims" 2>/dev/null || true
        git push origin 2>/dev/null || true
        cd - > /dev/null
        rm -rf "$temp_dir"
    fi
}

while true; do
    sleep "$MONITOR_INTERVAL"

    # Check if stop was requested
    if [ -s "$PROJECT_DIR/.ralph/stop_requested" ]; then
        log_info "Stop requested. Shutting down all agents..."
        for name in "${CONTAINER_NAMES[@]}"; do
            stop_agent "$name" 30
        done
        teardown_networks
        log_info "All agents stopped. Exiting."
        exit 0
    fi

    # Recover stale claims
    recover_stale_claims

    # Check container health
    ALL_STOPPED=true
    for name in "${CONTAINER_NAMES[@]}"; do
        if is_agent_running "$name"; then
            ALL_STOPPED=false
        else
            EXIT_CODE=$(docker inspect -f '{{.State.ExitCode}}' "$name" 2>/dev/null || echo "unknown")

            if [ "$EXIT_CODE" = "0" ]; then
                log_info "Container $name exited cleanly (code 0)."
            else
                log_warn "Container $name stopped unexpectedly (exit code: $EXIT_CODE). Restarting..."
                restart_agent "$name"
                if is_agent_running "$name"; then
                    ALL_STOPPED=false
                else
                    log_error "Failed to restart $name"
                fi
            fi
        fi
    done

    # Check if all stories are complete (read from bare repo)
    if check_all_stories_complete; then
        log_info "All PRD stories are complete!"
        log_info "Shutting down agents..."
        for name in "${CONTAINER_NAMES[@]}"; do
            stop_agent "$name" 15
        done
        # Sync bare repo back to project working directory
        log_info "Syncing results back to project..."
        cd "$PROJECT_DIR"
        git fetch "$BARE_REPO" 2>/dev/null || true
        git merge FETCH_HEAD 2>/dev/null || true
        teardown_networks
        log_info "Done. All stories passed."
        exit 0
    fi

    if $ALL_STOPPED; then
        log_info "All agents have exited. Cleaning up..."
        for name in "${CONTAINER_NAMES[@]}"; do
            docker rm "$name" 2>/dev/null || true
        done
        teardown_networks
        log_info "Done."
        exit 0
    fi
done
