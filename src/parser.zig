// parser — recursive descent parser for forge
//
// consumes tokens from the lexer and builds an AST.
// hand-written for full control over error messages
// and error recovery.

const std = @import("std");

test {
    _ = std;
}
