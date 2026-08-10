#!/bin/bash
cd "$(dirname "$0")/.."
docker compose down -v --timeout 3 2>/dev/null
echo "环境已清理"
