Test data from https://codeberg.org/vivicat/zig-syrup (Apache-2.0).
Used unmodified as a cross-implementation conformance oracle: zoo.bin is
canonical syrup wire produced by an independent implementation; our
decode -> esyrup -> encode chain must reproduce it byte-identically.
This 1-ulp-sensitive oracle caught a decimal->double mis-rounding in
vendored edn.c ('8.2' -> ...667, nearest ...666), corrected in
src/edn_bridge.zig by re-parsing float spans with std.fmt.parseFloat.
