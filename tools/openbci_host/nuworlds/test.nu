# test.nu
# Test suite for nuworlds BCI hypergraph module

use mod.nu *

def "test hypergraph basic" [] {
    print "Testing hypergraph basic operations..."
    
    # Create hypergraph
    let hg = (hypergraph new)
    assert ($hg.nodes | is-empty)
    assert ($hg.edges | is-empty)
    print "  ✓ Create empty hypergraph"
    
    # Add nodes
    let hg2 = ($hg | 
        hypergraph add-node "node1" "acquisition" {type: "source"} |
        hypergraph add-node "node2" "preprocessing" {type: "filter"}
    )
    assert (($hg2 | hypergraph list-nodes | length) == 2)
    print "  ✓ Add nodes"
    
    # Add edge
    let hg3 = ($hg2 | hypergraph add-edge "node1" "node2" {stream: "data"})
    assert (($hg3 | hypergraph list-edges | length) == 1)
    print "  ✓ Add edge"
    
    # Traverse
    let traversal = ($hg3 | hypergraph traverse "node1" --mode bfs)
    assert (($traversal | length) == 2)
    print "  ✓ Graph traversal"
    
    # Topological sort
    let order = ($hg3 | hypergraph topo-sort)
    assert ($order.0 == "node1")
    assert ($order.1 == "node2")
    print "  ✓ Topological sort"
    
    print "Hypergraph tests passed!"
}

def "test stream router" [] {
    print "Testing stream router..."
    
    # Create router
    mut router = (router create)
    assert (($router.streams | is-empty))
    print "  ✓ Create router"
    
    # Create stream
    $router = ($router | router stream-create "test_stream" --buffer-size 100)
    assert ("test_stream" in $router.streams)
    print "  ✓ Create stream"
    
    # Subscribe
    mut received = []
    $router = ($router | router subscribe "test_stream" {|data, meta|
        $received = ($received | append $data)
    })
    assert (($router.streams.test_stream.subscribers | length) == 1)
    print "  ✓ Subscribe handler"
    
    # Publish
    $router | router publish "test_stream" {value: 42}
    print "  ✓ Publish data"
    
    print "Stream router tests passed!"
}

def "test state manager" [] {
    print "Testing state manager..."
    
    # Create manager
    mut sm = (state new)
    assert ($sm.current_state == "unknown")
    print "  ✓ Create state manager"
    
    # Update state
    $sm = ($sm | state update "focused" --confidence 0.8)
    assert ($sm.current_state == "focused")
    assert ($sm.current_confidence == 0.8)
    print "  ✓ Update state"
    
    # Same state update (no transition)
    $sm = ($sm | state update "focused" --confidence 0.9)
    assert (($sm.transition_history | length) == 0)  # No new transition
    print "  ✓ Same state update (no transition)"
    
    # State transition
    $sm = ($sm | state update "relaxed" --confidence 0.7)
    assert ($sm.current_state == "relaxed")
    assert (($sm.transition_history | length) == 1)
    print "  ✓ State transition"
    
    # Get current state
    let current = ($sm | state current)
    assert ($current.state == "relaxed")
    print "  ✓ Get current state"
    
    print "State manager tests passed!"
}

def "test metrics" [] {
    print "Testing metrics collector..."
    
    # Create collector
    mut metrics = (metrics new)
    assert ($metrics.samples_processed == 0)
    print "  ✓ Create metrics collector"
    
    # Record latency
    $metrics = ($metrics | metrics record-latency "stream1" 5.0)
    $metrics = ($metrics | metrics record-latency "stream1" 6.0)
    assert ("stream1" in $metrics.stream_metrics)
    print "  ✓ Record latency"
    
    # Update channel
    $metrics = ($metrics | metrics update-channel "Fp1" --snr 12.5 --impedance 5.2)
    assert ("Fp1" in $metrics.signal_quality)
    assert ($metrics.signal_quality.Fp1.snr_db == 12.5)
    print "  ✓ Update channel metrics"
    
    # Get summary
    let summary = ($metrics | metrics summary)
    assert ($summary.streams != null)
    print "  ✓ Get summary"
    
    print "Metrics tests passed!"
}

def "test world integration" [] {
    print "Testing world integration..."
    
    # Create world
    let world = (world create "test_world")
    assert ($world.name == "test_world")
    print "  ✓ Create world"
    
    # Create BCI world
    let bci_world = (world create-bci --channels ["Fp1", "Fp2"])
    assert (($bci_world.entities | length) == 2)
    assert ("eeg_primary" in $bci_world.sensors)
    print "  ✓ Create BCI world"
    
    # Add sensor
    let world2 = ($world | world add-sensor "test_sensor" "eeg" --channels ["ch1"])
    assert ("test_sensor" in $world2.sensors)
    print "  ✓ Add sensor"
    
    # Update sensor
    let world3 = ($world2 | world update-sensor "test_sensor" {value: 100})
    assert ($world3.sensors.test_sensor.last_reading.value == 100)
    print "  ✓ Update sensor data"
    
    print "World integration tests passed!"
}

def "test bci pipeline" [] {
    print "Testing BCI pipeline..."
    
    # Create pipeline
    let config = {
        sample_rate: 250,
        channels: 4,
        classifier: "lda"
    }
    let pipeline = (bci-pipeline create --config $config)
    assert (($pipeline.nodes | length) == 5)  # 5 standard nodes
    print "  ✓ Create pipeline"
    
    # Check structure
    assert ("raw_acquisition" in $pipeline.nodes)
    assert ("filter" in $pipeline.nodes)
    assert ("feature_extract" in $pipeline.nodes)
    assert ("classify" in $pipeline.nodes)
    assert ("visualize" in $pipeline.nodes)
    print "  ✓ Pipeline structure"
    
    # Stats
    let stats = ($pipeline | hypergraph stats)
    assert ($stats.node_count == 5)
    print "  ✓ Pipeline stats"
    
    print "BCI pipeline tests passed!"
}

def run_all_tests [] {
    print "================================"
    print "Nuwolds BCI Module Test Suite"
    print "================================"
    print ""
    
    try {
        test hypergraph basic
        print ""
        
        test stream router
        print ""
        
        test state manager
        print ""
        
        test metrics
        print ""
        
        test world integration
        print ""
        
        test bci pipeline
        print ""
        
        print "================================"
        print "All tests passed! ✓"
        print "================================"
        true
    } catch {|e|
        print ""
        print "================================"
        print "Test failed!"
        print $"Error: ($e.msg)"
        print "================================"
        false
    }
}

# Run tests if executed directly
if ($env.CURRENT_FILE? | default "") == (scope frame 0 | get file? | default "") {
    run_all_tests
}
