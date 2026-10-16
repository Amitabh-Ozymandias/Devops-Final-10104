#!/bin/sh
set -e

# Wait for the database and apply migrations before serving traffic.
# Retries cover the window where PostgreSQL is still starting up.
attempt=1
max_attempts="${MIGRATION_MAX_ATTEMPTS:-30}"
until alembic upgrade head; do
  if [ "$attempt" -ge "$max_attempts" ]; then
    echo "Database migrations failed after $attempt attempts" >&2
    exit 1
  fi
  echo "Migration attempt $attempt failed; retrying in 2s..."
  attempt=$((attempt + 1))
  sleep 2
done

exec "$@"
