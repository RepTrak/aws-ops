#!/usr/bin/env bash
# Thin wrapper — delegates to export-scripts/export-eks.sh
exec "$(dirname "$0")/export-scripts/export-eks.sh" "$@"
