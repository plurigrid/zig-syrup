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
    
    # Retry logic
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
    # 1. Get recent repositories (owned, collaborated, or contributed)
    # We'll start with repositories the user contributed to or owns
    print("Fetching repositories...", file=sys.stderr)
    
    repos_query = """
    query($cursor: String) {
      viewer {
        repositories(first: 20, orderBy: {field: UPDATED_AT, direction: DESC}, after: $cursor) {
          nodes {
            nameWithOwner
            url
            primaryLanguage { name }
            updatedAt
          }
          pageInfo {
            hasNextPage
            endCursor
          }
        }
        contributionsCollection {
            commitContributionsByRepository(maxRepositories: 20) {
                repository {
                    nameWithOwner
                    url
                    primaryLanguage { name }
                }
            }
        }
      }
    }
    """
    
    seen_repos = set()
    repo_queue = []

    # Fetch viewer repos
    data = run_query(repos_query)
    if data:
        viewer = data.get("data", {}).get("viewer", {})
        
        # Owned/Collaborated
        for node in viewer.get("repositories", {}).get("nodes", []):
            name = node["nameWithOwner"]
            if name not in seen_repos:
                seen_repos.add(name)
                repo_queue.append(node)
                
        # Contributed
        for item in viewer.get("contributionsCollection", {}).get("commitContributionsByRepository", []):
            repo = item["repository"]
            name = repo["nameWithOwner"]
            if name not in seen_repos:
                seen_repos.add(name)
                repo_queue.append(repo)

    # 2. Iterate repos and find authors (from PRs and recent commits)
    print(f"Found {len(repo_queue)} repositories. Streaming authors...", file=sys.stderr)
    
    authors_query = """
    query($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        pullRequests(first: 10, states: [MERGED, OPEN], orderBy: {field: CREATED_AT, direction: DESC}) {
          nodes {
            author {
              login
              url
            }
            title
            createdAt
          }
        }
        issues(first: 10, orderBy: {field: CREATED_AT, direction: DESC}) {
            nodes {
                author {
                    login
                    url
                }
                title
                createdAt
            }
        }
      }
    }
    """

    seen_authors = set()
    # Add self
    seen_authors.add("bmorphism")

    for repo in repo_queue:
        name_with_owner = repo["nameWithOwner"]
        owner, name = name_with_owner.split("/")
        
        r_data = run_query(authors_query, {"owner": owner, "name": name})
        if not r_data:
            continue
            
        repo_data = r_data.get("data", {}).get("repository", {})
        if not repo_data:
            continue
            
        # Process PRs
        for pr in repo_data.get("pullRequests", {}).get("nodes", []):
            author = pr.get("author")
            if author and author["login"] not in seen_authors:
                seen_authors.add(author["login"])
                print(json.dumps({
                    "type": "author",
                    "login": author["login"],
                    "repo": name_with_owner,
                    "interaction": "pr",
                    "title": pr.get("title"),
                    "date": pr.get("createdAt")
                }))
                sys.stdout.flush()

        # Process Issues
        for issue in repo_data.get("issues", {}).get("nodes", []):
            author = issue.get("author")
            if author and author["login"] not in seen_authors:
                seen_authors.add(author["login"])
                print(json.dumps({
                    "type": "author",
                    "login": author["login"],
                    "repo": name_with_owner,
                    "interaction": "issue",
                    "title": issue.get("title"),
                    "date": issue.get("createdAt")
                }))
                sys.stdout.flush()
                
        time.sleep(0.2) # Rate limit nice

if __name__ == "__main__":
    main()
