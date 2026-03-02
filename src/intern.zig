// intern — string interning pool
//
// deduplicates strings so that equality checks become
// pointer comparisons. used for identifiers, keywords,
// and type names throughout the compiler.

const std = @import("std");

test {
    _ = std;
}
