#!/usr/bin/env bash
# L'unico pannello che rende visibile la storia del coordinatore.
cd "$(dirname "$0")/../../deploy"
exec docker compose --env-file .env.demo logs -f --tail=0 coord1 coord2 coord3 \
  | grep --line-buffered -Ei 'election|rebuild|quorum|leader|serving|standby|nodedown|went down'
