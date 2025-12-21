#!/bin/bash
set -e

# hack/setup.sh - Setup isolated test environment

REPO_ROOT=$(pwd)
TEST_DIR="${REPO_ROOT}/../gswarm-qa-temp"

echo "=== Setting up test environment in ${TEST_DIR} ==="

rm -rf "${TEST_DIR}"
mkdir -p "${TEST_DIR}"

# git init -q

echo "=== Building gswarm binary ==="
go build -o "${TEST_DIR}/gswarm" .

cd "${TEST_DIR}"
echo "=== Initializing gswarm ==="
./gswarm init

echo "=== Setup Complete ==="
ls -A1 .gswarm
