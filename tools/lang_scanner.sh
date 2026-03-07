#!/bin/bash
# Scan bmorphism following for repos by language
# Usage: ./lang_scanner.sh <start> <end> 
# Outputs NDJSON: {"login":"x","lang":"Zig","repo":"y","stars":123}

START=${1:-0}
END=${2:-1684}
LOGINS="/tmp/all_logins.txt"
i=0

while IFS= read -r login; do
    i=$((i+1))
    [ $i -le $START ] && continue
    [ $i -gt $END ] && break
    
    # Try as user first
    result=$(gh api graphql -f query="{
      user(login: \"$login\") {
        repositories(first: 5, orderBy: {field: STARGAZERS, direction: DESC}) {
          nodes { name stargazerCount primaryLanguage { name } }
        }
      }
    }" --jq '.data.user.repositories.nodes[] | "\(.primaryLanguage.name // "null")\t\(.stargazerCount)\t\(.name)"' 2>/dev/null)
    
    if [ -z "$result" ]; then
        # Try as org
        result=$(gh api graphql -f query="{
          organization(login: \"$login\") {
            repositories(first: 5, orderBy: {field: STARGAZERS, direction: DESC}, privacy: PUBLIC) {
              nodes { name stargazerCount primaryLanguage { name } }
            }
          }
        }" --jq '.data.organization.repositories.nodes[] | "\(.primaryLanguage.name // "null")\t\(.stargazerCount)\t\(.name)"' 2>/dev/null)
    fi
    
    echo "$result" | while IFS=$'\t' read -r lang stars repo; do
        [ -z "$lang" ] && continue
        [ "$lang" = "null" ] && continue
        echo "{\"login\":\"$login\",\"lang\":\"$lang\",\"repo\":\"$repo\",\"stars\":$stars}"
    done
done < "$LOGINS"
