// lexer — tokenizer for forge source files
//
// transforms source text into a stream of tokens, handling
// indentation-based blocks (INDENT/DEDENT), string interpolation,
// and all forge operators and keywords.

const std = @import("std");

test {
    _ = std;
}
