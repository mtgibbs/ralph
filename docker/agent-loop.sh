#!/usr/bin/env bash
set -euo pipefail
#
# agent-loop.sh — Container entrypoint for Ralph parallel agents.
#
# Clones from a bind-mounted project directory, claims stories from prd.json
# via git atomic push, runs Claude Code per iteration, and pushes results.
#
# Expected environment variables:
#   AGENT_ID                 - Unique agent identifier (e.g., "agent-1")
#   AGENT_ROLE               - One of: builder, researcher
#   MAX_ITERATIONS           - Max loop iterations (0 = infinite, default: 0)
#   CLAUDE_MODEL             - Model to use (default: claude-sonnet-4-5-20250929)
#
# Auth: Claude credentials are mounted via Docker volume at /home/agent/.claude
#

AGENT_ID="${AGENT_ID:?AGENT_ID is required}"
AGENT_ROLE="${AGENT_ROLE:?AGENT_ROLE is required}"
MAX_ITERATIONS="${MAX_ITERATIONS:-0}"
CLAUDE_MODEL="${CLAUDE_MODEL:-claude-sonnet-4-5-20250929}"

REPO_PATH="/repo.git"
WORKSPACE="/workspace"
PROMPT_DIR="/parallel-prompt"
PROMPT_FILE="$PROMPT_DIR/CLAUDE-parallel.md"
STOP_FILE="/harness-state/stop_requested"
LOG_DIR="/agent-logs"
ITERATION=0

echo "[$AGENT_ID] Starting agent loop (role=$AGENT_ROLE, model=$CLAUDE_MODEL, max_iterations=$MAX_ITERATIONS)"

# --- Step 1: Initialize firewall based on role ---
echo "[$AGENT_ID] Initializing firewall for role: $AGENT_ROLE"
case "$AGENT_ROLE" in
    researcher)
        sudo /opt/ralph/init-firewall-researcher.sh
        ;;
    *)
        sudo /opt/ralph/init-firewall-builder.sh
        ;;
esac

# --- Step 2: Copy Claude auth credentials from mounted volume ---
if [ ! -f /claude-auth/.credentials.json ]; then
    echo "[$AGENT_ID] ERROR: No Claude credentials found at /claude-auth/.credentials.json"
    echo "[$AGENT_ID] Ensure the ralph-claude-auth volume is mounted."
    exit 1
fi
mkdir -p ~/.claude
cp /claude-auth/.credentials.json ~/.claude/.credentials.json
chmod 600 ~/.claude/.credentials.json
echo "[$AGENT_ID] Claude credentials copied"

# --- Step 3: Clone or update workspace from bare repo ---
setup_workspace() {
    if [ -d "$WORKSPACE/.git" ]; then
        echo "[$AGENT_ID] Fetching latest changes"
        cd "$WORKSPACE"
        git fetch origin
        # Reset to current branch's remote tracking, not hard-coded main
        local current_branch
        current_branch=$(git branch --show-current 2>/dev/null || echo "")
        if [ -n "$current_branch" ]; then
            git reset --hard "origin/$current_branch" 2>/dev/null || true
        else
            git reset --hard origin/main 2>/dev/null || git reset --hard origin/master 2>/dev/null || true
        fi
    else
        echo "[$AGENT_ID] Cloning bare repo into workspace"
        git clone "$REPO_PATH" "$WORKSPACE"
        cd "$WORKSPACE"
    fi
}

# --- Step 4: Set git identity ---
setup_git_identity() {
    git config user.name "$AGENT_ID"
    git config user.email "${AGENT_ID}@ralph-agent.local"
    git config pull.rebase true
}

# --- Step 5: Check out the correct branch from prd.json ---
checkout_prd_branch() {
    if [ ! -f "$WORKSPACE/prd.json" ]; then
        echo "[$AGENT_ID] WARNING: No prd.json found in workspace"
        return 1
    fi

    local branch_name
    branch_name=$(jq -r '.branchName // empty' "$WORKSPACE/prd.json" 2>/dev/null || echo "")

    if [ -z "$branch_name" ]; then
        echo "[$AGENT_ID] No branchName in prd.json, staying on current branch"
        return 0
    fi

    local current_branch
    current_branch=$(git branch --show-current 2>/dev/null || echo "")

    if [ "$current_branch" = "$branch_name" ]; then
        echo "[$AGENT_ID] Already on branch: $branch_name"
        return 0
    fi

    echo "[$AGENT_ID] Checking out branch: $branch_name"
    if git show-ref --verify --quiet "refs/heads/$branch_name" 2>/dev/null; then
        git checkout "$branch_name"
    elif git show-ref --verify --quiet "refs/remotes/origin/$branch_name" 2>/dev/null; then
        git checkout -b "$branch_name" "origin/$branch_name"
    else
        git checkout -b "$branch_name"
    fi
}

# --- Step 6: Claim a story in prd.json ---
# Returns 0 and prints story ID if claimed, returns 1 if no stories available
claim_story() {
    cd "$WORKSPACE"

    # Pull latest prd.json (all git output to stderr to keep stdout clean for return value)
    git pull --rebase >&2 2>&1 || {
        git rebase --abort >/dev/null 2>&1 || true
        git fetch origin >&2 2>&1
        git reset --hard "origin/$(git branch --show-current)" >&2 2>&1
    }

    if [ ! -f prd.json ]; then
        echo "[$AGENT_ID] No prd.json found" >&2
        return 1
    fi

    # Find highest-priority unclaimed story (passes: false AND no claimed_by)
    local story_id
    story_id=$(jq -r '
        .userStories
        | map(select(.passes == false and (.claimed_by == null or .claimed_by == "")))
        | sort_by(.priority)
        | first
        | .id // empty
    ' prd.json 2>/dev/null || echo "")

    if [ -z "$story_id" ]; then
        echo "[$AGENT_ID] No unclaimed stories available" >&2
        return 1
    fi

    # Claim it by setting claimed_by and claimed_at
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    jq --arg agent "$AGENT_ID" --arg ts "$timestamp" --arg sid "$story_id" '
        .userStories |= map(
            if .id == $sid then
                .claimed_by = $agent | .claimed_at = $ts
            else . end
        )
    ' prd.json > prd.json.tmp && mv prd.json.tmp prd.json

    git add prd.json >&2 2>&1
    git commit -m "[$AGENT_ID] Claim: $story_id" >&2 2>&1 || {
        echo "[$AGENT_ID] Failed to commit claim for $story_id" >&2
        git checkout -- prd.json >/dev/null 2>&1 || true
        return 1
    }

    # Atomic push — if this fails, another agent claimed something concurrently
    if git push >&2 2>&1; then
        echo "$story_id"
        return 0
    else
        echo "[$AGENT_ID] Push failed (concurrent claim). Resetting and retrying..." >&2
        git reset --hard HEAD~1 >&2 2>&1
        git pull --rebase >&2 2>&1 || {
            git rebase --abort >/dev/null 2>&1 || true
            git fetch origin >&2 2>&1
            git reset --hard "origin/$(git branch --show-current)" >&2 2>&1
        }
        return 1
    fi
}

# --- Step 7: Check if all stories are complete ---
all_stories_complete() {
    if [ ! -f "$WORKSPACE/prd.json" ]; then
        return 1
    fi

    local incomplete
    incomplete=$(jq '[.userStories[] | select(.passes == false)] | length' "$WORKSPACE/prd.json" 2>/dev/null || echo "1")
    [ "$incomplete" -eq 0 ]
}

# --- Step 8: Push changes with retry ---
push_with_retry() {
    local max_attempts=3
    local attempt=0
    local branch
    branch=$(git branch --show-current 2>/dev/null || echo "main")

    while [ $attempt -lt $max_attempts ]; do
        if git push origin "$branch" 2>&1; then
            echo "[$AGENT_ID] Push successful."
            return 0
        fi
        attempt=$((attempt + 1))
        echo "[$AGENT_ID] Push failed (attempt $attempt/$max_attempts). Rebasing..."
        git pull --rebase origin "$branch" 2>&1 || {
            echo "[$AGENT_ID] Rebase conflict. Aborting rebase and resetting."
            git rebase --abort 2>/dev/null || true
            git fetch origin
            git reset --hard "origin/$branch"
            return 1
        }
    done

    echo "[$AGENT_ID] Failed to push after $max_attempts attempts."
    return 1
}

# --- Step 9: Prepare the prompt with agent identity ---
prepare_prompt() {
    if [ ! -f "$PROMPT_FILE" ]; then
        echo "[$AGENT_ID] ERROR: Prompt file not found at $PROMPT_FILE"
        return 1
    fi

    # Inject agent identity into prompt
    sed "s/{{AGENT_ID}}/$AGENT_ID/g" "$PROMPT_FILE"
}

# --- Main loop ---
setup_workspace
setup_git_identity
checkout_prd_branch

echo "[$AGENT_ID] Entering main loop"

while true; do
    # Check stop signal
    if [ -f "$STOP_FILE" ]; then
        echo "[$AGENT_ID] Stop requested. Exiting gracefully."
        exit 0
    fi

    # Check iteration limit
    if [ "$MAX_ITERATIONS" -gt 0 ] && [ "$ITERATION" -ge "$MAX_ITERATIONS" ]; then
        echo "[$AGENT_ID] Reached max iterations ($MAX_ITERATIONS). Exiting."
        exit 0
    fi

    # Check if all stories are done
    if all_stories_complete; then
        echo "[$AGENT_ID] All stories complete. Exiting."
        exit 0
    fi

    ITERATION=$((ITERATION + 1))
    COMMIT=$(git rev-parse --short=6 HEAD 2>/dev/null || echo "000000")
    LOGFILE="${LOG_DIR}/${AGENT_ID}_iter${ITERATION}_${COMMIT}.log"
    TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    echo "[$AGENT_ID] === Iteration $ITERATION (commit: $COMMIT) at $TIMESTAMP ==="

    # Attempt to claim a story (retry up to 3 times with different stories)
    CLAIMED_STORY=""
    CLAIM_ATTEMPTS=0
    while [ $CLAIM_ATTEMPTS -lt 3 ] && [ -z "$CLAIMED_STORY" ]; do
        # Use if to prevent set -e from killing the script on claim failure
        if CLAIMED_STORY=$(claim_story); then
            break
        else
            CLAIMED_STORY=""
            CLAIM_ATTEMPTS=$((CLAIM_ATTEMPTS + 1))
            sleep 2
        fi
    done

    if [ -z "$CLAIMED_STORY" ]; then
        echo "[$AGENT_ID] Could not claim any story. Checking if all complete..."
        if all_stories_complete; then
            echo "[$AGENT_ID] All stories complete. Exiting."
            exit 0
        fi
        echo "[$AGENT_ID] Stories exist but couldn't claim. Waiting 30s..."
        sleep 30
        continue
    fi

    echo "[$AGENT_ID] Claimed story: $CLAIMED_STORY"

    # Prepare prompt
    PROMPT=$(prepare_prompt) || {
        echo "[$AGENT_ID] Failed to prepare prompt. Sleeping 10s..."
        sleep 10
        continue
    }

    # Run Claude
    echo "[$AGENT_ID] Running Claude (model: $CLAUDE_MODEL) for story: $CLAIMED_STORY"
    claude --dangerously-skip-permissions \
        --print \
        --model "$CLAUDE_MODEL" \
        -p "$PROMPT" \
        &> "$LOGFILE" || {
        echo "[$AGENT_ID] Claude exited with error (code: $?). Check log: $LOGFILE"
    }

    echo "[$AGENT_ID] Claude session complete. Pushing changes..."

    # Stage and commit any remaining unstaged changes
    if ! git diff --quiet || ! git diff --cached --quiet; then
        git add -A
        if ! git diff --cached --quiet; then
            git commit -m "[$AGENT_ID] Iteration $ITERATION: $CLAIMED_STORY" || true
        fi
    fi

    # Push with retry
    push_with_retry

    # Write per-agent progress
    {
        echo "## $TIMESTAMP - $CLAIMED_STORY (Iteration $ITERATION)"
        echo "- Agent: $AGENT_ID"
        echo "- Commit: $COMMIT"
        echo "---"
    } >> "$WORKSPACE/progress-${AGENT_ID}.txt"

    # Check for completion sentinel in output
    if [ -f "$LOGFILE" ] && grep -q "<promise>COMPLETE</promise>" "$LOGFILE"; then
        echo "[$AGENT_ID] Completion sentinel detected. Verifying all stories..."
        git pull --rebase 2>/dev/null || true
        if all_stories_complete; then
            echo "[$AGENT_ID] All stories confirmed complete. Exiting."
            exit 0
        fi
    fi

    echo "[$AGENT_ID] Iteration $ITERATION complete. Sleeping 5s..."
    sleep 5
done
