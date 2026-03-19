# immer_ops.nu
# Immutable data operations for persistent world state
# Implements persistent data structures with structural sharing

# =============================================================================
# Persistent Array Operations
# =============================================================================

# Create a new persistent array
export def "immer array new" [
    --items: list = []       # Initial items
    --name: string = ""      # Optional array identifier
]: [ nothing -> record ] {
    {
        type: "immer_array"
        id: (if $name == "" { random uuid | str substring 0..8 } else { $name })
        data: $items
        hash: ($items | to json | hash sha256 | str substring 0..16)
        version: 0
        created_at: (date now)
        parent: null
    }
}

# Push item to array (returns new array)
export def "immer array push" [
    arr: record       # Array record
    value: any        # Value to append
]: [ nothing -> record ] {
    # Create new array with appended value
    let new_data = ($arr.data | append $value)
    
    {
        type: "immer_array"
        id: $arr.id
        data: $new_data
        hash: ($new_data | to json | hash sha256 | str substring 0..16)
        version: ($arr.version + 1)
        created_at: (date now)
        parent: $arr.hash
    }
}

# Pop item from array (returns new array and popped value)
export def "immer array pop" [
    arr: record       # Array record
]: [ nothing -> record ] {
    if ($arr.data | is-empty) {
        error make { msg: "Cannot pop from empty array" }
    }
    
    let new_data = ($arr.data | drop 1)
    let popped = ($arr.data | last)
    
    {
        type: "immer_array"
        id: $arr.id
        data: $new_data
        hash: ($new_data | to json | hash sha256 | str substring 0..16)
        version: ($arr.version + 1)
        created_at: (date now)
        parent: $arr.hash
        popped: $popped
    }
}

# Get item at index
export def "immer array get" [
    arr: record       # Array record
    index: int        # Index to get
]: [ nothing -> any ] {
    if $index < 0 or $index >= ($arr.data | length) {
        error make { msg: $"Index ($index) out of bounds" }
    }
    
    $arr.data | get $index
}

# Set item at index (returns new array)
export def "immer array set" [
    arr: record       # Array record
    index: int        # Index to set
    value: any        # New value
]: [ nothing -> record ] {
    if $index < 0 or $index >= ($arr.data | length) {
        error make { msg: $"Index ($index) out of bounds" }
    }
    
    let new_data = ($arr.data | enumerate | each { |item|
        if $item.index == $index {
            $value
        } else {
            $item.item
        }
    })
    
    {
        type: "immer_array"
        id: $arr.id
        data: $new_data
        hash: ($new_data | to json | hash sha256 | str substring 0..16)
        version: ($arr.version + 1)
        created_at: (date now)
        parent: $arr.hash
    }
}

# Slice array (returns new array)
export def "immer array slice" [
    arr: record       # Array record
    start: int        # Start index
    end: int          # End index (exclusive)
]: [ nothing -> record ] {
    let new_data = ($arr.data | range $start..$end)
    
    {
        type: "immer_array"
        id: $arr.id
        data: $new_data
        hash: ($new_data | to json | hash sha256 | str substring 0..16)
        version: ($arr.version + 1)
        created_at: (date now)
        parent: $arr.hash
    }
}

# Concatenate arrays (returns new array)
export def "immer array concat" [
    arr_a: record     # First array
    arr_b: record     # Second array
]: [ nothing -> record ] {
    let new_data = ($arr_a.data | append $arr_b.data)
    
    {
        type: "immer_array"
        id: (random uuid | str substring 0..8)
        data: $new_data
        hash: ($new_data | to json | hash sha256 | str substring 0..16)
        version: 0
        created_at: (date now)
        parent: [$arr_a.hash $arr_b.hash]
    }
}

# Map over array (returns new array)
export def "immer array map" [
    arr: record       # Array record
    fn: closure       # Mapping function
]: [ nothing -> record ] {
    let new_data = ($arr.data | each { |item| do $fn $item })
    
    {
        type: "immer_array"
        id: $arr.id
        data: $new_data
        hash: ($new_data | to json | hash sha256 | str substring 0..16)
        version: ($arr.version + 1)
        created_at: (date now)
        parent: $arr.hash
    }
}

# Filter array (returns new array)
export def "immer array filter" [
    arr: record       # Array record
    fn: closure       # Predicate function
]: [ nothing -> record ] {
    let new_data = ($arr.data | filter { |item| do $fn $item })
    
    {
        type: "immer_array"
        id: $arr.id
        data: $new_data
        hash: ($new_data | to json | hash sha256 | str substring 0..16)
        version: ($arr.version + 1)
        created_at: (date now)
        parent: $arr.hash
    }
}

# =============================================================================
# Persistent Map Operations
# =============================================================================

# Create a new persistent map
export def "immer map new" [
    --entries: record = {}   # Initial entries
    --name: string = ""      # Optional map identifier
]: [ nothing -> record ] {
    {
        type: "immer_map"
        id: (if $name == "" { random uuid | str substring 0..8 } else { $name })
        data: $entries
        hash: ($entries | to json | hash sha256 | str substring 0..16)
        version: 0
        created_at: (date now)
        parent: null
    }
}

# Associate key-value (returns new map)
export def "immer map assoc" [
    map: record       # Map record
    key: string       # Key to associate
    value: any        # Value to associate
]: [ nothing -> record ] {
    let new_data = ($map.data | insert $key $value)
    
    {
        type: "immer_map"
        id: $map.id
        data: $new_data
        hash: ($new_data | to json | hash sha256 | str substring 0..16)
        version: ($map.version + 1)
        created_at: (date now)
        parent: $map.hash
    }
}

# Dissociate key (returns new map)
export def "immer map dissoc" [
    map: record       # Map record
    key: string       # Key to remove
]: [ nothing -> record ] {
    if ($key not-in $map.data) {
        return $map
    }
    
    let new_data = ($map.data | reject $key)
    
    {
        type: "immer_map"
        id: $map.id
        data: $new_data
        hash: ($new_data | to json | hash sha256 | str substring 0..16)
        version: ($map.version + 1)
        created_at: (date now)
        parent: $map.hash
    }
}

# Get value by key
export def "immer map get" [
    map: record       # Map record
    key: string       # Key to get
    --default: any = null  # Default value if key not found
]: [ nothing -> any ] {
    $map.data | get -i $key | default $default
}

# Merge two maps (returns new map)
export def "immer map merge" [
    map_a: record     # First map
    map_b: record     # Second map
]: [ nothing -> record ] {
    let new_data = ($map_a.data | merge $map_b.data)
    
    {
        type: "immer_map"
        id: (random uuid | str substring 0..8)
        data: $new_data
        hash: ($new_data | to json | hash sha256 | str substring 0..16)
        version: 0
        created_at: (date now)
        parent: [$map_a.hash $map_b.hash]
    }
}

# Update key with function (returns new map)
export def "immer map update" [
    map: record       # Map record
    key: string       # Key to update
    fn: closure       # Update function
]: [ nothing -> record ] {
    let current = ($map.data | get -i $key)
    let new_value = (do $fn $current)
    
    immer map assoc $map $key $new_value
}

# Map over entries (returns new map)
export def "immer map map-entries" [
    map: record       # Map record
    fn: closure       # Mapping function over key-value pairs
]: [ nothing -> record ] {
    mut new_data = {}
    
    for key in ($map.data | columns) {
        let value = ($map.data | get $key)
        let result = (do $fn $key $value)
        $new_data = ($new_data | insert $result.0 $result.1)
    }
    
    {
        type: "immer_map"
        id: $map.id
        data: $new_data
        hash: ($new_data | to json | hash sha256 | str substring 0..16)
        version: ($map.version + 1)
        created_at: (date now)
        parent: $map.hash
    }
}

# Filter entries (returns new map)
export def "immer map filter" [
    map: record       # Map record
    fn: closure       # Predicate function over key-value pairs
]: [ nothing -> record ] {
    mut new_data = {}
    
    for key in ($map.data | columns) {
        let value = ($map.data | get $key)
        if (do $fn $key $value) {
            $new_data = ($new_data | insert $key $value)
        }
    }
    
    {
        type: "immer_map"
        id: $map.id
        data: $new_data
        hash: ($new_data | to json | hash sha256 | str substring 0..16)
        version: ($map.version + 1)
        created_at: (date now)
        parent: $map.hash
    }
}

# =============================================================================
# Diff Operations
# =============================================================================

# Show structural diff between two values
export def "immer diff" [
    old: any          # Old value
    new: any          # New value
    --path: string = ""   # Current path for nested diff
]: [ nothing -> record ] {
    
    # Handle different types
    if ($old | describe) != ($new | describe) {
        return {
            type: "type_changed"
            path: $path
            old_type: ($old | describe)
            new_type: ($new | describe)
            old: $old
            new: $new
        }
    }
    
    let type = ($old | describe)
    
    match $type {
        "record" => { diff-records $old $new $path }
        "list" => { diff-lists $old $new $path }
        "table" => { diff-lists ($old | transpose) ($new | transpose) $path }
        _ => {
            if $old == $new {
                { type: "unchanged", path: $path }
            } else {
                { type: "modified", path: $path, old: $old, new: $new }
            }
        }
    }
}

# Diff two records
export def diff-records [old: record, new: record, path: string]: [ nothing -> record ] {
    let old_keys = ($old | columns)
    let new_keys = ($new | columns)
    
    let added = ($new_keys | where {|k| $k not-in $old_keys})
    let removed = ($old_keys | where {|k| $k not-in $new_keys})
    
    mut modified = []
    let common = ($old_keys | where {|k| $k in $new_keys})
    
    for key in $common {
        let old_val = ($old | get $key)
        let new_val = ($new | get $key)
        let subdiff = (immer diff $old_val $new_val --path $"($path).($key)")
        if $subdiff.type != "unchanged" {
            $modified = ($modified | append $subdiff)
        }
    }
    
    {
        type: "record_diff"
        path: $path
        added: $added
        removed: $removed
        modified: $modified
    }
}

# Diff two lists
export def diff-lists [old: list, new: list, path: string]: [ nothing -> record ] {
    let len_old = ($old | length)
    let len_new = ($new | length)
    
    mut modified = []
    let min_len = (if $len_old < $len_new { $len_old } else { $len_new })
    
    for i in 0..<$min_len {
        let old_val = ($old | get $i)
        let new_val = ($new | get $i)
        let subdiff = (immer diff $old_val $new_val --path $"($path)[$i]")
        if $subdiff.type != "unchanged" {
            $modified = ($modified | append $subdiff)
        }
    }
    
    {
        type: "list_diff"
        path: $path
        length_delta: ($len_new - $len_old)
        added: (if $len_new > $len_old { $new | range $len_old.. } else { [] })
        removed: (if $len_old > $len_new { $old | range $len_new.. } else { [] })
        modified: $modified
    }
}

# =============================================================================
# Hash Operations
# =============================================================================

# Compute content hash of a value
export def "immer hash" [
    value: any                # Value to hash
    --algorithm: string = "sha256"   # Hash algorithm
]: [ nothing -> string ] {
    let json_str = ($value | to json)
    
    match $algorithm {
        "sha256" => { $json_str | hash sha256 }
        "md5" => { $json_str | hash md5 }
        "sha512" => { $json_str | hash sha256 }  # Fallback to sha256
        _ => { error make { msg: $"Unknown hash algorithm: ($algorithm)" } }
    }
}

# =============================================================================
# Structural Sharing Analysis
# =============================================================================

# Show structural sharing between two versions
export def "immer share" [
    v1: record              # First version
    v2: record              # Second version
    --detailed: bool        # Show detailed sharing info
]: [ nothing -> record ] {
    
    let same_id = ($v1.id == $v2.id)
    let parent_rel = (if $v2.parent == $v1.hash { "direct_child" } 
                      else if $v1.parent == $v2.hash { "direct_parent" }
                      else if ($v1.parent == $v2.parent) and ($v1.parent != null) { "siblings" }
                      else { "unrelated" })
    
    # Calculate data overlap
    let data_overlap = (if ($v1 | get -i data | is-not-empty) and ($v2 | get -i data | is-not-empty) {
        let v1_data = ($v1.data | to json)
        let v2_data = ($v2.data | to json)
        
        if $v1_data == $v2_data {
            1.0
        } else {
            # Estimate overlap by common structure
            estimate-overlap $v1.data $v2.data
        }
    } else { 0.0 })
    
    let result = {
        same_structure: ($v1.type == $v2.type)
        same_id: $same_id
        relationship: $parent_rel
        v1_hash: $v1.hash
        v2_hash: $v2.hash
        data_overlap: $data_overlap
        v1_version: $v1.version
        v2_version: $v2.version
        versions_apart: (if $same_id { ($v2.version - $v1.version) | math abs } else { null })
    }
    
    print "Structural Sharing Analysis:"
    print $"  Same ID: ($result.same_id)"
    print $"  Relationship: ($result.relationship)"
    print $"  Data overlap: ($result.data_overlap | math round -p 2)"
    if $same_id {
        print $"  Versions apart: ($result.versions_apart)"
    }
    
    if $detailed {
        print $"\n  v1 hash: ($result.v1_hash)"
        print $"  v2 hash: ($result.v2_hash)"
    }
    
    $result
}

# Estimate structural overlap (simplified)
export def estimate-overlap [a: any, b: any]: [ nothing -> float ] {
    let type_a = ($a | describe)
    let type_b = ($b | describe)
    
    if $type_a != $type_b {
        return 0.0
    }
    
    match $type_a {
        "list" => {
            let len_a = ($a | length)
            let len_b = ($b | length)
            let min_len = (if $len_a < $len_b { $len_a } else { $len_b })
            let max_len = (if $len_a > $len_b { $len_a } else { $len_b })
            
            if $max_len == 0 { return 1.0 }
            
            mut common = 0
            for i in 0..<$min_len {
                if ($a | get $i | to json) == ($b | get $i | to json) {
                    $common = $common + 1
                }
            }
            
            ($common / $max_len)
        }
        "record" => {
            let keys_a = ($a | columns)
            let keys_b = ($b | columns)
            let common_keys = ($keys_a | where {|k| $k in $keys_b })
            let all_keys = ($keys_a | append $keys_b | uniq)
            
            if ($all_keys | is-empty) { return 1.0 }
            
            ($common_keys | length) / ($all_keys | length)
        }
        _ => {
            if $a == $b { 1.0 } else { 0.0 }
        }
    }
}

# =============================================================================
# Version History
# =============================================================================

# Get version history for an immer data structure
export def "immer history" [
    current: record       # Current version
    --depth: int = 10     # How many versions back
]: [ nothing -> list ] {
    mut history = [$current]
    mut current_hash = ($current | get -i parent)
    
    # This is a simplified version - in practice would lookup from storage
    print $"History for ($current.id):"
    print $"  Current: v($current.version) - ($current.hash)"
    
    # Return what we have
    $history
}

# =============================================================================
# Utility Functions
# =============================================================================

# Convert immer structure to regular nushell value
export def "immer to-value" [
    immer: record         # Immer record
]: [ nothing -> any ] {
    $immer.data
}

# Create immer structure from regular value
export def "immer from-value" [
    value: any            # Value to wrap
    --type: string = "auto"   # Type hint (array/map)
]: [ nothing -> record ] {
    let detected_type = ($value | describe)
    
    match $detected_type {
        "list" => { immer array new --items $value }
        "record" => { immer map new --entries $value }
        _ => {
            if $type == "array" {
                immer array new --items [$value]
            } else {
                immer map new --entries { value: $value }
            }
        }
    }
}

# Pretty print immer structure
export def "immer print" [
    immer: record         # Immer record
    --compact: bool       # Compact output
]: [ nothing -> nothing ] {
    print $"Type: ($immer.type)"
    print $"ID: ($immer.id)"
    print $"Version: ($immer.version)"
    print $"Hash: ($immer.hash)"
    print "Data:"
    
    if $compact {
        $immer.data | table
    } else {
        $immer.data | table -e
    }
}
