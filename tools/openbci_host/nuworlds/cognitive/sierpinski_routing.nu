# sierpinski_routing.nu
# Sierpinski Fractal/Hierarchical Routing for nuworlds cognitive control
# Multi-resolution routing with self-similar structure

# =============================================================================
# Sierpinski Triangle Structure Construction
# =============================================================================

# Build Sierpinski triangle structure
export def "sierpinski build" [
    --depth: int = 5           # Recursion depth (levels)
    --size: float = 1.0        # Base triangle size
    --origin: list = [0.0 0.0] # Origin position [x, y]
]: [ nothing -> record ] {
    let vertices = {
        top: [$origin.0 ($origin.1 + $size)]
        left: [($origin.0 - $size * 0.866) ($origin.1 - $size * 0.5)]
        right: [($origin.0 + $size * 0.866) ($origin.1 - $size * 0.5)]
    }
    
    # Generate all triangles at all levels
    let triangles = (generate-sierpinski-triangles $vertices $depth)
    
    # Build routing tables
    let routing_tables = (build-routing-tables $triangles $depth)
    
    # Build address space (Sierpinski coordinates)
    let address_space = (build-address-space $triangles $depth)
    
    {
        type: "sierpinski_router"
        depth: $depth
        size: $size
        origin: $origin
        vertices: $vertices
        triangles: $triangles
        routing_tables: $routing_tables
        address_space: $address_space
        total_nodes: ($triangles | length)
        leaf_nodes: (pow 3 $depth)
    }
}

# Generate Sierpinski triangle geometry recursively
def generate-sierpinski-triangles [vertices: record, depth: int]: [ nothing -> list ] {
    mut all_triangles = []
    
    # Start with base triangle
    let base_triangle = {
        id: "0"
        level: 0
        vertices: $vertices
        centroid: (calculate-centroid $vertices)
        parent: null
        children: []
        neighbors: {}
    }
    
    $all_triangles = ($all_triangles | append $base_triangle)
    
    # Recursively subdivide
    mut current_level = [$base_triangle]
    
    for level in 1..=$depth {
        mut next_level = []
        
        for triangle in $current_level {
            # Subdivide into 3 smaller triangles (remove center)
            let subdivided = (subdivide-triangle $triangle $level)
            
            # Update parent with children
            let child_ids = ($subdivided | each {|t| $t.id})
            $all_triangles = ($all_triangles | update ($triangle.id) {|t|
                $t | upsert children $child_ids
            })
            
            $next_level = ($next_level | append $subdivided)
            $all_triangles = ($all_triangles | append $subdivided)
        }
        
        $current_level = $next_level
    }
    
    # Build neighbor relationships
    $all_triangles = (build-neighbor-connections $all_triangles)
    
    $all_triangles
}

# Subdivide a triangle into 3 Sierpinski sub-triangles
def subdivide-triangle [triangle: record, level: int]: [ nothing -> list ] {
    let v = $triangle.vertices
    
    # Calculate midpoints of each edge
    let mid_top_left = (midpoint $v.top $v.left)
    let mid_top_right = (midpoint $v.top $v.right)
    let mid_left_right = (midpoint $v.left $v.right)
    
    # Three sub-triangles (upside-down center triangle removed)
    [
        {
            id: $"($triangle.id).0"
            level: $level
            vertices: {
                top: $v.top
                left: $mid_top_left
                right: $mid_top_right
            }
            centroid: (calculate-centroid {
                top: $v.top
                left: $mid_top_left
                right: $mid_top_right
            })
            parent: $triangle.id
            children: []
            neighbors: {}
        }
        {
            id: $"($triangle.id).1"
            level: $level
            vertices: {
                top: $mid_top_left
                left: $v.left
                right: $mid_left_right
            }
            centroid: (calculate-centroid {
                top: $mid_top_left
                left: $v.left
                right: $mid_left_right
            })
            parent: $triangle.id
            children: []
            neighbors: {}
        }
        {
            id: $"($triangle.id).2"
            level: $level
            vertices: {
                top: $mid_top_right
                left: $mid_left_right
                right: $v.right
            }
            centroid: (calculate-centroid {
                top: $mid_top_right
                left: $mid_left_right
                right: $v.right
            })
            parent: $triangle.id
            children: []
            neighbors: {}
        }
    ]
}

# Build neighbor connections between triangles
def build-neighbor-connections [triangles: list]: [ nothing -> list ] {
    $triangles | each {|t1|
        mut neighbors = {}
        
        for t2 in $triangles {
            if $t1.id != $t2.id and (triangles-share-edge $t1 $t2) {
                # Determine which edge is shared
                let edge = (find-shared-edge $t1 $t2)
                $neighbors = ($neighbors | insert $edge $t2.id)
            }
        }
        
        $t1 | upsert neighbors $neighbors
    }
}

# =============================================================================
# Routing Through Fractal Hierarchy
# =============================================================================

# Route signals through Sierpinski hierarchy
export def "sierpinski route" [
    source: string             # Source address
    destination: string        # Destination address
    --router: record = {}      # Sierpinski router (or use input)
    --priority: int = 0        # Routing priority
    --multicast: bool = false  # Multicast routing
]: [ nothing -> record ] {
    let r = (if ($router | is-empty) { $in } else { $router })
    
    # Find source and destination triangles
    let source_tri = ($r.triangles | where {|t| $t.id == $source} | first)
    let dest_tri = ($r.triangles | where {|t| $t.id == $destination} | first)
    
    if $source_tri == null {
        error make { msg: $"Source triangle '($source)' not found" }
    }
    if $dest_tri == null {
        error make { msg: $"Destination triangle '($destination)' not found" }
    }
    
    # Find common ancestor for hierarchical routing
    let common_ancestor = (find-common-ancestor $source $destination)
    
    # Route: source -> up to common ancestor -> down to destination
    let upward_path = (route-up-hierarchy $source $common_ancestor $r)
    let downward_path = (route-down-hierarchy $common_ancestor $destination $r)
    
    # Combine paths
    let full_path = ($upward_path | append ($downward_path | skip 1))
    
    # Calculate routing metrics
    let path_length = ($full_path | length)
    let hops = $path_length - 1
    
    # Build routing instructions
    let instructions = ($full_path | window 2 | each {|pair|
        {
            from: $pair.0
            to: $pair.1
            direction: (get-routing-direction $pair.0 $pair.1 $r)
        }
    })
    
    {
        source: $source
        destination: $destination
        path: $full_path
        hops: $hops
        common_ancestor: $common_ancestor
        instructions: $instructions
        multicast: $multicast
        priority: $priority
    }
}

# Multi-resolution routing (coarse-to-fine or fine-to-coarse)
export def "sierpinski route multi-res" [
    source: string             # Source address
    destination: string        # Destination address
    --resolution: string = "adaptive"  # coarse, fine, adaptive
    --router: record = {}      # Sierpinski router
]: [ nothing -> record ] {
    let r = (if ($router | is-empty) { $in } else { $router })
    
    match $resolution {
        "coarse" => {
            # Route at higher level (shorter path, less detail)
            let coarse_source = (get-parent-at-level $source 1)
            let coarse_dest = (get-parent-at-level $destination 1)
            sierpinski route $coarse_source $coarse_dest --router $r
        }
        "fine" => {
            # Route at full resolution
            sierpinski route $source $destination --router $r
        }
        "adaptive" => {
            # Start coarse, refine near destination
            let coarse_route = (sierpinski route multi-res $source $destination --resolution coarse --router $r)
            let refined_route = (refine-route-near-destination $coarse_route $source $destination $r)
            $refined_route
        }
        _ => {
            sierpinski route $source $destination --router $r
        }
    }
}

# Route with load balancing across multiple paths
export def "sierpinski route balanced" [
    source: string             # Source address
    destination: string        # Destination address
    --paths: int = 2           # Number of paths to find
    --router: record = {}      # Sierpinski router
]: [ nothing -> record ] {
    let r = (if ($router | is-empty) { $in } else { $router })
    
    mut alternative_paths = []
    
    # Find primary path
    let primary = (sierpinski route $source $destination --router $r)
    $alternative_paths = ($alternative_paths | append $primary)
    
    # Find alternative paths by using different common ancestors
    let source_ancestors = (get-ancestors $source)
    let dest_ancestors = (get-ancestors $destination)
    
    for ancestor in ($source_ancestors | append $dest_ancestors | uniq) {
        if ($alternative_paths | length) >= $paths { break }
        
        let alt_up = (route-up-hierarchy $source $ancestor $r)
        let alt_down = (route-down-hierarchy $ancestor $destination $r)
        let alt_path = ($alt_up | append ($alt_down | skip 1))
        
        # Check if this is a different path
        let is_new = ($alternative_paths | all {|p| (paths-differ $p.path $alt_path)})
        
        if $is_new {
            $alternative_paths = ($alternative_paths | append {
                source: $source
                destination: $destination
                path: $alt_path
                hops: (($alt_path | length) - 1)
                via: $ancestor
            })
        }
    }
    
    {
        primary: $primary
        alternatives: ($alternative_paths | skip 1)
        n_paths: ($alternative_paths | length)
        load_balancing: true
    }
}

# =============================================================================
# State Encoding/Decoding in Sierpinski Coordinates
# =============================================================================

# Encode a state vector into Sierpinski address
export def "sierpinski encode" [
    state: list                # State vector [x, y] or higher dimensional
    --router: record = {}      # Sierpinski router
    --precision: int = 5       # Address precision (levels)
]: [ list -> record ] {
    let r = (if ($router | is-empty) { $in } else { $router })
    
    # Map 2D state to Sierpinski triangle
    let point = (if ($state | length) >= 2 {
        [$state.0 $state.1]
    } else {
        [$state.0 0.0]
    })
    
    # Normalize to triangle space
    let normalized = (normalize-to-triangle $point $r.vertices)
    
    # Descend Sierpinski tree to find containing triangle
    let address = (descend-to-address $normalized $r.triangles $precision)
    
    # Compute barycentric coordinates within the triangle
    let triangle = ($r.triangles | where {|t| $t.id == $address} | first)
    let barycentric = (point-to-barycentric $normalized $triangle.vertices)
    
    # Convert to Sierpinski code (balanced ternary)
    let sierpinski_code = (address-to-code $address)
    
    {
        state: $state
        address: $address
        sierpinski_code: $sierpinski_code
        barycentric: $barycentric
        triangle: $triangle.centroid
        precision: $precision
        normalized_point: $normalized
    }
}

# Decode from Sierpinski representation back to state
export def "sierpinski decode" [
    address: string            # Sierpinski address
    --router: record = {}      # Sierpinski router
    --barycentric: list = [0.33 0.33 0.34]  # Barycentric coordinates
]: [ nothing -> record ] {
    let r = (if ($router | is-empty) { $in } else { $router })
    
    # Find triangle by address
    let triangle = ($r.triangles | where {|t| $t.id == $address} | first)
    
    if $triangle == null {
        error make { msg: $"Triangle '($address)' not found" }
    }
    
    # Convert barycentric to Cartesian
    let point = (barycentric-to-cartesian $barycentric $triangle.vertices)
    
    # Convert Sierpinski code back to address
    let decoded_address = (code-to-address $address)
    
    # Verify address matches
    let verification = ($decoded_address == $address)
    
    {
        address: $address
        decoded_address: $decoded_address
        point: $point
        triangle_vertices: $triangle.vertices
        triangle_level: $triangle.level
        verification: $verification
    }
}

# Encode state at multiple resolutions
export def "sierpinski encode multi" [
    state: list                # State vector
    --router: record = {}      # Sierpinski router
    --levels: list = [1 3 5]   # Levels to encode
]: [ list -> record ] {
    let r = (if ($router | is-empty) { $in } else { $router })
    
    mut encodings = {}
    
    for level in $levels {
        let encoding = (sierpinski encode $state --router $r --precision $level)
        $encodings = ($encodings | insert $level $encoding)
    }
    
    {
        state: $state
        encodings: $encodings
        coarse_to_fine: ($levels | each {|l| $encodings | get $l | get address})
    }
}

# =============================================================================
# Self-Similar Routing Tables
# =============================================================================

# Build self-similar routing tables for scalability
def build-routing-tables [triangles: list, depth: int]: [ nothing -> record ] {
    mut tables = {}
    
    # Build hierarchical routing table
    for level in 0..=$depth {
        let level_triangles = ($triangles | where {|t| $t.level == $level})
        
        for tri in $level_triangles {
            # Routing table entry for this triangle
            let entry = {
                id: $tri.id
                level: $level
                parent: $tri.parent
                children: $tri.children
                neighbors: $tri.neighbors
                centroid: $tri.centroid
                routing_rules: (generate-routing-rules $tri $triangles)
            }
            
            $tables = ($tables | insert $tri.id $entry)
        }
    }
    
    $tables
}

# Generate routing rules for a triangle
def generate-routing-rules [triangle: record, all_triangles: list]: [ nothing -> record ] {
    # Rules for routing to different destinations
    {
        to_parent: $triangle.parent
        to_children: $triangle.children
        to_neighbors: $triangle.neighbors
        upward_priority: (if $triangle.level > 0 { $triangle.parent } else { null })
        downward_strategy: "nearest-child"
    }
}

# Build address space mapping
def build-address-space [triangles: list, depth: int]: [ nothing -> record ] {
    # Map addresses to physical locations
    let leaf_triangles = ($triangles | where {|t| ($t.children | length) == 0})
    
    mut address_map = {}
    for tri in $leaf_triangles {
        $address_map = ($address_map | insert $tri.id {
            centroid: $tri.centroid
            level: $tri.level
            address_path: ($tri.id | split row ".")
        })
    }
    
    {
        depth: $depth
        leaf_addresses: ($address_map | columns)
        address_map: $address_map
        total_capacity: ($leaf_triangles | length)
    }
}

# Get routing table for a specific node
export def "sierpinski routing-table" [
    address: string            # Node address
    --router: record = {}      # Sierpinski router
]: [ nothing -> record ] {
    let r = (if ($router | is-empty) { $in } else { $router })
    
    $r.routing_tables | get -i $address | default {
        error: $"No routing table found for '($address)'"
    }
}

# Display routing statistics
export def "sierpinski stats" [
    --router: record = {}      # Sierpinski router
]: [ nothing -> record ] {
    let r = (if ($router | is-empty) { $in } else { $router })
    
    # Calculate statistics
    let nodes_per_level = (seq 0 $r.depth | each {|l|
        let count = ($r.triangles | where {|t| $t.level == $l} | length)
        {level: $l, nodes: $count}
    })
    
    let avg_neighbors = ($r.triangles | each {|t| $t.neighbors | length} | math avg)
    
    let diameter_estimate = ($r.depth * 2)  # Rough estimate
    
    {
        total_depth: $r.depth
        total_nodes: $r.total_nodes
        leaf_nodes: $r.leaf_nodes
        nodes_per_level: $nodes_per_level
        avg_neighbors: $avg_neighbors
        estimated_diameter: $diameter_estimate
        fractal_dimension: 1.585  # math log 3 / math log 2
    }
}

# =============================================================================
# Helper Functions
# =============================================================================

# Calculate centroid of triangle
def calculate-centroid [vertices: record]: [ nothing -> list ] {
    let x = ([$vertices.top.0 $vertices.left.0 $vertices.right.0] | math avg)
    let y = ([$vertices.top.1 $vertices.left.1 $vertices.right.1] | math avg)
    [$x $y]
}

# Calculate midpoint between two points
def midpoint [a: list, b: list]: [ nothing -> list ] {
    [(($a.0 + $b.0) / 2) (($a.1 + $b.1) / 2)]
}

# Check if two triangles share an edge
def triangles-share-edge [t1: record, t2: record]: [ nothing -> bool ] {
    let shared_vertices = count-shared-vertices $t1.vertices $t2.vertices
    $shared_vertices >= 2
}

# Count shared vertices between triangles
def count-shared-vertices [v1: record, v2: record]: [ nothing -> int ] {
    mut count = 0
    let v1_points = [$v1.top $v1.left $v1.right]
    let v2_points = [$v2.top $v2.left $v2.right]
    
    for p1 in $v1_points {
        for p2 in $v2_points {
            if (points-equal $p1 $p2) {
                $count = $count + 1
            }
        }
    }
    
    $count
}

# Check if points are equal (within tolerance)
def points-equal [p1: list, p2: list]: [ nothing -> bool ] {
    ((($p1.0 - $p2.0) | math abs) < 0.0001) and ((($p1.1 - $p2.1) | math abs) < 0.0001)
}

# Find shared edge name
def find-shared-edge [t1: record, t2: record]: [ nothing -> string ] {
    # Check which edges are shared
    if (midpoint $t1.vertices.top $t1.vertices.left | points-equal (midpoint $t2.vertices.top $t2.vertices.left)) {
        "left"
    } else if (midpoint $t1.vertices.top $t1.vertices.right | points-equal (midpoint $t2.vertices.top $t2.vertices.right)) {
        "right"
    } else {
        "bottom"
    }
}

# Power function for integers
def pow [base: int, exp: int]: [ nothing -> int ] {
    mut result = 1
    for _ in 0..<$exp {
        $result = $result * $base
    }
    $result
}

# Find common ancestor of two addresses
def find-common-ancestor [addr1: string, addr2: string]: [ nothing -> string ] {
    let parts1 = ($addr1 | split row ".")
    let parts2 = ($addr2 | split row ".")
    
    mut common = []
    for i in 0..<[(($parts1 | length)) (($parts2 | length))] {
        if ($parts1 | get $i) == ($parts2 | get $i) {
            $common = ($common | append ($parts1 | get $i))
        } else {
            break
        }
    }
    
    if ($common | length) == 0 {
        "0"
    } else {
        $common | str join "."
    }
}

# Route up hierarchy from source to ancestor
def route-up-hierarchy [source: string, ancestor: string, router: record]: [ nothing -> list ] {
    mut path = [$source]
    mut current = $source
    
    while $current != $ancestor and $current != null {
        let tri = ($router.triangles | where {|t| $t.id == $current} | first)
        $current = $tri.parent
        if $current != null {
            $path = ($path | append $current)
        }
    }
    
    $path
}

# Route down hierarchy from ancestor to destination
def route-down-hierarchy [ancestor: string, dest: string, router: record]: [ nothing -> list ] {
    # Build path from dest up to ancestor, then reverse
    mut upward = [$dest]
    mut current = $dest
    
    while $current != $ancestor and $current != null {
        let tri = ($router.triangles | where {|t| $t.id == $current} | first)
        $current = $tri.parent
        if $current != null {
            $upward = ($upward | append $current)
        }
    }
    
    $upward | reverse
}

# Get routing direction between adjacent nodes
def get-routing-direction [from: string, to: string, router: record]: [ nothing -> string ] {
    let from_tri = ($router.triangles | where {|t| $t.id == $from} | first)
    
    if $from_tri.parent == $to {
        "up"
    } else if $to in $from_tri.children {
        "down"
    } else if $to in ($from_tri.neighbors | values) {
        "sideways"
    } else {
        "unknown"
    }
}

# Get parent at specific level
def get-parent-at-level [address: string, target_level: int]: [ nothing -> string ] {
    let parts = ($address | split row ".")
    if ($parts | length) <= $target_level {
        $address
    } else {
        $parts | take ($target_level + 1) | str join "."
    }
}

# Refine route near destination
def refine-route-near-destination [coarse_route: record, source: string, dest: string, router: record]: [ nothing -> record ] {
    # Get fine-grained route for last few hops
    let fine_route = (sierpinski route $source $dest --router $router)
    
    # Blend: use coarse route for most of path, fine near destination
    let blend_point = ($coarse_route.path | length) - 2
    let blended_path = ($coarse_route.path | take $blend_point) | append ($fine_route.path | skip ($blend_point))
    
    $coarse_route | upsert path $blended_path | upsert refined true
}

# Get all ancestors of an address
def get-ancestors [address: string]: [ nothing -> list ] {
    let parts = ($address | split row ".")
    mut ancestors = []
    for i in 1..<($parts | length) {
        $ancestors = ($ancestors | append ($parts | take $i | str join "."))
    }
    $ancestors
}

# Check if two paths differ
def paths-differ [path1: list, path2: list]: [ nothing -> bool ] {
    if ($path1 | length) != ($path2 | length) {
        true
    } else {
        for i in 0..<($path1 | length) {
            if ($path1 | get $i) != ($path2 | get $i) {
                return true
            }
        }
        false
    }
}

# Normalize point to triangle space
def normalize-to-triangle [point: list, vertices: record]: [ nothing -> list ] {
    # Map point to triangle coordinate system
    # Simplified: just scale to unit triangle
    let center_x = ([$vertices.top.0 $vertices.left.0 $vertices.right.0] | math avg)
    let center_y = ([$vertices.top.1 $vertices.left.1 $vertices.right.1] | math avg)
    
    [($point.0 - $center_x) ($point.1 - $center_y)]
}

# Descend Sierpinski tree to find containing triangle
def descend-to-address [point: list, triangles: list, max_depth: int]: [ nothing -> string ] {
    mut current_id = "0"
    mut current_level = 0
    
    while $current_level < $max_depth {
        let current_tri = ($triangles | where {|t| $t.id == $current_id} | first)
        
        if ($current_tri.children | length) == 0 {
            break
        }
        
        # Find which child contains the point
        mut found = false
        for child_id in $current_tri.children {
            let child_tri = ($triangles | where {|t| $t.id == $child_id} | first)
            if (point-in-triangle $point $child_tri.vertices) {
                $current_id = $child_id
                $found = true
                break
            }
        }
        
        if not $found {
            break
        }
        
        $current_level = $current_level + 1
    }
    
    $current_id
}

# Check if point is inside triangle
def point-in-triangle [point: list, vertices: record]: [ nothing -> bool ] {
    let bary = (point-to-barycentric $point $vertices)
    ($bary.0 >= 0) and ($bary.1 >= 0) and ($bary.2 >= 0)
}

# Convert point to barycentric coordinates
def point-to-barycentric [point: list, vertices: record]: [ nothing -> list ] {
    let x = $point.0
    let y = $point.1
    
    let x1 = $vertices.top.0
    let y1 = $vertices.top.1
    let x2 = $vertices.left.0
    let y2 = $vertices.left.1
    let x3 = $vertices.right.0
    let y3 = $vertices.right.1
    
    let denom = ($y2 - $y3) * ($x1 - $x3) + ($x3 - $x2) * ($y1 - $y3)
    
    if ($denom | math abs) < 0.0001 {
        [0.33 0.33 0.34]
    } else {
        let w1 = (($y2 - $y3) * ($x - $x3) + ($x3 - $x2) * ($y - $y3)) / $denom
        let w2 = (($y3 - $y1) * ($x - $x3) + ($x1 - $x3) * ($y - $y3)) / $denom
        let w3 = 1.0 - $w1 - $w2
        [$w1 $w2 $w3]
    }
}

# Convert barycentric to Cartesian
def barycentric-to-cartesian [bary: list, vertices: record]: [ nothing -> list ] {
    let w1 = $bary.0
    let w2 = $bary.1
    let w3 = $bary.2
    
    let x = ($w1 * $vertices.top.0) + ($w2 * $vertices.left.0) + ($w3 * $vertices.right.0)
    let y = ($w1 * $vertices.top.1) + ($w2 * $vertices.left.1) + ($w3 * $vertices.right.1)
    
    [$x $y]
}

# Convert address to Sierpinski code (balanced ternary-like)
def address-to-code [address: string]: [ nothing -> string ] {
    let parts = ($address | split row ".")
    
    # Map to symbols: 0 -> T, 1 -> L, 2 -> R
    let symbols = ["T" "L" "R"]
    
    mut code = ""
    for part in ($parts | skip 1) {
        let idx = ($part | into int)
        $code = $code + ($symbols | get $idx)
    }
    
    $code
}

# Convert Sierpinski code back to address
def code-to-address [code: string]: [ nothing -> string ] {
    # Reverse mapping
    mut address = "0"
    
    for char in ($code | split chars) {
        let idx = match $char {
            "T" => "0"
            "L" => "1"
            "R" => "2"
            _ => "0"
        }
        $address = $address + "." + $idx
    }
    
    $address
}

# =============================================================================
# Advanced Routing Features
# =============================================================================

# Route with quality-of-service guarantees
export def "sierpinski route qos" [
    source: string             # Source address
    destination: string        # Destination address
    --router: record = {}      # Sierpinski router
    --latency: float = 10.0    # Maximum latency requirement
    --bandwidth: float = 100.0 # Minimum bandwidth requirement
    --reliability: float = 0.99 # Minimum reliability
]: [ nothing -> record ] {
    let r = (if ($router | is-empty) { $in } else { $router })
    
    # Find multiple paths and select based on QoS
    let paths = (sierpinski route balanced $source $destination --router $r --paths 3)
    
    # Evaluate each path against QoS requirements
    let evaluated = ($paths.alternatives | append $paths.primary | each {|p|
        let estimated_latency = ($p.hops * 2.0)  # 2ms per hop estimate
        let estimated_reliability = (math pow 0.99 $p.hops)
        
        {
            path: $p
            meets_latency: ($estimated_latency <= $latency)
            meets_reliability: ($estimated_reliability >= $reliability)
            qos_score: (if ($estimated_latency <= $latency) and ($estimated_reliability >= $reliability) {
                1.0 / $p.hops  # Prefer shorter paths
            } else {
                0.0
            })
        }
    })
    
    let best = ($evaluated | sort-by qos_score -r | first)
    
    {
        route: $best.path
        qos_met: ($best.meets_latency and $best.meets_reliability)
        latency_estimate: ($best.path.hops * 2.0)
        reliability_estimate: (math pow 0.99 $best.path.hops)
        alternatives_considered: ($evaluated | length)
    }
}

# Visualize Sierpinski routing structure (ASCII art)
export def "sierpinski visualize" [
    --router: record = {}      # Sierpinski router
    --level: int = 3           # Level to visualize
]: [ nothing -> string ] {
    let r = (if ($router | is-empty) { $in } else { $router })
    
    # Simple ASCII visualization of Sierpinski triangle
    let header = $"Sierpinski Router Structure (Level ($level))\n"
    let stats = $"Total nodes: ($r.total_nodes) | Leaf nodes: ($r.leaf_nodes)\n"
    let depth = $"Max depth: ($r.depth) | Fractal dimension: 1.585\n"
    
    # ASCII art of Sierpinski triangle (simplified)
    let art = "
         A
        ABA
       ABCBA
      ABCDCBA
     ABCDEDCBA
    -----------
    "
    
    $header + $stats + $depth + $art
}

# =============================================================================
# Aliases
# =============================================================================

export alias sierp-build = sierpinski build
export alias sierp-route = sierpinski route
export alias sierp-route-multi = sierpinski route multi-res
export alias sierp-route-bal = sierpinski route balanced
export alias sierp-encode = sierpinski encode
export alias sierp-decode = sierpinski decode
export alias sierp-encode-multi = sierpinski encode multi
export alias sierp-table = sierpinski routing-table
export alias sierp-stats = sierpinski stats
export alias sierp-route-qos = sierpinski route qos
export alias sierp-viz = sierpinski visualize
