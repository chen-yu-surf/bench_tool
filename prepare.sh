#!/bin/bash
# Prepare benchmark tools: clone and build hackbench and schbench
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Clone rt-tests (contains hackbench)
if [ ! -d "${SCRIPT_DIR}/rt-tests" ]; then
    echo "Cloning rt-tests (hackbench) ..."
    git clone https://github.com/vianpl/rt-tests.git "${SCRIPT_DIR}/rt-tests"
else
    echo "rt-tests already exists, skipping clone."
fi

# Clone schbench
if [ ! -d "${SCRIPT_DIR}/schbench" ]; then
    echo "Cloning schbench ..."
    git clone https://git.kernel.org/pub/scm/linux/kernel/git/mason/schbench.git "${SCRIPT_DIR}/schbench"
else
    echo "schbench already exists, skipping clone."
fi

# Build hackbench
echo "Building hackbench ..."
make -C "${SCRIPT_DIR}/rt-tests" hackbench

# Build schbench
echo "Building schbench ..."
make -C "${SCRIPT_DIR}/schbench"

echo "Done. Both hackbench and schbench are ready."
