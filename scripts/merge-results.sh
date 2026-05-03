#!/bin/bash

# Merge parallel group outputs and update history.db (source of truth)

set -e

echo "Merging results from all groups..."
python3 "$(dirname "$0")/merge_results.py"
