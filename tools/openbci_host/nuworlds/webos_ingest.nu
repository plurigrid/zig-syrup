#!/usr/bin/env nu

# webos_ingest.nu
# Streams WebOS legacy data into local DuckDB

def main [] {
    let db_path = "webos_legacy.duckdb"
    let script_path = ($env.FILE_PWD | path join "webos_legacy_stream.py")

    print $"Initializing database at ($db_path)..."
    
    # Define table
    duckdb $db_path "CREATE TABLE IF NOT EXISTS repos (
        type VARCHAR, 
        name VARCHAR, 
        description VARCHAR, 
        stars INTEGER, 
        created TIMESTAMP, 
        updated TIMESTAMP,
        language VARCHAR,
        topics VARCHAR[],
        legacy_score INTEGER
    );"

    print "Streaming WebOS legacy data..."
    
    try {
        python3 $script_path | duckdb $db_path "INSERT INTO repos SELECT * FROM read_json_auto('/dev/stdin')"
    } catch {
        print "Error during ingestion."
    }

    print "Ingestion complete."
    
    # Analysis
    print "\nTop WebOS Repositories by Stars:"
    duckdb $db_path "SELECT name, stars, language, created FROM repos ORDER BY stars DESC LIMIT 5" | from csv | print

    print "\nOldest 'Legacy' Repositories:"
    duckdb $db_path "SELECT name, created, description FROM repos ORDER BY created ASC LIMIT 5" | from csv | print
}
