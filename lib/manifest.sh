#!/usr/bin/env bash
# Backup manifests: what a backup should contain, recorded when it was taken,
# so a restore drill can prove the restored copy matches.
#
# Format (<backup>.manifest, tab-separated, one record per line):
#   version   1
#   sha256    <hex>
#   created   <ISO-8601>
#   db        <name>   <user table count>
#   rows      <db>     <schema.table>   <exact row count>

MANIFEST_VERSION=1

# psql_q <db> <sql>  -> unaligned, tab-separated rows, no headers
psql_q() {
  psql -X -At -F $'\t' -v ON_ERROR_STOP=1 -d "$1" -c "$2"
}

list_databases() {
  psql_q postgres "SELECT datname FROM pg_database
                   WHERE datallowconn AND NOT datistemplate ORDER BY 1"
}

# collect_stats <table_limit>  -> db/rows records for every database
collect_stats() {
  local limit="$1" db tables tbl count
  while IFS= read -r db; do
    tables="$(psql_q "$db" "SELECT count(*) FROM pg_stat_user_tables")"
    printf 'db\t%s\t%s\n' "$db" "$tables"
    # Largest tables by estimate, then exact counts for just those
    while IFS= read -r tbl; do
      [[ -n "$tbl" ]] || continue
      count="$(psql_q "$db" "SELECT count(*) FROM $tbl")"
      printf 'rows\t%s\t%s\t%s\n' "$db" "$tbl" "$count"
    done < <(psql_q "$db" "SELECT format('%I.%I', schemaname, relname)
                           FROM pg_stat_user_tables
                           ORDER BY n_live_tup DESC, 1 LIMIT $limit")
  done < <(list_databases)
}

# write_manifest <backup_file> <stats_text>
write_manifest() {
  local file="$1" stats="$2"
  {
    printf 'version\t%s\n' "$MANIFEST_VERSION"
    printf 'sha256\t%s\n' "$(sha256sum -- "$file" | cut -d' ' -f1)"
    printf 'created\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '%s\n' "$stats"
  } > "$file.manifest"
}

# manifest_get <manifest> <key>  -> first value for key
manifest_get() {
  awk -F'\t' -v k="$2" '$1 == k { print $2; exit }' "$1"
}

# verify_checksum <backup_file>  (uses <backup_file>.manifest)
verify_checksum() {
  local file="$1" expected actual
  expected="$(manifest_get "$file.manifest" sha256)"
  [[ -n "$expected" ]] || { echo "manifest has no sha256"; return 1; }
  actual="$(sha256sum -- "$file" | cut -d' ' -f1)"
  if [[ "$expected" != "$actual" ]]; then
    echo "checksum mismatch: expected $expected, got $actual"
    return 1
  fi
}

# compare_stats <expected_stats> <actual_stats> <tolerance_pct>
# Prints one line per problem; returns 1 if any.
#  - every expected database must exist with the same user table count
#  - every expected table must exist; row counts may differ by tolerance_pct,
#    because pg_dumpall does not take one snapshot across databases and the
#    counts were taken right after the dump on a live server.
compare_stats() {
  local expected="$1" actual="$2" tol="$3"
  awk -F'\t' -v tol="$tol" '
    NR == FNR {
      if ($1 == "db")   adb[$2] = $3
      if ($1 == "rows") arow[$2 SUBSEP $3] = $4
      next
    }
    $1 == "db" {
      if (!($2 in adb))          { printf "missing database: %s\n", $2; bad = 1 }
      else if (adb[$2] != $3)    { printf "table count differs in %s: expected %s, got %s\n", $2, $3, adb[$2]; bad = 1 }
    }
    $1 == "rows" {
      k = $2 SUBSEP $3
      if (!(k in arow))          { printf "missing table: %s %s\n", $2, $3; bad = 1; next }
      want = $4 + 0; got = arow[k] + 0
      diff = want - got; if (diff < 0) diff = -diff
      if (diff > want * tol / 100) { printf "row count off in %s %s: expected %d, got %d (tolerance %s%%)\n", $2, $3, want, got, tol; bad = 1 }
    }
    END { exit bad }
  ' <(printf '%s\n' "$actual") <(printf '%s\n' "$expected")
}
