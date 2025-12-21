#!/bin/bash
# hack/cleanup.sh - Cleanup agents and test directory

REPO_ROOT=$(pwd)
TEST_DIR="${REPO_ROOT}/../gswarm-qa-temp"

echo "=== Cleaning up agents ==="

# Stop all agents started by gswarm
if [ -f "${TEST_DIR}/gswarm" ]; then
    AGENTS=$("${TEST_DIR}/gswarm" list | tail -n +2 | awk '{print $1}')
    for agent in $AGENTS; do
        if [ -n "$agent" ]; then
            "${TEST_DIR}/gswarm" stop "$agent"
        fi
    done
fi

# Fallback for Apple container
# if command -v container &> /dev/null; then
#     IDS=$(container list -a --format json | grep '"gswarm.agent":"true"' -B 20 | grep '"id":' | cut -d'"' -f4)
#     for id in $IDS; do
#         container stop "$id" || true
#         container rm "$id" || true
#     done
# fi

# Delete contents but keep the directory
echo "=== Cleaning up test directory contents ==="
if [ -d "${TEST_DIR}" ]; then
    find "${TEST_DIR}" -mindepth 1 -delete
fi

echo "=== Cleanup Complete ==="
