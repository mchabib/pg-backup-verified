#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  source "$ROOT/lib/common.sh"
  source "$ROOT/lib/manifest.sh"
  DIR="$(mktemp -d)"
  LOG_DIR=""
  EXPECTED=$'version\t1\nsha256\tabc\ndb\tapp\t3\nrows\tapp\tpublic.orders\t1000\nrows\tapp\tpublic.users\t50\ndb\tpostgres\t0'
}

teardown() {
  rm -rf "$DIR"
}

@test "write_manifest records the file checksum" {
  echo "hello" > "$DIR/b.sql.gz"
  write_manifest "$DIR/b.sql.gz" $'db\tapp\t1'
  run manifest_get "$DIR/b.sql.gz.manifest" sha256
  [ "$output" = "$(sha256sum "$DIR/b.sql.gz" | cut -d' ' -f1)" ]
  grep -q $'^db\tapp\t1$' "$DIR/b.sql.gz.manifest"
}

@test "verify_checksum passes on an untouched file" {
  echo "hello" > "$DIR/b.sql.gz"
  write_manifest "$DIR/b.sql.gz" ""
  run verify_checksum "$DIR/b.sql.gz"
  [ "$status" -eq 0 ]
}

@test "verify_checksum fails after a single byte changes" {
  echo "hello" > "$DIR/b.sql.gz"
  write_manifest "$DIR/b.sql.gz" ""
  printf 'x' | dd of="$DIR/b.sql.gz" bs=1 seek=0 conv=notrunc 2>/dev/null
  run verify_checksum "$DIR/b.sql.gz"
  [ "$status" -eq 1 ]
  [[ "$output" == checksum\ mismatch* ]]
}

@test "compare_stats accepts identical stats" {
  run compare_stats "$EXPECTED" "$EXPECTED" 5
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "compare_stats accepts row drift within tolerance" {
  actual="${EXPECTED/1000/1040}"
  run compare_stats "$EXPECTED" "$actual" 5
  [ "$status" -eq 0 ]
}

@test "compare_stats rejects row drift beyond tolerance" {
  actual="${EXPECTED/1000/900}"
  run compare_stats "$EXPECTED" "$actual" 5
  [ "$status" -eq 1 ]
  [[ "$output" == *"row count off in app public.orders: expected 1000, got 900"* ]]
}

@test "compare_stats reports a missing database" {
  actual=$'db\tpostgres\t0'
  run compare_stats "$EXPECTED" "$actual" 5
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing database: app"* ]]
}

@test "compare_stats reports a missing table" {
  actual="$(grep -v users <<< "$EXPECTED")"
  run compare_stats "$EXPECTED" "$actual" 5
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing table: app public.users"* ]]
}

@test "compare_stats reports a different table count" {
  actual="${EXPECTED/$'db\tapp\t3'/$'db\tapp\t2'}"
  run compare_stats "$EXPECTED" "$actual" 5
  [ "$status" -eq 1 ]
  [[ "$output" == *"table count differs in app: expected 3, got 2"* ]]
}
