#!/usr/bin/env python3
"""
Scan bmorphism's following for Swift-based accounts.
Uses per-user GraphQL queries to get top repos by language.
"""
import subprocess, json, sys, time

def get_following_logins():
    """Get all logins from the already-fetched NDJSON."""
    logins = []
    with open("/Users/bob/i/zig-syrup/tools/openbci_host/nuworlds/bmorphism_following.ndjson") as f:
        for line in f:
            rec = json.loads(line)
            logins.append(rec["login"])
    return logins

def check_user_swift(login):
    """Check if a user has Swift repos in their top repos."""
    query = '''{{
      user(login: "{login}") {{
        repositories(first: 6, orderBy: {{field: STARGAZERS, direction: DESC}}) {{
          nodes {{
            name
            stargazerCount
            primaryLanguage {{ name }}
            description
          }}
        }}
      }}
    }}'''.format(login=login)
    
    result = subprocess.run(
        ["gh", "api", "graphql", "-f", f"query={query}"],
        capture_output=True, text=True, timeout=15
    )
    if result.returncode != 0:
        return None
    try:
        data = json.loads(result.stdout)
        repos = data.get("data", {}).get("user", {}).get("repositories", {}).get("nodes", [])
        swift_repos = [r for r in repos if r.get("primaryLanguage") and r["primaryLanguage"].get("name") == "Swift"]
        if swift_repos:
            return {
                "login": login,
                "swift_repos": [
                    {"name": r["name"], "stars": r["stargazerCount"], "desc": (r.get("description") or "")[:80]}
                    for r in swift_repos
                ],
                "all_repos": [
                    {"name": r["name"], "stars": r["stargazerCount"], "lang": (r.get("primaryLanguage") or {}).get("name", "?")}
                    for r in repos
                ]
            }
    except:
        pass
    return None

def main():
    logins = get_following_logins()
    print(f"Scanning {len(logins)} accounts for Swift repos...", file=sys.stderr)
    
    swift_users = []
    for i, login in enumerate(logins):
        if i % 50 == 0 and i > 0:
            print(f"  ...{i}/{len(logins)} scanned, {len(swift_users)} Swift accounts found", file=sys.stderr)
        result = check_user_swift(login)
        if result:
            swift_users.append(result)
            # Also get follower count from our existing data
            print(f"  SWIFT: {login} ({len(result['swift_repos'])} Swift repos)", file=sys.stderr)
    
    print(f"\nTotal Swift accounts: {len(swift_users)}", file=sys.stderr)
    
    # Enrich with follower data from parquet
    import polars as pl
    df = pl.read_parquet("/Users/bob/i/zig-syrup/tools/openbci_host/nuworlds/bmorphism_following.parquet")
    
    for u in swift_users:
        row = df.filter(pl.col("login") == u["login"])
        if len(row) > 0:
            u["followers"] = row["followers"][0]
            u["name"] = row["name"][0]
            u["company"] = row["company"][0]
            u["bio"] = row["bio"][0]
            u["bucket"] = row["bucket"][0]
        else:
            u["followers"] = 0
            u["name"] = ""
            u["company"] = ""
            u["bio"] = ""
            u["bucket"] = "?"
    
    # Sort by followers descending
    swift_users.sort(key=lambda x: x["followers"], reverse=True)
    
    # Output
    print(json.dumps(swift_users, indent=2))

if __name__ == "__main__":
    main()
