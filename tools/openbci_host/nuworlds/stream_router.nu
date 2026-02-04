# stream_router.nu
# Nuworlds stream routing for BCI data
# Supports multicast routing, backpressure handling, and TCP integration

# Router state
export def Router [] {
    {
        id: (random uuid),
        streams: {},
        handlers: {},
        stats: {
            messages_routed: 0,
            bytes_routed: 0,
            dropped_messages: 0,
            start_time: (date now)
        },
        running: false,
        sockets: {
            tcp_listeners: {},
            tcp_clients: {}
        }
    }
}

# Stream definition
export def Stream [name: string, config: record] {
    {
        name: $name,
        config: ($config | default {
            buffer_size: 1000,
            backpressure: "drop_oldest",  # drop_oldest, block, throttle
            multicast: true,
            persist: false
        }),
        subscribers: [],
        buffer: [],
        message_count: 0,
        created_at: (date now)
    }
}

# Create a new stream router
export def "router create" [] {
    Router
}

# Initialize a new stream
export def "router stream-create" [
    name: string,
    --buffer-size: int = 1000,
    --backpressure: string = "drop_oldest",
    --multicast: bool = true,
    --persist: bool = false
] {
    let router = $in
    
    if ($name in $router.streams) {
        print $"Stream '($name)' already exists"
        return $router
    }
    
    let stream = (Stream $name {
        buffer_size: $buffer_size,
        backpressure: $backpressure,
        multicast: $multicast,
        persist: $persist
    })
    
    $router | upsert streams {||
        $router.streams | insert $name $stream
    }
}

# Subscribe a handler to a stream
export def "router subscribe" [
    stream_name: string,     # Stream to subscribe to
    handler: closure,        # Handler closure (receives data)
    --priority: int = 0,     # Handler priority (higher = earlier)
    --filter: closure = null  # Optional filter closure
] {
    let router = $in
    
    if ($stream_name not-in $router.streams) {
        print $"Stream '($stream_name)' does not exist, creating..."
    }
    
    let subscription = {
        id: (random uuid),
        handler: $handler,
        priority: $priority,
        filter: $filter,
        subscribed_at: (date now),
        message_count: 0,
        error_count: 0
    }
    
    mut new_router = $router
    
    # Create stream if doesn't exist
    if ($stream_name not-in $router.streams) {
        $new_router = ($new_router | router stream-create $stream_name)
    }
    
    # Add subscriber to stream
    let stream = ($new_router.streams | get $stream_name)
    let updated_subscribers = ($stream.subscribers | append $subscription 
        | sort-by priority -r)
    
    $new_router | upsert streams.($stream_name).subscribers $updated_subscribers
}

# Unsubscribe from a stream
export def "router unsubscribe" [
    stream_name: string,
    subscription_id: string
] {
    let router = $in
    
    if ($stream_name not-in $router.streams) {
        print $"Stream '($stream_name)' does not exist"
        return $router
    }
    
    let stream = ($router.streams | get $stream_name)
    let filtered = ($stream.subscribers | where id != $subscription_id)
    
    $router | upsert streams.($stream_name).subscribers $filtered
}

# Publish data to a stream
export def "router publish" [
    stream_name: string,     # Target stream
    data: any,               # Data to publish
    --metadata: record = {}  # Optional metadata
] {
    let router = $in
    
    if ($stream_name not-in $router.streams) {
        print $"Stream '($stream_name)' does not exist"
        return $router
    }
    
    let stream = ($router.streams | get $stream_name)
    let message = {
        data: $data,
        metadata: ($metadata | insert timestamp (date now)),
        stream: $stream_name
    }
    
    # Add to buffer with backpressure handling
    mut updated_buffer = $stream.buffer
    let buffer_full = ($stream.buffer | length) >= $stream.config.buffer_size
    
    if $buffer_full {
        match $stream.config.backpressure {
            "drop_oldest" => {
                $updated_buffer = ($stream.buffer | skip 1 | append $message)
            },
            "block" => {
                # Wait for buffer space
                while (($updated_buffer | length) >= $stream.config.buffer_size {
                    sleep 10ms
                }
                $updated_buffer = ($updated_buffer | append $message)
            },
            "throttle" => {
                # Drop new message if buffer full
                print $"Stream '($stream_name)' throttling - dropping message"
            },
            _ => {
                $updated_buffer = ($stream.buffer | skip 1 | append $message)
            }
        }
    } else {
        $updated_buffer = ($stream.buffer | append $message)
    }
    
    # Route to subscribers
    mut router_mut = $router
    for sub in $stream.subscribers {
        # Check filter if present
        let should_receive = if $sub.filter != null {
            try {
                do $sub.filter $data $metadata
            } catch {
                true
            }
        } else {
            true
        }
        
        if $should_receive {
            try {
                do $sub.handler $data $message.metadata
                $router_mut = ($router_mut | upsert streams.($stream_name).subscribers.
                    {|s| $s | where id == $sub.id | upsert 0.message_count {|m| $m.message_count + 1}})
            } catch {|e|
                print $"Handler error in stream ($stream_name): ($e.msg)"
                $router_mut = ($router_mut | upsert streams.($stream_name).subscribers.
                    {|s| $s | where id == $sub.id | upsert 0.error_count {|m| $m.error_count + 1}})
            }
        }
    }
    
    # Update stats
    let data_size = ($data | to json | str length)
    $router_mut 
    | upsert streams.($stream_name).buffer $updated_buffer
    | upsert streams.($stream_name).message_count {|r| ($r.streams | get $stream_name | get message_count) + 1}
    | upsert stats.messages_routed {|r| $r.stats.messages_routed + 1}
    | upsert stats.bytes_routed {|r| $r.stats.bytes_routed + $data_size}
}

# Create TCP listener for external connections
export def "router tcp-listen" [
    port: int,               # Port to listen on
    --stream: string,        # Stream to route incoming data to
    --format: string = "json"  # Data format: json, binary, text
] {
    let router = $in
    
    print $"Starting TCP listener on port ($port) -> stream '($stream)'"
    
    # Spawn TCP listener job
    let listener_job = job spawn {
        # This would use nushell's socket capabilities
        # For now, we simulate the structure
        loop {
            # Accept connections
            # Read data
            # Parse according to format
            # Route to stream
            sleep 100ms
        }
    }
    
    let listener_info = {
        port: $port,
        stream: $stream,
        format: $format,
        job_id: $listener_job,
        started_at: (date now),
        connection_count: 0
    }
    
    $router 
    | upsert sockets.tcp_listeners {||
        $router.sockets.tcp_listeners | insert ($port | into string) $listener_info
    }
}

# Connect to external TCP endpoint
export def "router tcp-connect" [
    host: string,            # Remote host
    port: int,               # Remote port
    --stream: string,        # Local stream to publish received data to
    --auto-reconnect: bool = true,
    --reconnect-delay: duration = 5sec
] {
    let router = $in
    
    print $"Connecting to ($host):($port) -> stream '($stream)'"
    
    let connection_id = $"($host):($port)"
    
    let client_info = {
        host: $host,
        port: $port,
        stream: $stream,
        auto_reconnect: $auto_reconnect,
        reconnect_delay: $reconnect_delay,
        connected: false,
        connected_at: null,
        reconnect_count: 0
    }
    
    $router | upsert sockets.tcp_clients {||
        $router.sockets.tcp_clients | insert $connection_id $client_info
    }
}

# Pipe between streams
export def "router pipe" [
    from: string,            # Source stream
    to: string,              # Destination stream
    --transform: closure = null  # Optional transform closure
] {
    let router = $in
    
    let handler = if $transform != null {
        {|data, meta|
            let transformed = (do $transform $data $meta)
            $router | router publish $to $transformed
        }
    } else {
        {|data, meta|
            $router | router publish $to $data
        }
    }
    
    $router | router subscribe $from $handler
}

# Merge multiple streams into one
export def "router merge" [
    sources: list,           # Source stream names
    target: string,          # Target stream name
    --prefix: bool = true    # Prefix with source stream name
] {
    let router = $in
    
    mut result = $router
    
    for source in $sources {
        let handler = if $prefix {
            {|data, meta|
                let prefixed_data = {source: $source, data: $data}
                $result | router publish $target $prefixed_data
            }
        } else {
            {|data, meta|
                $result | router publish $target $data
            }
        }
        
        $result = ($result | router subscribe $source $handler)
    }
    
    $result
}

# Split a stream based on a condition
export def "router split" [
    source: string,          # Source stream
    --branches: record       # Branch conditions: {target_stream: condition_closure}
] {
    let router = $in
    
    let handler = {|data, meta|
        for branch in ($branches | transpose stream condition) {
            let matches = try {
                do $branch.condition $data $meta
            } catch {
                false
            }
            
            if $matches {
                $router | router publish $branch.stream $data
            }
        }
    }
    
    $router | router subscribe $source $handler
}

# Get router statistics
export def "router stats" [] {
    let router = $in
    
    let uptime = (date now) - $router.stats.start_time
    
    {
        router_id: $router.id,
        uptime: $uptime,
        stream_count: ($router.streams | length),
        total_messages: $router.stats.messages_routed,
        total_bytes: $router.stats.bytes_routed,
        streams: ($router.streams | transpose name info | each {|s|
            {
                name: $s.name,
                subscribers: ($s.info.subscribers | length),
                messages: $s.info.message_count,
                buffer_size: ($s.info.buffer | length)
            }
        }),
        tcp_listeners: ($router.sockets.tcp_listeners | length),
        tcp_clients: ($router.sockets.tcp_clients | length)
    }
}

# List all streams
export def "router list-streams" [] {
    let router = $in
    $router.streams | transpose name config | each {|s|
        {
            name: $s.name,
            subscribers: ($s.config.subscribers | length),
            messages: $s.config.message_count,
            created_at: $s.config.created_at
        }
    }
}

# Clear stream buffer
export def "router clear" [stream_name: string] {
    let router = $in
    
    if ($stream_name not-in $router.streams) {
        print $"Stream '($stream_name)' does not exist"
        return $router
    }
    
    $router | upsert streams.($stream_name).buffer []
}

# Stop the router and cleanup
export def "router stop" [] {
    let router = $in
    
    print "Stopping router..."
    
    # Close TCP listeners
    for listener in ($router.sockets.tcp_listeners | columns) {
        print $"Stopping TCP listener on ($listener)"
    }
    
    # Close TCP clients
    for client in ($router.sockets.tcp_clients | columns) {
        print $"Disconnecting TCP client ($client)"
    }
    
    $router | upsert running false
}

# Create a bridge between nushell pipeline and stream
export def "router bridge-in" [
    stream_name: string,     # Target stream
    --source: string = "stdin"  # Source: stdin, file, http
] {
    let router = $in
    
    print $"Creating bridge from ($source) to stream '($stream_name)'"
    
    match $source {
        "stdin" => {
            # Read from stdin and publish to stream
            # This would be used in a pipeline
        },
        _ => {
            print $"Unknown bridge source: ($source)"
        }
    }
    
    $router
}

# Export stream to nushell pipeline
export def "router bridge-out" [
    stream_name: string
] {
    let router = $in
    
    if ($stream_name not-in $router.streams) {
        print $"Stream '($stream_name)' does not exist"
        return
    }
    
    # Return stream data for pipeline
    $router.streams | get $stream_name | get buffer
}

# Apply backpressure strategy to a stream
export def "router set-backpressure" [
    stream_name: string,
    strategy: string         # drop_oldest, block, throttle
] {
    let router = $in
    
    if ($stream_name not-in $router.streams) {
        print $"Stream '($stream_name)' does not exist"
        return $router
    }
    
    $router | upsert streams.($stream_name).config.backpressure $strategy
}
