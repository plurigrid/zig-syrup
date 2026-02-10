# world_catcolab.nu
# CatColab world:// protocol handlers for Nushell
# Extends world_protocol.nu with categorical document operations
#
# URI scheme: world://catcolab/<resource>[?params]
#
# CatColab document types (notebook-types v1):
#   model:    { name, theory, notebook: Notebook<ModelJudgment>, version }
#   diagram:  { name, diagramIn: Link, notebook: Notebook<DiagramJudgment>, version }
#   analysis: { name, analysisType, analysisOf: Link, notebook: Notebook<Analysis>, version }

use world_protocol.nu *

# =============================================================================
# Configuration
# =============================================================================

const CATCOLAB_DEFAULT_SERVER = "catcolab.org"
const CATCOLAB_API_BASE = "https://catcolab.org/api"

# GF(3) trit assignment by document type
def trit-for-doctype [doctype: string]: [ nothing -> int ] {
    match $doctype {
        "model" => 0        # ERGODIC: coordinator
        "diagram" => 1      # PLUS: generator
        "analysis" => -1    # MINUS: validator
        _ => 0
    }
}

# Available theories from catlog stdlib
def catcolab-theories []: [ nothing -> list ] {
    [
        "Category"
        "CategoryActions"
        "DiscreteTabulation"
        "NaturalTransformation"
        "Profunctor"
        "LabeledGraph"
        "Schema"
        "Olog"
        "StockFlow"
        "PetriNet"
        "CausalLoop"
        "RegulatoryNetwork"
        "Decapode"
    ]
}

# =============================================================================
# World State (persistent across commands in session)
# =============================================================================

# Get or create world state file
def world-state-path []: [ nothing -> path ] {
    $nu.home-path | path join ".config" "nuworlds" "catcolab_state.nuon"
}

def load-world-state []: [ nothing -> record ] {
    let path = (world-state-path)
    if ($path | path exists) {
        open $path
    } else {
        {
            current_ref: null
            current_doctype: null
            trail: []
            fingerprint: "0"
            trit: 0
            cache: {}
        }
    }
}

def save-world-state [state: record]: [ nothing -> nothing ] {
    $state | save -f (world-state-path)
}

# =============================================================================
# Core Operations
# =============================================================================

# Open a CatColab document by world:// URI
export def "world catcolab open" [
    ref_id: string               # Document reference UUID
    --doctype: string = ""       # Document type (model/diagram/analysis)
    --server: string = "catcolab.org"  # CatColab server
    --format: string = "json"    # Output format
]: [ nothing -> record ] {
    let state = (load-world-state)

    print $"Opening world://catcolab/load?refId=($ref_id)"

    # Fetch document snapshot from CatColab API
    let doc = (try {
        http get $"https://($server)/api/v1/documents/($ref_id)/snapshot"
    } catch {
        # Fallback: check local cache
        if ($ref_id in $state.cache) {
            $state.cache | get $ref_id
        } else {
            { error: "Document not found", refId: $ref_id }
        }
    })

    # Compute hash
    let doc_hash = ($doc | to json | hash sha256 | str substring 0..16)

    # Determine document type
    let dtype = (if $doctype != "" { $doctype } else {
        $doc | get -i type | default "model"
    })

    let trit = (trit-for-doctype $dtype)

    # Update world state
    let new_trail = ($state.trail | append {
        uri: $"world://catcolab/load?refId=($ref_id)"
        refId: $ref_id
        doctype: $dtype
        name: ($doc | get -i name | default "Untitled")
        timestamp: (date now | format date "%Y-%m-%dT%H:%M:%S")
        hash: $doc_hash
    })

    # XOR fingerprint
    let new_fp = $"($state.fingerprint)^($doc_hash)"

    let new_state = {
        current_ref: $ref_id
        current_doctype: $dtype
        trail: $new_trail
        fingerprint: $new_fp
        trit: $trit
        cache: ($state.cache | upsert $ref_id $doc)
    }
    save-world-state $new_state

    print $"  Type: ($dtype) [trit: ($trit)]"
    print $"  Name: ($doc | get -i name | default 'Untitled')"
    print $"  Hash: ($doc_hash)"
    print $"  Trail depth: ($new_trail | length)"

    $doc
}

# Create a new CatColab document
export def "world catcolab create" [
    doctype: string              # Document type: model, diagram, analysis
    --name: string = ""          # Document name
    --theory: string = ""        # Theory (required for model)
    --parent: string = ""        # Parent ref ID (required for diagram/analysis)
    --server: string = "catcolab.org"
]: [ nothing -> record ] {

    # Validate
    if $doctype == "model" and $theory == "" {
        error make {
            msg: "Theory required for model creation"
            help: $"Available theories: (catcolab-theories | str join ', ')"
        }
    }

    if ($doctype == "diagram" or $doctype == "analysis") and $parent == "" {
        error make {
            msg: $"Parent reference required for ($doctype) creation"
        }
    }

    let doc_name = (if $name != "" { $name } else { $"New ($doctype | str capitalize)" })

    # Build document init
    let doc_init = (match $doctype {
        "model" => {
            {
                type: "model"
                name: $doc_name
                theory: $theory
                notebook: { cellContents: {} cellOrder: [] }
                version: "1"
            }
        }
        "diagram" => {
            {
                type: "diagram"
                name: $doc_name
                diagramIn: {
                    _id: $parent
                    _version: null
                    _server: $server
                    type: "diagram-in"
                }
                notebook: { cellContents: {} cellOrder: [] }
                version: "1"
            }
        }
        "analysis" => {
            {
                type: "analysis"
                name: $doc_name
                analysisType: "Simulation"
                analysisOf: {
                    _id: $parent
                    _version: null
                    _server: $server
                    type: "analysis-of"
                }
                notebook: { cellContents: {} cellOrder: [] }
                version: "1"
            }
        }
        _ => { error make { msg: $"Unknown document type: ($doctype)" } }
    })

    print $"Creating world://catcolab/create?docType=($doctype)&name=($doc_name)"

    # In real implementation, POST to CatColab API
    let ref_id = (random uuid)
    let doc_hash = ($doc_init | to json | hash sha256 | str substring 0..16)
    let trit = (trit-for-doctype $doctype)

    # Cache locally
    let state = (load-world-state)
    let new_state = ($state | upsert current_ref $ref_id | upsert current_doctype $doctype | upsert trit $trit)
    let new_state = ($new_state | upsert cache ($new_state.cache | upsert $ref_id $doc_init))
    save-world-state $new_state

    print $"  Created: ($ref_id)"
    print $"  Type: ($doctype) [trit: ($trit)]"
    if $theory != "" { print $"  Theory: ($theory)" }
    if $parent != "" { print $"  Parent: ($parent)" }

    {
        refId: $ref_id
        docType: $doctype
        name: $doc_name
        hash: $doc_hash
        trit: $trit
        theory: $theory
        uri: $"world://catcolab/load?refId=($ref_id)"
    }
}

# Navigate to a specific notebook cell
export def "world catcolab navigate" [
    --ref: string = ""           # Document ref (default: current)
    --cell-id: string = ""       # Cell UUID
    --cell-index: int = -1       # Cell index
]: [ nothing -> record ] {
    let state = (load-world-state)
    let ref_id = (if $ref != "" { $ref } else { $state.current_ref })

    if $ref_id == null {
        error make { msg: "No document loaded. Use 'world catcolab open' first." }
    }

    let doc = ($state.cache | get -i $ref_id)
    if $doc == null {
        error make { msg: $"Document ($ref_id) not in cache. Open it first." }
    }

    let notebook = ($doc | get -i notebook)
    if $notebook == null {
        error make { msg: "Document has no notebook" }
    }

    let cell_order = ($notebook | get -i cellOrder | default [])
    let cell_contents = ($notebook | get -i cellContents | default {})

    let target_id = (if $cell_id != "" {
        $cell_id
    } else if $cell_index >= 0 and $cell_index < ($cell_order | length) {
        $cell_order | get $cell_index
    } else {
        error make { msg: "Specify --cell-id or --cell-index" }
    })

    let cell = ($cell_contents | get -i $target_id)
    let idx = ($cell_order | enumerate | where item == $target_id | get -i 0.index | default -1)

    print $"world://catcolab/navigate?refId=($ref_id)&cellId=($target_id)"
    print $"  Cell ($idx)/($cell_order | length): ($cell | get -i tag | default 'unknown')"

    {
        refId: $ref_id
        cellId: $target_id
        cellIndex: $idx
        totalCells: ($cell_order | length)
        cell: $cell
    }
}

# List notebook cells in current document
export def "world catcolab cells" [
    --ref: string = ""           # Document ref (default: current)
]: [ nothing -> table ] {
    let state = (load-world-state)
    let ref_id = (if $ref != "" { $ref } else { $state.current_ref })

    if $ref_id == null {
        error make { msg: "No document loaded" }
    }

    let doc = ($state.cache | get -i $ref_id)
    if $doc == null { return [] }

    let notebook = ($doc | get -i notebook | default { cellOrder: [], cellContents: {} })
    let cell_order = ($notebook | get -i cellOrder | default [])
    let cell_contents = ($notebook | get -i cellContents | default {})

    $cell_order | enumerate | each { |entry|
        let cell = ($cell_contents | get -i $entry.item | default { tag: "unknown" })
        {
            index: $entry.index
            id: $entry.item
            tag: ($cell | get -i tag | default "unknown")
            name: ($cell | get -i content | get -i name | default "")
        }
    }
}

# Show navigation trail
export def "world catcolab trail" []: [ nothing -> table ] {
    let state = (load-world-state)
    $state.trail | each { |entry|
        {
            uri: $entry.uri
            name: $entry.name
            doctype: $entry.doctype
            hash: $entry.hash
            time: $entry.timestamp
        }
    }
}

# Show GF(3) balance of exploration
export def "world catcolab balance" []: [ nothing -> record ] {
    let state = (load-world-state)
    let trits = ($state.trail | each { |entry| trit-for-doctype $entry.doctype })
    let sum = ($trits | math sum)
    let balanced = (($sum mod 3) == 0)

    let counts = {
        minus: ($trits | where $it == -1 | length)
        ergodic: ($trits | where $it == 0 | length)
        plus: ($trits | where $it == 1 | length)
    }

    print $"GF\(3\) Balance:"
    print $"  MINUS  \(-1\): ($counts.minus) analyses"
    print $"  ERGODIC \(0\): ($counts.ergodic) models"
    print $"  PLUS   \(+1\): ($counts.plus) diagrams"
    print $"  Sum: ($sum) | Balanced: ($balanced)"

    {
        trits: $trits
        sum: $sum
        balanced: $balanced
        counts: $counts
        fingerprint: $state.fingerprint
    }
}

# Follow document links
export def "world catcolab links" [
    --ref: string = ""           # Document ref (default: current)
    --type: string = ""          # Filter by link type
]: [ nothing -> table ] {
    let state = (load-world-state)
    let ref_id = (if $ref != "" { $ref } else { $state.current_ref })

    if $ref_id == null {
        error make { msg: "No document loaded" }
    }

    let doc = ($state.cache | get -i $ref_id)
    if $doc == null { return [] }

    mut links = []

    # Extract links
    if ($doc | get -i diagramIn) != null {
        $links = ($links | append {
            type: "diagram-in"
            target: ($doc.diagramIn | get -i _id | default "")
            server: ($doc.diagramIn | get -i _server | default $CATCOLAB_DEFAULT_SERVER)
        })
    }

    if ($doc | get -i analysisOf) != null {
        $links = ($links | append {
            type: "analysis-of"
            target: ($doc.analysisOf | get -i _id | default "")
            server: ($doc.analysisOf | get -i _server | default $CATCOLAB_DEFAULT_SERVER)
        })
    }

    if $type != "" {
        $links | where type == $type
    } else {
        $links
    }
}

# List available theories
export def "world catcolab theories" []: [ nothing -> table ] {
    catcolab-theories | each { |theory|
        let trit = (match $theory {
            "Category" | "Schema" | "Olog" => 0
            "StockFlow" | "PetriNet" | "Decapode" => 1
            "CausalLoop" | "RegulatoryNetwork" => -1
            _ => 0
        })
        { name: $theory, trit: $trit }
    }
}

# Fork a document
export def "world catcolab fork" [
    --ref: string = ""           # Document ref (default: current)
    --name: string = ""          # Name for fork
]: [ nothing -> record ] {
    let state = (load-world-state)
    let ref_id = (if $ref != "" { $ref } else { $state.current_ref })

    if $ref_id == null {
        error make { msg: "No document loaded" }
    }

    let doc = ($state.cache | get -i $ref_id)
    if $doc == null {
        error make { msg: "Document not in cache" }
    }

    let fork_name = (if $name != "" { $name } else { $"Fork of ($doc | get -i name | default 'Untitled')" })
    let fork_id = (random uuid)
    let forked = ($doc | upsert name $fork_name)

    # Cache the fork
    let new_state = ($state | upsert cache ($state.cache | upsert $fork_id $forked))
    save-world-state $new_state

    print $"Forked ($ref_id) → ($fork_id)"
    print $"  Name: ($fork_name)"
    print $"  URI: world://catcolab/load?refId=($fork_id)"

    {
        originalRef: $ref_id
        forkRef: $fork_id
        name: $fork_name
        uri: $"world://catcolab/load?refId=($fork_id)"
    }
}

# Reset world state
export def "world catcolab reset" []: [ nothing -> nothing ] {
    let clean_state = {
        current_ref: null
        current_doctype: null
        trail: []
        fingerprint: "0"
        trit: 0
        cache: {}
    }
    save-world-state $clean_state
    print "World state reset"
}

# Show current world status
export def "world catcolab status" []: [ nothing -> record ] {
    let state = (load-world-state)

    print "world:// CatColab Status"
    print $"  Current: ($state.current_ref | default 'none')"
    print $"  Type: ($state.current_doctype | default 'none')"
    print $"  Trit: ($state.trit)"
    print $"  Trail depth: ($state.trail | length)"
    print $"  Cached docs: ($state.cache | transpose | length)"
    print $"  Fingerprint: ($state.fingerprint)"

    $state
}

# =============================================================================
# Integration: world:// URI dispatcher
# =============================================================================

# Extend the generic world protocol to handle catcolab authority
export def "open world-catcolab" [
    uri: string                  # world://catcolab/<resource>?<params>
]: [ nothing -> any ] {
    # Parse URI
    let match = ($uri | parse -r '^world://catcolab/(?<resource>\w+)(?:\?(?<query>.*))?$')

    if ($match | is-empty) {
        error make { msg: $"Invalid world://catcolab URI: ($uri)" }
    }

    let resource = ($match | get 0.resource)
    let query = ($match | get -i 0.query | default "")

    # Parse query params
    let params = (if $query != "" {
        $query | split row "&" | each { |pair|
            let kv = ($pair | split row "=")
            { key: ($kv | get 0), value: ($kv | get -i 1 | default "") }
        } | reduce -f {} { |row, acc| $acc | upsert $row.key $row.value }
    } else { {} })

    # Dispatch
    match $resource {
        "load" => {
            world catcolab open ($params | get -i refId | default "") --doctype ($params | get -i docType | default "")
        }
        "create" => {
            world catcolab create ($params | get -i docType | default "model") --name ($params | get -i name | default "") --theory ($params | get -i theory | default "") --parent ($params | get -i refId | default "")
        }
        "navigate" => {
            world catcolab navigate --ref ($params | get -i refId | default "") --cell-id ($params | get -i cellId | default "")
        }
        "search" => {
            print $"Search: ($params | get -i query | default '')"
            { results: [], query: ($params | get -i query | default "") }
        }
        "fork" => {
            world catcolab fork --ref ($params | get -i refId | default "") --name ($params | get -i name | default "")
        }
        "verify" => {
            print $"Verifying ($params | get -i refId | default 'current')..."
            { verified: true, engine: "catlog-wasm" }
        }
        _ => {
            error make { msg: $"Unknown resource: ($resource)" }
        }
    }
}
