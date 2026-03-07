#!/usr/bin/env python3
"""
Fetch all bmorphism GitHub following via gh CLI GraphQL pagination,
stream into Polars, partition by maximally deranged first letters.

A derangement sigma satisfies sigma(i) != i for all i.
Here: each bucket's label letter != the first letter of any login in that bucket.
"""
import subprocess, json, sys
import polars as pl

QUERY_TEMPLATE = """
{{
  user(login: "bmorphism") {{
    following(first: 100{after}) {{
      totalCount
      pageInfo {{ hasNextPage endCursor }}
      nodes {{
        login
        name
        __typename
        ... on User {{
          bio
          company
          followers {{ totalCount }}
          following {{ totalCount }}
          repositories {{ totalCount }}
        }}
      }}
    }}
  }}
}}
"""

def fetch_all_following():
    all_nodes = []
    cursor = None
    page = 0
    while True:
        after = f', after: "{cursor}"' if cursor else ""
        query = QUERY_TEMPLATE.format(after=after)
        result = subprocess.run(
            ["gh", "api", "graphql", "-f", f"query={query}"],
            capture_output=True, text=True
        )
        if result.returncode != 0:
            print(f"Error on page {page}: {result.stderr}", file=sys.stderr)
            break
        data = json.loads(result.stdout)
        following = data["data"]["user"]["following"]
        nodes = following["nodes"]
        all_nodes.extend(nodes)
        page += 1
        total = following["totalCount"]
        print(f"  Page {page}: {len(all_nodes)}/{total} fetched", file=sys.stderr)
        if not following["pageInfo"]["hasNextPage"]:
            break
        cursor = following["pageInfo"]["endCursor"]
    return all_nodes

def derangement_map(letters):
    """Build a derangement: each letter maps to a different letter."""
    sorted_letters = sorted(set(letters))
    n = len(sorted_letters)
    if n < 2:
        return {sorted_letters[0]: sorted_letters[0]}  # trivial
    # Simple cyclic shift derangement: a->b, b->c, ..., z->a
    deranged = {}
    for i, letter in enumerate(sorted_letters):
        deranged[letter] = sorted_letters[(i + 1) % n]
    return deranged

def main():
    print("Fetching bmorphism's following (1683 accounts)...", file=sys.stderr)
    nodes = fetch_all_following()

    # Flatten to records
    records = []
    for n in nodes:
        login = n.get("login", "")
        first_letter = login[0].upper() if login else "?"
        records.append({
            "login": login,
            "name": n.get("name") or "",
            "first_letter": first_letter,
            "followers": n.get("followers", {}).get("totalCount", 0) if isinstance(n.get("followers"), dict) else 0,
            "following": n.get("following", {}).get("totalCount", 0) if isinstance(n.get("following"), dict) else 0,
            "repos": n.get("repositories", {}).get("totalCount", 0) if isinstance(n.get("repositories"), dict) else 0,
            "company": n.get("company") or "",
            "bio": (n.get("bio") or "")[:80],
        })

    df = pl.DataFrame(records)
    print(f"\nTotal accounts: {len(df)}", file=sys.stderr)

    # Get all first letters present
    letters = sorted(df["first_letter"].unique().to_list())
    print(f"Unique first letters: {len(letters)} -> {letters}", file=sys.stderr)

    # Build derangement map
    sigma = derangement_map(letters)
    print(f"\nDerangement sigma (letter -> bucket):", file=sys.stderr)
    for k, v in sorted(sigma.items()):
        print(f"  {k} -> bucket [{v}]", file=sys.stderr)

    # Add deranged bucket column
    df = df.with_columns(
        pl.col("first_letter").replace_strict(sigma, default="?").alias("bucket")
    )

    # Summary stats
    print(f"\n{'='*80}", file=sys.stderr)
    print(f"DERANGED BUCKET SUMMARY", file=sys.stderr)
    print(f"{'='*80}", file=sys.stderr)

    bucket_stats = (
        df.group_by("bucket")
        .agg([
            pl.col("login").count().alias("count"),
            pl.col("followers").sum().alias("total_followers"),
            pl.col("repos").sum().alias("total_repos"),
            pl.col("first_letter").first().alias("actual_first_letter"),
            pl.col("login").sort_by("followers", descending=True).first().alias("top_account"),
        ])
        .sort("bucket")
    )

    # Print bucket summary
    print(bucket_stats.to_pandas().to_string(index=False), file=sys.stderr)

    # Write full partitioned output as NDJSON for nushell/nuworlds consumption
    output_path = "/Users/bob/i/zig-syrup/tools/openbci_host/nuworlds/bmorphism_following.ndjson"
    # Sort by bucket then by followers descending
    df_sorted = df.sort(["bucket", "followers"], descending=[False, True])

    with open(output_path, "w") as f:
        for row in df_sorted.iter_rows(named=True):
            f.write(json.dumps(row) + "\n")
    print(f"\nWrote {len(df_sorted)} records to {output_path}", file=sys.stderr)

    # Also write a compact parquet for polars addon
    parquet_path = "/Users/bob/i/zig-syrup/tools/openbci_host/nuworlds/bmorphism_following.parquet"
    df_sorted.write_parquet(parquet_path)
    print(f"Wrote parquet to {parquet_path}", file=sys.stderr)

    # Print the deranged partition table to stdout (token-efficient)
    print("\n## Deranged Buckets (sigma(letter) != letter for all)")
    print(f"## Total: {len(df)} accounts across {len(letters)} letters\n")

    for bucket_letter in sorted(df_sorted["bucket"].unique().to_list()):
        bucket_df = df_sorted.filter(pl.col("bucket") == bucket_letter)
        source_letter = [k for k, v in sigma.items() if v == bucket_letter][0] if bucket_letter in sigma.values() else "?"
        count = len(bucket_df)
        top5 = bucket_df.head(5)["login"].to_list()
        total_followers = bucket_df["followers"].sum()
        print(f"### Bucket [{bucket_letter}] (contains '{source_letter}'-logins, n={count}, {total_followers} followers)")
        print(f"  Top: {', '.join(top5)}")
        # Print all logins compactly
        all_logins = bucket_df["login"].to_list()
        # Chunk into lines of ~10
        for i in range(0, len(all_logins), 10):
            chunk = all_logins[i:i+10]
            print(f"  {' '.join(chunk)}")
        print()

if __name__ == "__main__":
    main()
