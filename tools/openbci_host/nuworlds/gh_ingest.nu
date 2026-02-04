#!/usr/bin/env nu

# gh_ingest.nu
# Streams GitHub interactions via GraphQL into local DuckDB
# Part of Nuworlds

def main [] {
    let db_path = "gh_social.duckdb"
    let script_path = ($env.FILE_PWD | path join "gh_stream.py")

    print $"Initializing database at ($db_path)..."
    
    # Ensure table exists
    # We use a permissive schema or let DuckDB infer on first load if we drop table.
    # For stability, let's define it.
    duckdb $db_path "CREATE TABLE IF NOT EXISTS interactions (
        type VARCHAR, 
        login VARCHAR, 
        repo VARCHAR, 
        interaction VARCHAR, 
        title VARCHAR, 
        date TIMESTAMP
    );"

    print "Starting GitHub GraphQL stream..."
    
    # Execute python script and pipe to DuckDB
    # We use 'read_json_auto' reading from stdin (/dev/stdin)
    
    try {
        python3 $script_path | duckdb $db_path "INSERT INTO interactions SELECT * FROM read_json_auto('/dev/stdin')"
    } catch {
        print "Error during ingestion. Check API limits or network."
    }

    print "Ingestion complete."
    
    # Summary
    let summary = (duckdb $db_path "SELECT interaction, count(*) as count FROM interactions GROUP BY interaction" | from csv)
    print $summary
    
    let top_authors = (duckdb $db_path "SELECT login, count(*) as count FROM interactions GROUP BY login ORDER BY count DESC LIMIT 5" | from csv)
    print "Top Authors:"
    print $top_authors
}
