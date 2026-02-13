#!/usr/bin/env bash
#
# docker-helpers.sh — Container launch and management helpers for Ralph parallel mode.
#

RALPH_IMAGE="ralph-agent:latest"

build_image() {
    local docker_dir="$1"

    log_info "Building Ralph agent image..."
    docker build --platform linux/arm64 -t "$RALPH_IMAGE" "$docker_dir"
    log_info "Image built: $RALPH_IMAGE"
}

launch_agent() {
    local agent_id="$1"
    local agent_role="$2"
    local project_dir="$3"
    local claude_token="$4"
    local claude_model="$5"
    local max_iterations="$6"
    local container_memory="${7:-4g}"
    local container_cpus="${8:-2}"

    # Determine network based on role
    local network
    case "$agent_role" in
        researcher) network="$RESEARCHER_NETWORK" ;;
        *)          network="$BUILDER_NETWORK" ;;
    esac

    local container_name="ralph-${agent_id}"
    local project_dir_abs
    project_dir_abs="$(cd "$project_dir" && pwd)"

    log_info "Launching container: $container_name (role=$agent_role, network=$network)"

    # Ensure log and state directories exist
    mkdir -p "$project_dir_abs/agent_logs" "$project_dir_abs/.ralph"

    docker run -d \
        --name "$container_name" \
        --network "$network" \
        --platform linux/arm64 \
        --memory="$container_memory" \
        --cpus="$container_cpus" \
        --pids-limit=256 \
        --cap-add=NET_ADMIN \
        --cap-add=NET_RAW \
        -e "AGENT_ID=$agent_id" \
        -e "AGENT_ROLE=$agent_role" \
        -e "CLAUDE_CODE_OAUTH_TOKEN=$claude_token" \
        -e "CLAUDE_MODEL=$claude_model" \
        -e "MAX_ITERATIONS=$max_iterations" \
        -v "$project_dir_abs/.ralph/repo.git:/repo.git:rw" \
        -v "$project_dir_abs/parallel/CLAUDE-parallel.md:/parallel-prompt/CLAUDE-parallel.md:ro" \
        -v "$project_dir_abs/agent_logs:/agent-logs:rw" \
        -v "$project_dir_abs/.ralph:/harness-state:ro" \
        "$RALPH_IMAGE"

    log_info "Container $container_name started"
}

stop_agent() {
    local container_name="$1"
    local timeout="${2:-30}"

    log_info "Stopping container: $container_name (timeout=${timeout}s)"
    docker stop -t "$timeout" "$container_name" 2>/dev/null || true
    docker rm "$container_name" 2>/dev/null || true
}

is_agent_running() {
    local container_name="$1"
    docker inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null | grep -q "true"
}

restart_agent() {
    local container_name="$1"

    log_info "Restarting container: $container_name"
    docker restart "$container_name" 2>/dev/null || {
        log_error "Could not restart $container_name"
        return 1
    }
    log_info "Container $container_name restarted"
}
