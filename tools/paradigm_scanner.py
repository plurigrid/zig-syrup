#!/usr/bin/env python3
"""Scan all bmorphism following accounts for programming languages and classify by paradigm."""
import json, subprocess, sys, time

PARADIGMS = {
    "Functional": {"Haskell","OCaml","Elixir","Erlang","Elm","F#","Clojure","Scala","PureScript","Standard ML","Gleam","Unison","Dhall"},
    "Homoiconic/Lisp": {"Common Lisp","Emacs Lisp","Scheme","Racket","Clojure","Hy","Fennel","Janet","Babashka","NewLisp","LFE"},
    "Systems": {"Zig","Rust","C","C++","D","Assembly","Odin","Nim","V","Carbon"},
    "Proof/Dependent": {"Coq","Agda","Lean","Idris","Isabelle","Alloy","TLA+","Dafny"},
    "Logic/Constraint": {"Prolog","Mercury","Datalog","MiniKanren","Picat","Answer Set Programming"},
    "Concatenative": {"Forth","Factor","Joy","PostScript","Cat"},
    "Array": {"APL","J","K","BQN","Q"},
    "ML-family": {"OCaml","Standard ML","F#","Haskell","Elm","PureScript","ReScript","Reason"},
    "JVM": {"Java","Kotlin","Scala","Groovy","Clojure"},
    "Scripting": {"Python","Ruby","Perl","Lua","JavaScript","TypeScript","PHP","Shell","Nushell","PowerShell","Tcl","Awk"},
    "Web/Frontend": {"JavaScript","TypeScript","HTML","CSS","Svelte","Vue","Astro","SCSS","CoffeeScript"},
    "Mobile/Apple": {"Swift","Kotlin","Dart","Objective-C","Objective-C++"},
    "Scientific": {"R","Julia","MATLAB","Fortran","Chapel","Mathematica"},
    "Smart Contract": {"Solidity","Move","Vyper","Cairo","Clarity","Plutus","Michelson","TEAL"},
    "Config/DSL": {"Nix","Dhall","CUE","Jsonnet","HCL","Starlark","Nickel","Pkl"},
    "Dataflow": {"Verilog","VHDL","SystemVerilog","LabVIEW","Max","SuperCollider","Csound","Faust"},
    "Notebook/Literate": {"Jupyter Notebook","RMarkdown","Quarto","Org","TeX","LaTeX"},
}

def lang_to_paradigms(lang):
    if not lang: return []
    return [p for p, langs in PARADIGMS.items() if lang in langs]

def batch_query(logins, batch_size=20):
    """Fetch top repos for multiple users in one GraphQL query using aliases."""
    all_results = {}
    batches = [logins[i:i+batch_size] for i in range(0, len(logins), batch_size)]
    
    for bi, batch in enumerate(batches):
        # Build aliased query - try user first
        parts = []
        for j, login in enumerate(batch):
            safe = login.replace("-", "_").replace(".", "_")
            parts.append(f'u{j}: user(login: "{login}") {{ repositories(first: 5, orderBy: {{field: STARGAZERS, direction: DESC}}) {{ nodes {{ name stargazerCount primaryLanguage {{ name }} }} }} }}')
        
        query = "{ " + " ".join(parts) + " }"
        
        try:
            r = subprocess.run(
                ["gh", "api", "graphql", "-f", f"query={query}"],
                capture_output=True, text=True, timeout=30
            )
            data = json.loads(r.stdout)
        except Exception as e:
            print(f"  batch {bi+1}/{len(batches)} error: {e}", file=sys.stderr)
            time.sleep(1)
            continue

        errors = data.get("errors", [])
        result_data = data.get("data", {})
        
        # Parse successful results
        for j, login in enumerate(batch):
            key = f"u{j}"
            if result_data.get(key):
                repos = result_data[key].get("repositories", {}).get("nodes", [])
                langs = {}
                for repo in repos:
                    lang = (repo.get("primaryLanguage") or {}).get("name")
                    if lang:
                        stars = repo.get("stargazerCount", 0)
                        if lang not in langs or stars > langs[lang]["stars"]:
                            langs[lang] = {"repo": repo["name"], "stars": stars}
                all_results[login] = langs

        # Retry failed ones as orgs
        failed = [login for j, login in enumerate(batch) if f"u{j}" not in result_data or result_data[f"u{j}"] is None]
        if failed:
            org_parts = []
            for j, login in enumerate(failed):
                org_parts.append(f'o{j}: organization(login: "{login}") {{ repositories(first: 5, orderBy: {{field: STARGAZERS, direction: DESC}}, privacy: PUBLIC) {{ nodes {{ name stargazerCount primaryLanguage {{ name }} }} }} }}')
            
            org_query = "{ " + " ".join(org_parts) + " }"
            try:
                r2 = subprocess.run(
                    ["gh", "api", "graphql", "-f", f"query={org_query}"],
                    capture_output=True, text=True, timeout=30
                )
                odata = json.loads(r2.stdout).get("data", {})
                for j, login in enumerate(failed):
                    key = f"o{j}"
                    if odata.get(key):
                        repos = odata[key].get("repositories", {}).get("nodes", [])
                        langs = {}
                        for repo in repos:
                            lang = (repo.get("primaryLanguage") or {}).get("name")
                            if lang:
                                stars = repo.get("stargazerCount", 0)
                                if lang not in langs or stars > langs[lang]["stars"]:
                                    langs[lang] = {"repo": repo["name"], "stars": stars}
                        all_results[login] = langs
            except:
                pass

        pct = ((bi + 1) / len(batches)) * 100
        print(f"  batch {bi+1}/{len(batches)} ({pct:.0f}%) - {len(all_results)} accounts scanned", file=sys.stderr)
        
        if bi % 5 == 4:
            time.sleep(0.5)  # rate limit courtesy

    return all_results

def main():
    ndjson_path = "/Users/bob/i/zig-syrup/tools/openbci_host/nuworlds/bmorphism_following.ndjson"
    out_path = "/Users/bob/i/zig-syrup/tools/openbci_host/nuworlds/bmorphism_paradigms.ndjson"
    
    with open(ndjson_path) as f:
        accounts = [json.loads(l) for l in f]
    
    logins = [a["login"] for a in accounts]
    print(f"Scanning {len(logins)} accounts...", file=sys.stderr)
    
    results = batch_query(logins)
    
    # Build enriched output
    lang_totals = {}
    paradigm_totals = {}
    records = []
    
    for acct in accounts:
        login = acct["login"]
        langs = results.get(login, {})
        lang_list = list(langs.keys())
        paradigm_set = set()
        for lang in lang_list:
            for p in lang_to_paradigms(lang):
                paradigm_set.add(p)
            lang_totals[lang] = lang_totals.get(lang, 0) + 1
        
        for p in paradigm_set:
            paradigm_totals[p] = paradigm_totals.get(p, 0) + 1
        
        records.append({
            "login": login,
            "name": acct.get("name", ""),
            "languages": lang_list,
            "paradigms": sorted(paradigm_set),
            "top_repos": [{"lang": l, "repo": d["repo"], "stars": d["stars"]} for l, d in langs.items()],
        })
    
    with open(out_path, "w") as f:
        for r in records:
            f.write(json.dumps(r) + "\n")
    
    # Summary
    print(f"\n=== LANGUAGES ({len(lang_totals)} unique) ===", file=sys.stderr)
    for lang, count in sorted(lang_totals.items(), key=lambda x: -x[1])[:40]:
        print(f"  {lang:25s} {count:4d} accounts", file=sys.stderr)
    
    print(f"\n=== PARADIGMS ({len(paradigm_totals)}) ===", file=sys.stderr)
    for p, count in sorted(paradigm_totals.items(), key=lambda x: -x[1]):
        print(f"  {p:25s} {count:4d} accounts", file=sys.stderr)
    
    # JSON summary to stdout
    print(json.dumps({
        "total_accounts": len(accounts),
        "scanned": len(results),
        "unique_languages": len(lang_totals),
        "languages": dict(sorted(lang_totals.items(), key=lambda x: -x[1])),
        "paradigms": dict(sorted(paradigm_totals.items(), key=lambda x: -x[1])),
    }, indent=2))

if __name__ == "__main__":
    main()
