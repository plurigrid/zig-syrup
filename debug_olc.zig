const std = @import("std");
const geo = @import("src/geo.zig");

pub fn main() void {
    const d0 = std.math.pow(f64, 20.0, @as(f64, @floatFromInt(4 - 0/2)));
    std.debug.print("Digit 0 resolution: {d}\n", .{d0});
    // Should be 20^4 = 160000. 
    // Lat range is 180 deg (-90 to 90), mapped to 0..180? No, adj_lat is adj_lat + 90. So 0..180.
    // 160000? That's way too big for 180 degrees.
    
    // OLC encoding logic:
    // First pair is 20 degrees.
    // ENCODING_BASE is 20.
    // If pairResolution(0) is 20^4 = 160,000, that's wrong.
    
    // Correct OLC logic:
    // 5 pairs.
    // Pair 0 resolution: 20 degrees.
    // Pair 1: 1 degree.
    // Pair 2: 0.05 degree (1/20).
    // ...
    
    // Wait, pair 0 (digits 0,1) reduces the range by factor of 20?
    // No, OLC uses base 20.
    // 180 degrees / 20 = 9 degrees? No.
    // The first pair (2 chars) divides the world into 20x20 grid?
    // 180 lat / 20 = 9 deg height.
    // 360 lng / 20 = 18 deg width.
    
    // If pairResolution returns the "value" of the digit place:
    // It should be 20^(some power).
    
    // Let's check Google's OLC spec or implementation reference in comments?
    // "Reference: https://github.com/google/open-location-code"
    
    // If I look at the loop in encodeOlc:
    // const lat_digit = floor(lat_val / pairResolution(digit));
    // lat_val -= lat_digit * pairResolution(digit);
    
    // If lat_val starts at ~127 (37+90)
    // And first digit is '8' (index ?).
    // If pairResolution(0) is 20 degrees?
    // 127 / 20 = 6.35 -> digit 6 ('8' in 2345678.. 2=0,3=1,4=2,5=3,6=4,7=5,8=6).
    // So '8' corresponds to 6.
    
    // So pairResolution(0) should be 20.
    // pairResolution(2) should be 1.
    // pairResolution(4) should be 0.05.
    
    // My formula: 20^(4 - digit/2)
    // digit=0 -> 20^4 = 160,000. WRONG.
    // digit=2 -> 20^3 = 8,000.
    
    // I want:
    // digit=0 -> 20
    // digit=2 -> 1
    // digit=4 -> 1/20
    
    // 20^1 = 20.
    // 20^0 = 1.
    // 20^-1 = 0.05.
    
    // So exponent should be: 1 - digit/2.
    
    // Let's verify.
    // digit=0 -> 1-0 = 1. 20^1 = 20. Correct.
    // digit=2 -> 1-1 = 0. 20^0 = 1. Correct.
    // digit=4 -> 1-2 = -1. 20^-1 = 0.05. Correct.
    
    // Current code: 4 - digit/2.
    // 4 - 0 = 4. 20^4.
    
    // So the resolution is off by factor of 20^3 = 8000.
    // That explains why lat_val (127) / 160000 = 0.
    // So digit is 0 ('2').
    // Next iter, lat_val is still 127.
    // digit 2: res 20^3 = 8000. 127/8000 = 0. Digit 0 ('2').
    // ...
    // All digits are '2'.
}
