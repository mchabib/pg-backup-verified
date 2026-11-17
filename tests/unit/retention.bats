#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  source "$ROOT/lib/common.sh"
  source "$ROOT/lib/retention.sh"
  DIR="$(mktemp -d)"
  LOG_DIR=""
}

teardown() {
  rm -rf "$DIR"
}

aged() { # aged <name> <days-old>
  touch "$DIR/$1"
  touch -d "$2 days ago" "$DIR/$1"
}

@test "latest_backup picks the newest matching file" {
  aged a_1.sql.gz 3
  aged b_2.sql.gz 1
  aged c_3.sql.gz 2
  aged z.txt 0
  run latest_backup "$DIR" '*.sql.gz'
  [ "$status" -eq 0 ]
  [ "$output" = "$DIR/b_2.sql.gz" ]
}

@test "latest_backup prints nothing for a missing directory" {
  run latest_backup "$DIR/nope" '*.sql.gz'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "age_hours counts whole hours since modification" {
  touch -d '@1700000000' "$DIR/f"
  run age_hours "$DIR/f" $((1700000000 + 3 * 3600 + 59))
  [ "$output" = "3" ]
}

@test "cleanup removes backups older than the retention window" {
  aged old.sql.gz 10
  aged old.sql.gz.manifest 10
  aged new.sql.gz 1
  aged new.sql.gz.manifest 1
  cleanup_old_backups "$DIR" 7 >/dev/null
  [ ! -e "$DIR/old.sql.gz" ]
  [ ! -e "$DIR/old.sql.gz.manifest" ]
  [ -e "$DIR/new.sql.gz" ]
  [ -e "$DIR/new.sql.gz.manifest" ]
}

@test "cleanup always keeps the newest backup and its manifest even if expired" {
  aged a.sql.gz 30
  aged a.sql.gz.manifest 30
  aged b.sql.gz 20
  aged b.sql.gz.manifest 20
  cleanup_old_backups "$DIR" 7 >/dev/null
  [ ! -e "$DIR/a.sql.gz" ]
  [ -e "$DIR/b.sql.gz" ]
  [ -e "$DIR/b.sql.gz.manifest" ]
}

@test "cleanup without arguments is a no-op" {
  aged a.sql.gz 30
  run cleanup_old_backups "" ""
  [ "$status" -eq 0 ]
  [ -e "$DIR/a.sql.gz" ]
}
