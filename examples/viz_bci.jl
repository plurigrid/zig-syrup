using Pkg
Pkg.activate("Notnotcurses.jl")
using Notcurses
using JSON
using Dates

# Initialize Notcurses
nc = Notcurses.NotcursesObject()
std_plane = Notcurses.stdplane(nc)

# Create planes
# Header
header_plane = Notcurses.ncplane_create(std_plane, 
    y=0, x=0, rows=2, cols=60
)
Notcurses.putstr(header_plane, "=== BCI-Aptos Bridge (Zig -> Julia) ===")
Notcurses.putstr_yx(header_plane, 1, 0, "Waiting for data...")

# Focus Gauge
focus_plane = Notcurses.ncplane_create(std_plane,
    y=3, x=0, rows=3, cols=40
)

# Relax Gauge
relax_plane = Notcurses.ncplane_create(std_plane,
    y=7, x=0, rows=3, cols=40
)

# Log
log_plane = Notcurses.ncplane_create(std_plane,
    y=11, x=0, rows=15, cols=80
)

function draw_bar(plane, label, value, color_pair)
    Notcurses.erase(plane)
    Notcurses.putstr_yx(plane, 0, 0, "$label: $(round(value, digits=2))")
    
    width = 30
    filled = Int(floor(value * width))
    bar = repeat("█", filled) * repeat("░", width - filled)
    
    Notcurses.putstr_yx(plane, 1, 0, bar)
end

try
    # Read stdin line by line
    for line in eachline(stdin)
        try
            data = JSON.parse(line)
            
            focus = get(data, "focus", 0.0)
            relax = get(data, "relax", 0.0)
            action = get(data, "action", nothing)
            
            # Update Gauges
            draw_bar(focus_plane, "Focus", focus, nothing)
            draw_bar(relax_plane, "Relax", relax, nothing)
            
            # Update Log if action
            if action !== nothing
                ts = get(data, "timestamp", 0)
                conf = get(data, "confidence", 0.0)
                payload = get(data, "payload", "")
                
                # Truncate payload for display
                short_payload = length(payload) > 40 ? payload[1:40] * "..." : payload
                
                log_msg = "[$ts] ACTION: $action (Conf: $conf)\n  -> $short_payload\n"
                Notcurses.putstr(log_plane, log_msg)
            end
            
            Notcurses.render(nc)
            
        catch e
            # Ignore parse errors
        end
    end
finally
    Notcurses.stop(nc)
end
