#!/bin/bash
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

#
# PR Dependency Graph Tool
# ========================
# Analyzes open Pull Requests to determine dependency relationships,
# recommend merge order, and detect file overlaps.
#
# Usage:
#   ./scripts/pr-deps.sh [command] [options]
#
# Commands:
#   graph   Show branch dependency graph (default)
#   order   Show recommended merge order (topological sort)
#   files   Show file overlap matrix across PRs
#
# Options:
#   --author <name>      Filter by author (default: current gh user)
#   --base <branch>      Override default branch detection
#   --dot                Output graph in graphviz DOT format
#   --all                Show all open PRs regardless of author
#   --repo <owner/repo>  Target a specific repository
#   --no-color           Disable color output
#   --help               Show this help message
#

set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# --- Defaults ---
COMMAND="graph"
AUTHOR=""
BASE_BRANCH=""
DOT_OUTPUT=false
ALL_AUTHORS=false
REPO_FLAG=""
NO_COLOR=false

# --- Usage ---
usage() {
    cat <<'EOF'
PR Dependency Graph Tool

Usage:
  pr-deps.sh [command] [options]

Commands:
  graph   Show branch dependency graph (default)
  order   Show recommended merge order (topological sort)
  files   Show file overlap matrix across PRs

Options:
  --author <name>      Filter by author (default: current gh user)
  --base <branch>      Override default branch detection
  --dot                Output graph in graphviz DOT format (graph command only)
  --all                Show all open PRs regardless of author
  --repo <owner/repo>  Target a specific repository
  --no-color           Disable color output
  --help               Show this help message

Examples:
  pr-deps.sh                           # Show dependency graph for your PRs
  pr-deps.sh graph --all               # Show graph for all open PRs
  pr-deps.sh order --author octocat    # Show merge order for octocat's PRs
  pr-deps.sh files                     # Show file overlap matrix
  pr-deps.sh graph --dot | dot -Tpng -o deps.png   # Generate PNG diagram
EOF
}

# --- Color helpers ---
color() {
    if [[ "$NO_COLOR" == true ]]; then
        echo -n "$2"
    else
        echo -ne "${1}${2}${RESET}"
    fi
}

println_color() {
    if [[ "$NO_COLOR" == true ]]; then
        echo "$2"
    else
        echo -e "${1}${2}${RESET}"
    fi
}

# --- Dependency checks ---
check_deps() {
    local missing=()
    if ! command -v gh &>/dev/null; then
        missing+=("gh (GitHub CLI)")
    fi
    if ! command -v jq &>/dev/null; then
        missing+=("jq")
    fi
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Error: missing required dependencies:" >&2
        for dep in "${missing[@]}"; do
            echo "  - $dep" >&2
        done
        exit 1
    fi
}

# --- Resolve defaults ---
resolve_author() {
    if [[ -n "$AUTHOR" ]]; then
        return
    fi
    if [[ "$ALL_AUTHORS" == true ]]; then
        return
    fi
    AUTHOR=$(gh api user --jq '.login' 2>/dev/null) || {
        echo "Warning: could not detect GitHub user. Use --author or --all." >&2
        exit 1
    }
}

resolve_base_branch() {
    if [[ -n "$BASE_BRANCH" ]]; then
        return
    fi
    BASE_BRANCH=$(gh repo view $REPO_FLAG --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null) || {
        BASE_BRANCH="main"
        echo "Warning: could not detect default branch, assuming 'main'." >&2
    }
}

# --- Fetch PR data ---
# Stores raw JSON in PR_JSON global
fetch_prs() {
    local author_filter=""
    if [[ -n "$AUTHOR" ]]; then
        author_filter="--author $AUTHOR"
    fi

    PR_JSON=$(gh pr list $REPO_FLAG $author_filter \
        --state open \
        --json number,title,headRefName,baseRefName,author \
        --limit 100 2>/dev/null) || {
        echo "Error: failed to fetch PRs. Check gh authentication." >&2
        exit 1
    }

    PR_COUNT=$(echo "$PR_JSON" | jq 'length')
    if [[ "$PR_COUNT" -eq 0 ]]; then
        local scope="your"
        [[ "$ALL_AUTHORS" == true ]] && scope="any"
        [[ -n "$AUTHOR" ]] && scope="$AUTHOR's"
        echo "No open PRs found for $scope account." >&2
        exit 0
    fi
}

# --- Build dependency structures ---
# Populates associative arrays for the graph
#   PR_NUMBERS[i]       = PR number
#   PR_TITLES[number]   = PR title
#   PR_HEADS[number]    = head branch name
#   PR_BASES[number]    = base branch name
#   PR_AUTHORS[number]  = PR author login
#   CHILDREN[branch]    = space-separated list of PR numbers whose base is this branch
#   HEAD_TO_PR[branch]  = PR number whose head is this branch
declare -A PR_TITLES PR_HEADS PR_BASES PR_AUTHORS CHILDREN HEAD_TO_PR
declare -a PR_NUMBERS

build_graph() {
    local count
    count=$(echo "$PR_JSON" | jq 'length')

    for ((i = 0; i < count; i++)); do
        local num head base title author
        num=$(echo "$PR_JSON" | jq -r ".[$i].number")
        head=$(echo "$PR_JSON" | jq -r ".[$i].headRefName")
        base=$(echo "$PR_JSON" | jq -r ".[$i].baseRefName")
        title=$(echo "$PR_JSON" | jq -r ".[$i].title")
        author=$(echo "$PR_JSON" | jq -r ".[$i].author.login")

        PR_NUMBERS+=("$num")
        PR_TITLES[$num]="$title"
        PR_HEADS[$num]="$head"
        PR_BASES[$num]="$base"
        PR_AUTHORS[$num]="$author"
        HEAD_TO_PR[$head]="$num"

        # Record this PR as a child of its base branch
        if [[ -n "${CHILDREN[$base]+x}" ]]; then
            CHILDREN[$base]="${CHILDREN[$base]} $num"
        else
            CHILDREN[$base]="$num"
        fi
    done
}

# --- graph command: ASCII tree ---
render_ascii_tree() {
    local branch="$1"
    local prefix="$2"
    local is_last="$3"

    local children_str="${CHILDREN[$branch]:-}"
    if [[ -z "$children_str" ]]; then
        return
    fi

    # Convert to array
    local -a children
    read -ra children <<< "$children_str"
    local total=${#children[@]}

    for ((idx = 0; idx < total; idx++)); do
        local num="${children[$idx]}"
        local head="${PR_HEADS[$num]}"
        local title="${PR_TITLES[$num]}"
        local author_str=""
        if [[ "$ALL_AUTHORS" == true ]]; then
            author_str=" ${DIM}[${PR_AUTHORS[$num]}]${RESET}"
            [[ "$NO_COLOR" == true ]] && author_str=" [${PR_AUTHORS[$num]}]"
        fi

        local connector="├── "
        local child_prefix="${prefix}│   "
        if [[ $idx -eq $((total - 1)) ]]; then
            connector="└── "
            child_prefix="${prefix}    "
        fi

        if [[ "$NO_COLOR" == true ]]; then
            echo "${prefix}${connector}#${num} ${head} (${title})${author_str}"
        else
            echo -e "${prefix}${connector}${CYAN}#${num}${RESET} ${BOLD}${head}${RESET} ${DIM}(${title})${RESET}${author_str}"
        fi

        # Recurse into children of this PR's head branch
        render_ascii_tree "$head" "$child_prefix" "false"
    done
}

cmd_graph() {
    if [[ "$DOT_OUTPUT" == true ]]; then
        cmd_graph_dot
        return
    fi

    local scope_label="$AUTHOR"
    [[ "$ALL_AUTHORS" == true ]] && scope_label="all authors"

    println_color "$BOLD" "PR Dependency Graph (${scope_label})"
    echo ""

    # Find root branches (bases that are not any PR's head, typically the default branch)
    local -a roots=()
    for num in "${PR_NUMBERS[@]}"; do
        local base="${PR_BASES[$num]}"
        # If no PR has this base as its head, it's a root
        if [[ -z "${HEAD_TO_PR[$base]+x}" ]]; then
            # Add to roots if not already present
            local found=false
            for r in "${roots[@]+"${roots[@]}"}"; do
                if [[ "$r" == "$base" ]]; then
                    found=true
                    break
                fi
            done
            if [[ "$found" == false ]]; then
                roots+=("$base")
            fi
        fi
    done

    # Render each root tree
    for root in "${roots[@]}"; do
        if [[ "$NO_COLOR" == true ]]; then
            echo "$root"
        else
            echo -e "${GREEN}${BOLD}${root}${RESET}"
        fi
        render_ascii_tree "$root" "" "true"
        echo ""
    done
}

cmd_graph_dot() {
    echo "digraph pr_dependencies {"
    echo "  rankdir=LR;"
    echo "  node [shape=box, style=rounded];"
    echo ""

    # Add nodes
    for num in "${PR_NUMBERS[@]}"; do
        local head="${PR_HEADS[$num]}"
        local title="${PR_TITLES[$num]}"
        # Escape quotes in title
        title="${title//\"/\\\"}"
        echo "  \"${head}\" [label=\"#${num}: ${title}\"];"
    done
    echo ""

    # Add the default branch node
    echo "  \"${BASE_BRANCH}\" [label=\"${BASE_BRANCH}\", style=\"filled,rounded\", fillcolor=\"#90EE90\"];"
    echo ""

    # Add edges
    for num in "${PR_NUMBERS[@]}"; do
        local head="${PR_HEADS[$num]}"
        local base="${PR_BASES[$num]}"
        echo "  \"${base}\" -> \"${head}\";"
    done

    echo "}"
}

# --- order command: topological sort ---
cmd_order() {
    local scope_label="$AUTHOR"
    [[ "$ALL_AUTHORS" == true ]] && scope_label="all authors"

    println_color "$BOLD" "Recommended Merge Order (${scope_label})"
    echo ""

    # Kahn's algorithm for topological sort
    # In-degree: how many PRs must merge before this one
    declare -A in_degree
    for num in "${PR_NUMBERS[@]}"; do
        in_degree[$num]=0
    done

    # Build dependency: if PR_B's base == PR_A's head, then B depends on A
    declare -A depends_on  # depends_on[B] = "A1 A2 ..."
    declare -A blocks      # blocks[A] = "B1 B2 ..."
    for num in "${PR_NUMBERS[@]}"; do
        local base="${PR_BASES[$num]}"
        if [[ -n "${HEAD_TO_PR[$base]+x}" ]]; then
            local dep="${HEAD_TO_PR[$base]}"
            in_degree[$num]=$(( ${in_degree[$num]} + 1 ))
            if [[ -n "${blocks[$dep]+x}" ]]; then
                blocks[$dep]="${blocks[$dep]} $num"
            else
                blocks[$dep]="$num"
            fi
        fi
    done

    # BFS: start with PRs that have no dependencies (in_degree == 0)
    local -a queue=()
    for num in "${PR_NUMBERS[@]}"; do
        if [[ ${in_degree[$num]} -eq 0 ]]; then
            queue+=("$num")
        fi
    done

    local step=1
    local -a sorted=()
    local -a processing=("${queue[@]}")

    while [[ ${#processing[@]} -gt 0 ]]; do
        local -a next_queue=()
        for num in "${processing[@]}"; do
            sorted+=("$num")
            local base="${PR_BASES[$num]}"
            local head="${PR_HEADS[$num]}"
            local title="${PR_TITLES[$num]}"

            if [[ "$NO_COLOR" == true ]]; then
                echo "  ${step}. #${num} ${head} -> ${base} (${title})"
            else
                echo -e "  ${BOLD}${step}.${RESET} ${CYAN}#${num}${RESET} ${head} ${DIM}->${RESET} ${GREEN}${base}${RESET} ${DIM}(${title})${RESET}"
            fi
            step=$((step + 1))

            # Reduce in-degree for PRs blocked by this one
            local blocked_str="${blocks[$num]:-}"
            if [[ -n "$blocked_str" ]]; then
                local -a blocked
                read -ra blocked <<< "$blocked_str"
                for b in "${blocked[@]}"; do
                    in_degree[$b]=$(( ${in_degree[$b]} - 1 ))
                    if [[ ${in_degree[$b]} -eq 0 ]]; then
                        next_queue+=("$b")
                    fi
                done
            fi
        done
        processing=("${next_queue[@]+"${next_queue[@]}"}")
    done

    # Check for cycles
    if [[ ${#sorted[@]} -ne ${#PR_NUMBERS[@]} ]]; then
        echo ""
        println_color "$RED" "Warning: circular dependency detected! The following PRs form a cycle:"
        for num in "${PR_NUMBERS[@]}"; do
            local found=false
            for s in "${sorted[@]}"; do
                if [[ "$s" == "$num" ]]; then
                    found=true
                    break
                fi
            done
            if [[ "$found" == false ]]; then
                echo "  #${num} ${PR_HEADS[$num]} -> ${PR_BASES[$num]}"
            fi
        done
    fi
}

# --- files command: file overlap matrix ---
cmd_files() {
    local scope_label="$AUTHOR"
    [[ "$ALL_AUTHORS" == true ]] && scope_label="all authors"

    println_color "$BOLD" "File Overlap Analysis (${scope_label})"
    echo ""

    if [[ $PR_COUNT -gt 20 ]]; then
        println_color "$YELLOW" "Warning: fetching file lists for $PR_COUNT PRs, this may take a moment..."
    fi

    # Fetch files for each PR
    declare -A PR_FILES  # PR_FILES[number] = newline-separated file paths
    for num in "${PR_NUMBERS[@]}"; do
        local files_json
        files_json=$(gh pr view "$num" $REPO_FLAG --json files --jq '.files[].path' 2>/dev/null) || {
            PR_FILES[$num]=""
            continue
        }
        PR_FILES[$num]="$files_json"
    done

    # Find overlaps between each pair
    local found_overlap=false
    for ((i = 0; i < ${#PR_NUMBERS[@]}; i++)); do
        for ((j = i + 1; j < ${#PR_NUMBERS[@]}; j++)); do
            local num_a="${PR_NUMBERS[$i]}"
            local num_b="${PR_NUMBERS[$j]}"
            local files_a="${PR_FILES[$num_a]}"
            local files_b="${PR_FILES[$num_b]}"

            if [[ -z "$files_a" || -z "$files_b" ]]; then
                continue
            fi

            # Find common files
            local common
            common=$(comm -12 <(echo "$files_a" | sort) <(echo "$files_b" | sort))

            if [[ -n "$common" ]]; then
                found_overlap=true
                local count
                count=$(echo "$common" | wc -l | tr -d ' ')

                if [[ "$NO_COLOR" == true ]]; then
                    echo "#${num_a} (${PR_HEADS[$num_a]}) <-> #${num_b} (${PR_HEADS[$num_b]}): ${count} shared file(s)"
                else
                    echo -e "${CYAN}#${num_a}${RESET} (${PR_HEADS[$num_a]}) ${YELLOW}<->${RESET} ${CYAN}#${num_b}${RESET} (${PR_HEADS[$num_b]}): ${BOLD}${count}${RESET} shared file(s)"
                fi
                echo "$common" | while read -r f; do
                    echo "    $f"
                done
                echo ""
            fi
        done
    done

    if [[ "$found_overlap" == false ]]; then
        println_color "$GREEN" "No file overlaps detected between PRs."
    fi
}

# --- Parse arguments ---
parse_args() {
    local positional_set=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            graph|order|files)
                if [[ "$positional_set" == false ]]; then
                    COMMAND="$1"
                    positional_set=true
                else
                    echo "Error: unexpected argument '$1'" >&2
                    exit 1
                fi
                shift
                ;;
            --author)
                AUTHOR="${2:?--author requires a value}"
                shift 2
                ;;
            --base)
                BASE_BRANCH="${2:?--base requires a value}"
                shift 2
                ;;
            --dot)
                DOT_OUTPUT=true
                shift
                ;;
            --all)
                ALL_AUTHORS=true
                shift
                ;;
            --repo)
                REPO_FLAG="--repo ${2:?--repo requires a value}"
                shift 2
                ;;
            --no-color)
                NO_COLOR=true
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                echo "Error: unknown option '$1'" >&2
                echo "Run 'pr-deps.sh --help' for usage." >&2
                exit 1
                ;;
        esac
    done
}

# --- Main ---
main() {
    parse_args "$@"
    check_deps
    resolve_author
    resolve_base_branch
    fetch_prs
    build_graph

    case "$COMMAND" in
        graph) cmd_graph ;;
        order) cmd_order ;;
        files) cmd_files ;;
    esac
}

main "$@"
