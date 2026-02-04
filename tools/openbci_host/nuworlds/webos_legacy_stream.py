#!/usr/bin/env python3
import sys
import json
import subprocess
import time

def run_query(query, variables=None):
    cmd = ["gh", "api", "graphql", "-f", f"query={query}"]
    if variables:
        for k, v in variables.items():
            cmd.extend(["-F", f"{k}={v}"])
    
    for _ in range(3):
        try:
            res = subprocess.run(cmd, capture_output=True, text=True)
            if res.returncode == 0:
                return json.loads(res.stdout)
            if "RATE_LIMITED" in res.stderr:
                time.sleep(5)
                continue
        except Exception:
            pass
        time.sleep(1)
    return None

def main():
    print("Searching for WebOS legacy...", file=sys.stderr)
    
    # Search query for "webos"
    search_query = """
    query($query: String!, $cursor: String) {
      search(query: $query, type: REPOSITORY, first: 20, after: $cursor) {
        nodes {
          ... on Repository {
            nameWithOwner
            url
            description
            stargazerCount
            createdAt
            updatedAt
            primaryLanguage { name }
            owner { login }
            repositoryTopics(first: 5) {
              nodes {
                topic { name }
              }
            }
          }
        }
        pageInfo {
          hasNextPage
          endCursor
        }
      }
    }
    """
    
    variables = {
        "query": "webos sort:stars",
        "cursor": None
    }

    # Fetch a few pages
    for _ in range(3):
        data = run_query(search_query, variables)
        if not data:
            break
            
        search_data = data.get("data", {}).get("search", {})
        nodes = search_data.get("nodes", [])
        
        for repo in nodes:
            if not repo: continue
            
            # Extract topics
            topics = [t["topic"]["name"] for t in repo.get("repositoryTopics", {}).get("nodes", [])]
            
            record = {
                "type": "repo",
                "name": repo["nameWithOwner"],
                "description": repo["description"],
                "stars": repo["stargazerCount"],
                "created": repo["createdAt"],
                "updated": repo["updatedAt"],
                "language": (repo.get("primaryLanguage") or {}).get("name"),
                "topics": topics,
                "legacy_score": 1 if "palm" in (repo["description"] or "").lower() or "lune" in (repo["description"] or "").lower() else 0
            }
            
            print(json.dumps(record))
            sys.stdout.flush()
            
        page_info = search_data.get("pageInfo", {})
        if not page_info.get("hasNextPage"):
            break
            
        variables["cursor"] = page_info["endCursor"]
        time.sleep(1)

if __name__ == "__main__":
    main()
