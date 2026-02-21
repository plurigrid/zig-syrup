#!/usr/bin/env nu

# duckdb_find.nu
# Discover, catalog, and query all DuckDB files across ~/i/
# Part of Nuworlds

const DUCKDB_BIN = "/Users/bob/.topos/.flox/run/aarch64-darwin.topos.run/bin/duckdb"
const CATALOG_DB = "/Users/bob/i/zig-syrup/tools/openbci_host/nuworlds/duckdb_catalog.duckdb"

def run-duckdb [db: string, sql: string, fmt: string = ""] {
    let args = if $fmt == "" { [$db $sql] } else { [$db $sql $fmt] }
    let result = (do { ^$DUCKDB_BIN ...$args } | complete)
    if $result.exit_code != 0 { return "" }
    $result.stdout | str trim
}

# Discover all .duckdb files under search root
export def "duckdb find" [
    --root: string = "/Users/bob/i"
    --max-depth: int = 5
] {
    glob $"($root)/**/*.duckdb" --depth $max_depth
    | where ($it | path basename) != "duckdb_catalog.duckdb"
    | each {|path|
        let stat = (ls -l $path | first)
        {
            path: $path
            name: ($path | path basename | str replace ".duckdb" "")
            size_kb: (($stat.size | into int) / 1024)
            modified: $stat.modified
            relative: ($path | str replace $root "" | str trim -c "/")
        }
    }
    | sort-by size_kb -r
}

# Show tables in a duckdb file
export def "duckdb tables" [
    db_path: string
] {
    let raw = (run-duckdb $db_path "SHOW TABLES;" "--csv")
    if ($raw | is-empty) { return [] }
    $raw | from csv | rename table_name
}

# Describe schema of a table
export def "duckdb schema" [
    db_path: string
    table: string
] {
    let raw = (run-duckdb $db_path $"DESCRIBE ($table);" "--csv")
    if ($raw | is-empty) { return [] }
    $raw | from csv
}

# Query any duckdb file with SQL
export def "duckdb query" [
    db_path: string
    sql: string
    --format: string = "table"
] {
    match $format {
        "csv" => { run-duckdb $db_path $sql "--csv" }
        "json" => {
            let raw = (run-duckdb $db_path $sql "--json")
            if ($raw | is-empty) { return [] }
            $raw | from json
        }
        _ => { run-duckdb $db_path $sql }
    }
}

# Search across ALL duckdb files for a table name pattern
export def "duckdb search-tables" [
    pattern: string
    --root: string = "/Users/bob/i"
] {
    duckdb find --root $root
    | each {|db|
        let tables = (duckdb tables $db.path)
        if ($tables | is-empty) { return [] }
        $tables
        | where {|row| ($row.table_name | str downcase) =~ ($pattern | str downcase) }
        | each {|t| { db_name: $db.name, db_path: $db.path, table: $t.table_name, db_size_kb: $db.size_kb } }
    }
    | flatten
}

# Search for text inside table data across all duckdb files
export def "duckdb grep" [
    pattern: string
    --root: string = "/Users/bob/i"
    --limit: int = 5
] {
    duckdb find --root $root
    | each {|db|
        let tables = (duckdb tables $db.path)
        if ($tables | is-empty) { return [] }
        $tables
        | each {|t|
            let cols_raw = (run-duckdb $db.path $"SELECT column_name FROM information_schema.columns WHERE table_name = '($t.table_name)' AND data_type IN \('VARCHAR', 'TEXT'\);" "--csv")
            if ($cols_raw | is-empty) { return [] }
            let cols = ($cols_raw | from csv | get column_name)
            if ($cols | is-empty) { return [] }

            let where_clause = ($cols | each {|c| $"\"($c)\" ILIKE '%($pattern)%'"} | str join " OR ")
            let sql = $"SELECT * FROM \"($t.table_name)\" WHERE ($where_clause) LIMIT ($limit);"

            let result = (run-duckdb $db.path $sql "--json")
            if ($result | is-empty) or ($result == "[]") { return [] }

            { db_name: $db.name, db_path: $db.path, table: $t.table_name, matches: ($result | from json) }
        }
    }
    | flatten
    | where ($it | is-not-empty)
}

# Build a catalog database indexing all duckdb files and their tables
export def "duckdb catalog" [
    --root: string = "/Users/bob/i"
    --output: string = "/Users/bob/i/zig-syrup/tools/openbci_host/nuworlds/duckdb_catalog.duckdb"
] {
    run-duckdb $output "
        CREATE OR REPLACE TABLE databases (
            path VARCHAR PRIMARY KEY,
            name VARCHAR,
            size_kb BIGINT,
            relative_path VARCHAR
        );
        CREATE OR REPLACE TABLE tables_index (
            db_path VARCHAR,
            table_name VARCHAR,
            PRIMARY KEY (db_path, table_name)
        );
    "

    let dbs = (duckdb find --root $root)
    print $"Cataloging ($dbs | length) DuckDB files..."

    mut table_total = 0

    for db in $dbs {
        run-duckdb $output $"INSERT OR REPLACE INTO databases VALUES \('($db.path)', '($db.name)', ($db.size_kb), '($db.relative)'\);"

        let tables = (duckdb tables $db.path)
        for t in $tables {
            run-duckdb $output $"INSERT OR REPLACE INTO tables_index VALUES \('($db.path)', '($t.table_name)'\);"
            $table_total = $table_total + 1
        }
    }

    print $"Done: ($dbs | length) databases, ($table_total) tables -> ($output)"
}

# Query the catalog
export def "duckdb catalog-query" [
    sql: string
] {
    run-duckdb $CATALOG_DB $sql
}

# Quick summary of duckdb universe
export def "duckdb universe" [
    --root: string = "/Users/bob/i"
] {
    let dbs = (duckdb find --root $root)
    let total_mb = (($dbs | get size_kb | math sum) / 1024)

    print $"DuckDB Universe: ($dbs | length) databases, ($total_mb) MB total"
    print ""
    print "Top 15 by size:"
    $dbs | first 15 | select name size_kb relative | print
    print ""
    print "Most recently modified:"
    $dbs | sort-by modified -r | first 10 | select name modified relative | print
}
