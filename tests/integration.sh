#!/usr/bin/env bash
# End-to-end test (also the demo): needs only Docker on the host.
#
#   source PostgreSQL + pgbench data
#   -> backup_dumpall.sh (run inside a postgres client container)
#   -> restore_drill.sh must PASS
#   -> a corrupted copy must FAIL on checksum
#   -> a tampered manifest must FAIL on row counts
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${PG_IMAGE:-postgres:16}"
NET="pgbv-it-$$"
SRC="pgbv-src-$$"
WORK="$(mktemp -d)"

cleanup() {
  docker rm -f "$SRC" &>/dev/null || true
  docker network rm "$NET" &>/dev/null || true
  rm -rf -- "$WORK" 2>/dev/null || docker run --rm -v "$WORK:/w" "$IMAGE" rm -rf /w/backups /w/logs || true
  rm -rf -- "$WORK" 2>/dev/null || true
}
trap cleanup EXIT

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

step "Start source PostgreSQL with sample data"
docker network create "$NET" >/dev/null
docker run -d --name "$SRC" --network "$NET" -e POSTGRES_PASSWORD=secret "$IMAGE" >/dev/null
for _ in $(seq 1 60); do
  docker exec "$SRC" pg_isready -U postgres -q && docker exec "$SRC" psql -U postgres -Atqc 'SELECT 1' &>/dev/null && break
  sleep 1
done
docker exec "$SRC" psql -U postgres -qc 'CREATE DATABASE shop'
docker exec "$SRC" pgbench -U postgres -i -s 2 -q shop
docker exec "$SRC" psql -U postgres -d shop -qc \
  "CREATE TABLE customers(id serial primary key, name text);
   INSERT INTO customers(name) SELECT 'c' || g FROM generate_series(1, 5000) g;"

cat > "$WORK/.env" <<EOF
PGHOST=$SRC
PGUSER=postgres
PGPASSWORD=secret
BACKUP_ROOT_DIR=/work/backups
LOG_DIR=/work/logs
SERVER_LABEL=it
DRILL_IMAGE=$IMAGE
EOF

step "Run backup_dumpall.sh"
docker run --rm --network "$NET" -u "$(id -u):$(id -g)" \
  -v "$ROOT:/app:ro" -v "$WORK:/work" -e PGBV_ENV_FILE=/work/.env \
  "$IMAGE" bash /app/backup_dumpall.sh

BACKUP="$(ls "$WORK"/backups/dumpall/*.sql.gz)"
echo "--- manifest"; cat "$BACKUP.manifest"

# The drill runs on the host and talks to Docker directly; map paths back.
sed -e "s#/work#$WORK#g" "$WORK/.env" > "$WORK/host.env"
export PGBV_ENV_FILE="$WORK/host.env"

step "Restore drill on the good backup: expect PASS"
"$ROOT/restore_drill.sh" "$BACKUP"

step "Corrupted copy: expect FAIL"
cp "$BACKUP" "$WORK/backups/dumpall/bad.sql.gz"
cp "$BACKUP.manifest" "$WORK/backups/dumpall/bad.sql.gz.manifest"
printf 'x' | dd of="$WORK/backups/dumpall/bad.sql.gz" bs=1 seek=100 conv=notrunc 2>/dev/null
if "$ROOT/restore_drill.sh" "$WORK/backups/dumpall/bad.sql.gz"; then
  echo "expected the drill to fail on a corrupted file" >&2; exit 1
fi

step "Tampered manifest (row count): expect FAIL"
cp "$BACKUP" "$WORK/backups/dumpall/tamper.sql.gz"
awk -F'\t' -v OFS='\t' '$1 == "rows" && $3 == "public.customers" { $4 = 9999 } { print }' \
  "$BACKUP.manifest" > "$WORK/backups/dumpall/tamper.sql.gz.manifest"
# keep the checksum valid so only the content check can catch it
if "$ROOT/restore_drill.sh" "$WORK/backups/dumpall/tamper.sql.gz"; then
  echo "expected the drill to fail on a row-count mismatch" >&2; exit 1
fi

step "All integration checks passed"
