// parser — recursive descent parser for forge
//
// consumes tokens from the lexer and builds an AST.
// hand-written for full control over error messages
// and error recovery.
//
// design: pre-tokenize the full source via lexer.tokenize(),
// then walk the token array with arbitrary lookahead.
// all AST nodes are arena-allocated and freed in one shot.

const std = @import("std");
const ast = @import("ast.zig");
const lexer_mod = @import("lexer.zig");
const errors = @import("errors.zig");

const Token = lexer_mod.Token;
const TokenKind = lexer_mod.TokenKind;
const Lexer = lexer_mod.Lexer;
const Location = errors.Location;

/// errors that can occur during parsing.
/// just allocation failures — parse errors are collected in diagnostics.
pub const ParseError = std.mem.Allocator.Error;

pub const Parser = struct {
    tokens: []const Token,
    pos: u32,
    allocator: std.mem.Allocator,
    diagnostics: errors.DiagnosticList,
    source: []const u8,

    pub fn init(tokens: []const Token, source: []const u8, allocator: std.mem.Allocator) Parser {
        return .{
            .tokens = tokens,
            .pos = 0,
            .allocator = allocator,
            .diagnostics = errors.DiagnosticList.init(allocator, source),
            .source = source,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.diagnostics.deinit();
    }

    // ---------------------------------------------------------------
    // token navigation
    // ---------------------------------------------------------------
    // all of these skip comment tokens automatically.

    /// look at the current token without consuming it.
    fn peek(self: *const Parser) Token {
        var i = self.pos;
        while (i < self.tokens.len) {
            if (self.tokens[i].kind != .comment) return self.tokens[i];
            i += 1;
        }
        // past the end — return the last token (should be eof)
        return self.tokens[self.tokens.len - 1];
    }

    /// look ahead by `offset` non-comment tokens.
    fn peekAhead(self: *const Parser, offset: u32) Token {
        var i = self.pos;
        var skipped: u32 = 0;
        while (i < self.tokens.len) {
            if (self.tokens[i].kind != .comment) {
                if (skipped == offset) return self.tokens[i];
                skipped += 1;
            }
            i += 1;
        }
        return self.tokens[self.tokens.len - 1];
    }

    /// consume the current token and return it.
    fn advance(self: *Parser) Token {
        while (self.pos < self.tokens.len) {
            const tok = self.tokens[self.pos];
            self.pos += 1;
            if (tok.kind != .comment) return tok;
        }
        return self.tokens[self.tokens.len - 1];
    }

    /// check if the current token matches the expected kind.
    fn check(self: *const Parser, kind: TokenKind) bool {
        return self.peek().kind == kind;
    }

    /// if the current token matches, consume it and return true.
    fn match(self: *Parser, kind: TokenKind) bool {
        if (self.check(kind)) {
            _ = self.advance();
            return true;
        }
        return false;
    }

    /// consume a token of the expected kind, or emit an error.
    fn expect(self: *Parser, kind: TokenKind) ParseError!Token {
        const tok = self.peek();
        if (tok.kind == kind) {
            return self.advance();
        }
        try self.diagnostics.addError(
            tok.location,
            try std.fmt.allocPrint(self.allocator, "expected {s}, got {s}", .{
                @tagName(kind),
                @tagName(tok.kind),
            }),
        );
        return tok;
    }

    /// skip over newline tokens. useful inside arg lists, param lists, etc.
    fn skipNewlines(self: *Parser) void {
        while (self.peek().kind == .newline) {
            _ = self.advance();
        }
    }

    /// allocate a value on the arena and return a pointer to it.
    fn create(self: *Parser, comptime T: type, value: T) ParseError!*const T {
        const ptr = try self.allocator.create(T);
        @as(*T, @constCast(ptr)).* = value;
        return ptr;
    }

    /// skip tokens until we reach a synchronization point.
    /// used for error recovery — gets us back to a known state.
    fn synchronize(self: *Parser) void {
        while (self.peek().kind != .eof) {
            const kind = self.peek().kind;
            if (kind == .newline or kind == .dedent) {
                _ = self.advance();
                return;
            }
            _ = self.advance();
        }
    }

    // ---------------------------------------------------------------
    // type expressions
    // ---------------------------------------------------------------

    /// type_expr = base_type ["?"] | base_type "!" [type_expr]
    fn parseTypeExpr(self: *Parser) ParseError!*const ast.TypeExpr {
        const base = try self.parseBaseType();

        // optional: T?
        if (self.check(.question)) {
            const q_tok = self.advance();
            return self.create(ast.TypeExpr, .{
                .kind = .{ .optional = base },
                .location = Location.span(base.location, q_tok.location),
            });
        }

        // result: T! or T!E
        if (self.check(.bang)) {
            const bang_tok = self.advance();

            // check if there's an error type following
            // it's T!E only if the next token can start a type (identifier or fn or lparen)
            const next = self.peek().kind;
            if (next == .identifier or next == .kw_fn or next == .lparen) {
                const err_type = try self.parseTypeExpr();
                return self.create(ast.TypeExpr, .{
                    .kind = .{ .result = .{
                        .ok_type = base,
                        .err_type = err_type,
                    } },
                    .location = Location.span(base.location, err_type.location),
                });
            }

            return self.create(ast.TypeExpr, .{
                .kind = .{ .result = .{
                    .ok_type = base,
                    .err_type = null,
                } },
                .location = Location.span(base.location, bang_tok.location),
            });
        }

        return base;
    }

    /// base_type = IDENT ["[" type_list "]"]
    ///           | "(" type_list ")"
    ///           | fn_type
    fn parseBaseType(self: *Parser) ParseError!*const ast.TypeExpr {
        const tok = self.peek();

        // fn type: fn(Int, String) -> Bool
        if (tok.kind == .kw_fn) {
            return self.parseFnType();
        }

        // tuple type: (Int, String)
        if (tok.kind == .lparen) {
            return self.parseTupleType();
        }

        // named or generic type
        if (tok.kind == .identifier) {
            const name_tok = self.advance();

            // check for generic args: Type[T, U]
            if (self.check(.lbracket)) {
                _ = self.advance(); // skip [
                var args: std.ArrayList(*const ast.TypeExpr) = .empty;
                try args.append(self.allocator, try self.parseTypeExpr());
                while (self.match(.comma)) {
                    try args.append(self.allocator, try self.parseTypeExpr());
                }
                const end_tok = try self.expect(.rbracket);

                return self.create(ast.TypeExpr, .{
                    .kind = .{ .generic = .{
                        .name = name_tok.lexeme,
                        .args = try args.toOwnedSlice(self.allocator),
                    } },
                    .location = Location.span(name_tok.location, end_tok.location),
                });
            }

            return self.create(ast.TypeExpr, .{
                .kind = .{ .named = name_tok.lexeme },
                .location = name_tok.location,
            });
        }

        // unexpected token
        try self.diagnostics.addError(tok.location, "expected type");
        self.synchronize();
        return self.create(ast.TypeExpr, .{
            .kind = .{ .named = "" },
            .location = tok.location,
        });
    }

    /// fn_type = "fn" "(" [type_list] ")" ["->" type_expr]
    fn parseFnType(self: *Parser) ParseError!*const ast.TypeExpr {
        const fn_tok = self.advance(); // skip fn
        _ = try self.expect(.lparen);

        var params: std.ArrayList(*const ast.TypeExpr) = .empty;
        if (!self.check(.rparen)) {
            try params.append(self.allocator, try self.parseTypeExpr());
            while (self.match(.comma)) {
                try params.append(self.allocator, try self.parseTypeExpr());
            }
        }
        var end_loc = (try self.expect(.rparen)).location;

        var return_type: ?*const ast.TypeExpr = null;
        if (self.match(.arrow)) {
            const ret = try self.parseTypeExpr();
            return_type = ret;
            end_loc = ret.location;
        }

        return self.create(ast.TypeExpr, .{
            .kind = .{ .fn_type = .{
                .params = try params.toOwnedSlice(self.allocator),
                .return_type = return_type,
            } },
            .location = Location.span(fn_tok.location, end_loc),
        });
    }

    /// tuple type: "(" type "," { type "," } ")"
    fn parseTupleType(self: *Parser) ParseError!*const ast.TypeExpr {
        const lparen_tok = self.advance(); // skip (

        var types: std.ArrayList(*const ast.TypeExpr) = .empty;
        if (!self.check(.rparen)) {
            try types.append(self.allocator, try self.parseTypeExpr());
            while (self.match(.comma)) {
                if (self.check(.rparen)) break;
                try types.append(self.allocator, try self.parseTypeExpr());
            }
        }
        const rparen_tok = try self.expect(.rparen);

        return self.create(ast.TypeExpr, .{
            .kind = .{ .tuple = try types.toOwnedSlice(self.allocator) },
            .location = Location.span(lparen_tok.location, rparen_tok.location),
        });
    }

    // ---------------------------------------------------------------
    // expressions
    // ---------------------------------------------------------------

    /// entry point for expression parsing.
    pub fn parseExpression(self: *Parser) ParseError!*const ast.Expr {
        return self.parseOrExpr();
    }

    /// or_expr = and_expr { "or" and_expr }
    fn parseOrExpr(self: *Parser) ParseError!*const ast.Expr {
        var left = try self.parseAndExpr();
        while (self.check(.kw_or)) {
            _ = self.advance();
            const right = try self.parseAndExpr();
            left = try self.create(ast.Expr, .{
                .kind = .{ .binary = .{ .left = left, .op = .@"or", .right = right } },
                .location = Location.span(left.location, right.location),
            });
        }
        return left;
    }

    /// and_expr = not_expr { "and" not_expr }
    fn parseAndExpr(self: *Parser) ParseError!*const ast.Expr {
        var left = try self.parseNotExpr();
        while (self.check(.kw_and)) {
            _ = self.advance();
            const right = try self.parseNotExpr();
            left = try self.create(ast.Expr, .{
                .kind = .{ .binary = .{ .left = left, .op = .@"and", .right = right } },
                .location = Location.span(left.location, right.location),
            });
        }
        return left;
    }

    /// not_expr = "not" not_expr | comparison
    fn parseNotExpr(self: *Parser) ParseError!*const ast.Expr {
        if (self.check(.kw_not)) {
            const tok = self.advance();
            const operand = try self.parseNotExpr();
            return self.create(ast.Expr, .{
                .kind = .{ .unary = .{ .op = .not, .operand = operand } },
                .location = Location.span(tok.location, operand.location),
            });
        }
        return self.parseComparison();
    }

    /// comparison = pipe_expr { comp_op pipe_expr }
    fn parseComparison(self: *Parser) ParseError!*const ast.Expr {
        var left = try self.parsePipeExpr();
        while (true) {
            const op: ast.BinaryOp = switch (self.peek().kind) {
                .eq_eq => .eq,
                .bang_eq => .neq,
                .less => .lt,
                .greater => .gt,
                .less_eq => .lte,
                .greater_eq => .gte,
                else => break,
            };
            _ = self.advance();
            const right = try self.parsePipeExpr();
            left = try self.create(ast.Expr, .{
                .kind = .{ .binary = .{ .left = left, .op = op, .right = right } },
                .location = Location.span(left.location, right.location),
            });
        }
        return left;
    }

    /// pipe_expr = add_expr { "|" add_expr }
    fn parsePipeExpr(self: *Parser) ParseError!*const ast.Expr {
        var left = try self.parseAddExpr();
        while (self.check(.pipe)) {
            _ = self.advance();
            const right = try self.parseAddExpr();
            left = try self.create(ast.Expr, .{
                .kind = .{ .binary = .{ .left = left, .op = .pipe, .right = right } },
                .location = Location.span(left.location, right.location),
            });
        }
        return left;
    }

    /// add_expr = mul_expr { ("+" | "-") mul_expr }
    fn parseAddExpr(self: *Parser) ParseError!*const ast.Expr {
        var left = try self.parseMulExpr();
        while (true) {
            const op: ast.BinaryOp = switch (self.peek().kind) {
                .plus => .add,
                .minus => .sub,
                else => break,
            };
            _ = self.advance();
            const right = try self.parseMulExpr();
            left = try self.create(ast.Expr, .{
                .kind = .{ .binary = .{ .left = left, .op = op, .right = right } },
                .location = Location.span(left.location, right.location),
            });
        }
        return left;
    }

    /// mul_expr = unary_expr { ("*" | "/" | "%") unary_expr }
    fn parseMulExpr(self: *Parser) ParseError!*const ast.Expr {
        var left = try self.parseUnaryExpr();
        while (true) {
            const op: ast.BinaryOp = switch (self.peek().kind) {
                .star => .mul,
                .slash => .div,
                .percent => .mod,
                else => break,
            };
            _ = self.advance();
            const right = try self.parseUnaryExpr();
            left = try self.create(ast.Expr, .{
                .kind = .{ .binary = .{ .left = left, .op = op, .right = right } },
                .location = Location.span(left.location, right.location),
            });
        }
        return left;
    }

    /// unary_expr = "-" unary_expr | postfix_expr
    fn parseUnaryExpr(self: *Parser) ParseError!*const ast.Expr {
        if (self.check(.minus)) {
            const tok = self.advance();
            const operand = try self.parseUnaryExpr();
            return self.create(ast.Expr, .{
                .kind = .{ .unary = .{ .op = .negate, .operand = operand } },
                .location = Location.span(tok.location, operand.location),
            });
        }
        return self.parsePostfixExpr();
    }

    /// postfix_expr = primary { "?" | "!" | call | index | field_access | method_call }
    fn parsePostfixExpr(self: *Parser) ParseError!*const ast.Expr {
        var expr = try self.parsePrimary();

        while (true) {
            switch (self.peek().kind) {
                // unwrap: expr?
                .question => {
                    const tok = self.advance();
                    expr = try self.create(ast.Expr, .{
                        .kind = .{ .unwrap = expr },
                        .location = Location.span(expr.location, tok.location),
                    });
                },
                // try: expr!
                .bang => {
                    const tok = self.advance();
                    expr = try self.create(ast.Expr, .{
                        .kind = .{ .try_expr = expr },
                        .location = Location.span(expr.location, tok.location),
                    });
                },
                // call: expr(args)
                .lparen => {
                    expr = try self.parseCallExpr(expr);
                },
                // index: expr[index]
                .lbracket => {
                    _ = self.advance(); // skip [
                    const index = try self.parseExpression();
                    const end_tok = try self.expect(.rbracket);
                    expr = try self.create(ast.Expr, .{
                        .kind = .{ .index = .{ .object = expr, .index = index } },
                        .location = Location.span(expr.location, end_tok.location),
                    });
                },
                // field access or method call: expr.name or expr.name(args)
                .dot => {
                    _ = self.advance(); // skip .
                    const name_tok = try self.expect(.identifier);

                    // method call: expr.name(args)
                    if (self.check(.lparen)) {
                        _ = self.advance(); // skip (
                        const args = try self.parseArgList();
                        const end_tok = try self.expect(.rparen);
                        expr = try self.create(ast.Expr, .{
                            .kind = .{ .method_call = .{
                                .receiver = expr,
                                .method = name_tok.lexeme,
                                .args = args,
                            } },
                            .location = Location.span(expr.location, end_tok.location),
                        });
                    } else {
                        // field access: expr.name
                        expr = try self.create(ast.Expr, .{
                            .kind = .{ .field_access = .{
                                .object = expr,
                                .field = name_tok.lexeme,
                            } },
                            .location = Location.span(expr.location, name_tok.location),
                        });
                    }
                },
                else => break,
            }
        }
        return expr;
    }

    /// parse a function call's argument list (already past the opening paren).
    fn parseCallExpr(self: *Parser, callee: *const ast.Expr) ParseError!*const ast.Expr {
        _ = self.advance(); // skip (
        const args = try self.parseArgList();
        const end_tok = try self.expect(.rparen);
        return self.create(ast.Expr, .{
            .kind = .{ .call = .{ .callee = callee, .args = args } },
            .location = Location.span(callee.location, end_tok.location),
        });
    }

    /// parse comma-separated argument list: [name "="] expr { "," [name "="] expr }
    fn parseArgList(self: *Parser) ParseError![]const ast.Arg {
        var args: std.ArrayList(ast.Arg) = .empty;
        self.skipNewlines();
        if (self.check(.rparen)) return args.toOwnedSlice(self.allocator);

        try args.append(self.allocator, try self.parseArg());
        while (self.match(.comma)) {
            self.skipNewlines();
            if (self.check(.rparen)) break;
            try args.append(self.allocator, try self.parseArg());
        }
        self.skipNewlines();
        return args.toOwnedSlice(self.allocator);
    }

    /// parse a single argument: [name "="] expr
    fn parseArg(self: *Parser) ParseError!ast.Arg {
        const loc = self.peek().location;

        // check for named argument: name = expr
        if (self.peek().kind == .identifier and self.peekAhead(1).kind == .eq) {
            const name = self.advance().lexeme;
            _ = self.advance(); // skip =
            const value = try self.parseExpression();
            return .{ .name = name, .value = value, .location = loc };
        }

        const value = try self.parseExpression();
        return .{ .name = null, .value = value, .location = loc };
    }

    /// primary = literal | ident | self | grouped/tuple | list | map/set | if_expr | match_expr | lambda
    fn parsePrimary(self: *Parser) ParseError!*const ast.Expr {
        const tok = self.peek();

        switch (tok.kind) {
            // integer literal
            .int_lit => {
                _ = self.advance();
                return self.create(ast.Expr, .{
                    .kind = .{ .int_lit = tok.lexeme },
                    .location = tok.location,
                });
            },
            // float literal
            .float_lit => {
                _ = self.advance();
                return self.create(ast.Expr, .{
                    .kind = .{ .float_lit = tok.lexeme },
                    .location = tok.location,
                });
            },
            // string literal (no interpolation)
            .string_lit => {
                _ = self.advance();
                return self.create(ast.Expr, .{
                    .kind = .{ .string_lit = tok.lexeme },
                    .location = tok.location,
                });
            },
            // interpolated string
            .string_start => {
                return self.parseStringInterpolation();
            },
            // boolean literals
            .kw_true => {
                _ = self.advance();
                return self.create(ast.Expr, .{
                    .kind = .{ .bool_lit = true },
                    .location = tok.location,
                });
            },
            .kw_false => {
                _ = self.advance();
                return self.create(ast.Expr, .{
                    .kind = .{ .bool_lit = false },
                    .location = tok.location,
                });
            },
            // none
            .kw_none => {
                _ = self.advance();
                return self.create(ast.Expr, .{
                    .kind = .none_lit,
                    .location = tok.location,
                });
            },
            // self
            .kw_self => {
                _ = self.advance();
                return self.create(ast.Expr, .{
                    .kind = .self_expr,
                    .location = tok.location,
                });
            },
            // identifier
            .identifier => {
                _ = self.advance();
                return self.create(ast.Expr, .{
                    .kind = .{ .ident = tok.lexeme },
                    .location = tok.location,
                });
            },
            // grouped expression or tuple: (expr) or (expr, expr, ...)
            .lparen => {
                return self.parseGroupedOrTuple();
            },
            // list literal: [expr, expr, ...]
            .lbracket => {
                return self.parseListLiteral();
            },
            // map or set literal: {k: v, ...} or {x, y, ...}
            .lbrace => {
                return self.parseMapOrSetLiteral();
            },
            // if expression
            .kw_if => {
                return self.parseIfExpr();
            },
            // match expression
            .kw_match => {
                return self.parseMatchExpr();
            },
            // lambda: fn(params) => expr  or  fn(params): block
            .kw_fn => {
                return self.parseLambda();
            },
            else => {
                try self.diagnostics.addError(tok.location, "expected expression");
                self.synchronize();
                return self.create(ast.Expr, .{
                    .kind = .err,
                    .location = tok.location,
                });
            },
        }
    }

    /// parse grouped expression or tuple: (expr) or (expr,) or (expr, expr)
    fn parseGroupedOrTuple(self: *Parser) ParseError!*const ast.Expr {
        const lparen = self.advance(); // skip (
        self.skipNewlines();

        // empty tuple: ()
        if (self.check(.rparen)) {
            const rparen = self.advance();
            return self.create(ast.Expr, .{
                .kind = .{ .tuple = &.{} },
                .location = Location.span(lparen.location, rparen.location),
            });
        }

        const first = try self.parseExpression();
        self.skipNewlines();

        // tuple with trailing comma or multiple elements
        if (self.check(.comma)) {
            var elements: std.ArrayList(*const ast.Expr) = .empty;
            try elements.append(self.allocator, first);
            while (self.match(.comma)) {
                self.skipNewlines();
                if (self.check(.rparen)) break;
                try elements.append(self.allocator, try self.parseExpression());
                self.skipNewlines();
            }
            const rparen = try self.expect(.rparen);
            return self.create(ast.Expr, .{
                .kind = .{ .tuple = try elements.toOwnedSlice(self.allocator) },
                .location = Location.span(lparen.location, rparen.location),
            });
        }

        // grouped: (expr)
        const rparen = try self.expect(.rparen);
        return self.create(ast.Expr, .{
            .kind = .{ .grouped = first },
            .location = Location.span(lparen.location, rparen.location),
        });
    }

    /// list literal: [expr, expr, ...]
    fn parseListLiteral(self: *Parser) ParseError!*const ast.Expr {
        const lbracket = self.advance(); // skip [
        var elements: std.ArrayList(*const ast.Expr) = .empty;
        self.skipNewlines();

        if (!self.check(.rbracket)) {
            try elements.append(self.allocator, try self.parseExpression());
            while (self.match(.comma)) {
                self.skipNewlines();
                if (self.check(.rbracket)) break;
                try elements.append(self.allocator, try self.parseExpression());
            }
        }
        self.skipNewlines();
        const rbracket = try self.expect(.rbracket);
        return self.create(ast.Expr, .{
            .kind = .{ .list = try elements.toOwnedSlice(self.allocator) },
            .location = Location.span(lbracket.location, rbracket.location),
        });
    }

    /// map or set literal. {} = empty map, {k: v} = map, {x} = set
    fn parseMapOrSetLiteral(self: *Parser) ParseError!*const ast.Expr {
        const lbrace = self.advance(); // skip {
        self.skipNewlines();

        // empty map: {}
        if (self.check(.rbrace)) {
            const rbrace = self.advance();
            return self.create(ast.Expr, .{
                .kind = .{ .map = &.{} },
                .location = Location.span(lbrace.location, rbrace.location),
            });
        }

        // parse first expression to determine map vs set
        const first = try self.parseExpression();
        self.skipNewlines();

        // map: first expression followed by ":"
        if (self.check(.colon)) {
            _ = self.advance(); // skip :
            var entries: std.ArrayList(ast.MapEntry) = .empty;
            const first_value = try self.parseExpression();
            try entries.append(self.allocator, .{
                .key = first,
                .value = first_value,
                .location = first.location,
            });

            while (self.match(.comma)) {
                self.skipNewlines();
                if (self.check(.rbrace)) break;
                const key = try self.parseExpression();
                _ = try self.expect(.colon);
                const value = try self.parseExpression();
                try entries.append(self.allocator, .{
                    .key = key,
                    .value = value,
                    .location = key.location,
                });
            }
            self.skipNewlines();
            const rbrace = try self.expect(.rbrace);
            return self.create(ast.Expr, .{
                .kind = .{ .map = try entries.toOwnedSlice(self.allocator) },
                .location = Location.span(lbrace.location, rbrace.location),
            });
        }

        // set: {x} or {x, y, ...}
        var elements: std.ArrayList(*const ast.Expr) = .empty;
        try elements.append(self.allocator, first);
        while (self.match(.comma)) {
            self.skipNewlines();
            if (self.check(.rbrace)) break;
            try elements.append(self.allocator, try self.parseExpression());
        }
        self.skipNewlines();
        const rbrace = try self.expect(.rbrace);
        return self.create(ast.Expr, .{
            .kind = .{ .set = try elements.toOwnedSlice(self.allocator) },
            .location = Location.span(lbrace.location, rbrace.location),
        });
    }

    /// if expression: if cond: expr {elif cond: expr} else: expr
    fn parseIfExpr(self: *Parser) ParseError!*const ast.Expr {
        const if_tok = self.advance(); // skip if
        const condition = try self.parseExpression();
        _ = try self.expect(.colon);
        const then_expr = try self.parseExpression();

        var elifs: std.ArrayList(ast.ElifExprBranch) = .empty;
        while (self.check(.kw_elif)) {
            const elif_tok = self.advance();
            const elif_cond = try self.parseExpression();
            _ = try self.expect(.colon);
            const elif_expr = try self.parseExpression();
            try elifs.append(self.allocator, .{
                .condition = elif_cond,
                .expr = elif_expr,
                .location = elif_tok.location,
            });
        }

        _ = try self.expect(.kw_else);
        _ = try self.expect(.colon);
        const else_expr = try self.parseExpression();

        return self.create(ast.Expr, .{
            .kind = .{ .if_expr = .{
                .condition = condition,
                .then_expr = then_expr,
                .elif_branches = try elifs.toOwnedSlice(self.allocator),
                .else_expr = else_expr,
            } },
            .location = Location.span(if_tok.location, else_expr.location),
        });
    }

    /// match expression: match subject: NEWLINE INDENT {arm NEWLINE} DEDENT
    fn parseMatchExpr(self: *Parser) ParseError!*const ast.Expr {
        const match_tok = self.advance(); // skip match
        const subject = try self.parseExpression();
        _ = try self.expect(.colon);
        _ = try self.expect(.newline);
        _ = try self.expect(.indent);

        var arms: std.ArrayList(ast.MatchArm) = .empty;
        while (!self.check(.dedent) and !self.check(.eof)) {
            const arm = try self.parseMatchArm();
            try arms.append(self.allocator, arm);
            if (self.check(.newline)) _ = self.advance();
        }
        const end_tok = try self.expect(.dedent);

        return self.create(ast.Expr, .{
            .kind = .{ .match_expr = .{
                .subject = subject,
                .arms = try arms.toOwnedSlice(self.allocator),
            } },
            .location = Location.span(match_tok.location, end_tok.location),
        });
    }

    /// match arm: pattern ["if" expr] "=>" (expr | block)
    fn parseMatchArm(self: *Parser) ParseError!ast.MatchArm {
        const loc = self.peek().location;
        const pattern = try self.parsePattern();

        var guard: ?*const ast.Expr = null;
        if (self.check(.kw_if)) {
            _ = self.advance();
            guard = try self.parseExpression();
        }

        _ = try self.expect(.fat_arrow);

        // the body is either an inline expression or a block
        const body: ast.MatchBody = if (self.check(.newline))
            .{ .block = try self.parseBlock() }
        else
            .{ .expr = try self.parseExpression() };

        return .{
            .pattern = pattern,
            .guard = guard,
            .body = body,
            .location = loc,
        };
    }

    /// lambda: fn(params) => expr | fn(params): block
    fn parseLambda(self: *Parser) ParseError!*const ast.Expr {
        const fn_tok = self.advance(); // skip fn

        // if next token is an identifier, this is a fn declaration, not a lambda.
        // but in expression context we treat it as a lambda.
        // lambdas always have ( immediately after fn.
        _ = try self.expect(.lparen);
        const params = try self.parseLambdaParams();
        _ = try self.expect(.rparen);

        // short form: fn(x) => expr
        if (self.check(.fat_arrow)) {
            _ = self.advance();
            const body_expr = try self.parseExpression();
            return self.create(ast.Expr, .{
                .kind = .{ .lambda = .{
                    .params = params,
                    .body = .{ .expr = body_expr },
                } },
                .location = Location.span(fn_tok.location, body_expr.location),
            });
        }

        // block form: fn(x): block
        if (self.check(.colon)) {
            const body = try self.parseBlock();
            return self.create(ast.Expr, .{
                .kind = .{ .lambda = .{
                    .params = params,
                    .body = .{ .block = body },
                } },
                .location = Location.span(fn_tok.location, body.location),
            });
        }

        try self.diagnostics.addError(self.peek().location, "expected '=>' or ':' after lambda parameters");
        return self.create(ast.Expr, .{
            .kind = .err,
            .location = fn_tok.location,
        });
    }

    /// parse lambda parameter list (simplified — no defaults).
    fn parseLambdaParams(self: *Parser) ParseError![]const ast.Param {
        var params: std.ArrayList(ast.Param) = .empty;
        if (self.check(.rparen)) return params.toOwnedSlice(self.allocator);

        try params.append(self.allocator, try self.parseLambdaParam());
        while (self.match(.comma)) {
            try params.append(self.allocator, try self.parseLambdaParam());
        }
        return params.toOwnedSlice(self.allocator);
    }

    /// parse a single lambda param: [mut] [ref] name [: type]
    fn parseLambdaParam(self: *Parser) ParseError!ast.Param {
        const loc = self.peek().location;
        const is_mut = self.match(.kw_mut);
        const is_ref = self.match(.kw_ref);
        const name_tok = try self.expect(.identifier);

        var type_expr: ?*const ast.TypeExpr = null;
        if (self.match(.colon)) {
            type_expr = try self.parseTypeExpr();
        }

        return .{
            .name = name_tok.lexeme,
            .type_expr = type_expr,
            .default = null,
            .is_mut = is_mut,
            .is_ref = is_ref,
            .location = loc,
        };
    }

    /// string interpolation: string_start {interp_expr (string_mid | string_end)}
    fn parseStringInterpolation(self: *Parser) ParseError!*const ast.Expr {
        const start_tok = self.advance(); // consume string_start
        var parts: std.ArrayList(ast.StringPart) = .empty;

        // add the leading string text
        if (start_tok.lexeme.len > 0) {
            try parts.append(self.allocator, .{ .literal = start_tok.lexeme });
        }

        var end_loc = start_tok.location;

        while (true) {
            // expect an interpolation expression
            if (self.check(.interpolation_expr)) {
                const interp_tok = self.advance();
                // sub-lex and sub-parse the interpolation expression
                const expr = try self.parseInterpolationExpr(interp_tok);
                try parts.append(self.allocator, .{ .expr = expr });
                end_loc = interp_tok.location;
            }

            // string_mid means more interpolations follow
            if (self.check(.string_mid)) {
                const mid_tok = self.advance();
                if (mid_tok.lexeme.len > 0) {
                    try parts.append(self.allocator, .{ .literal = mid_tok.lexeme });
                }
                end_loc = mid_tok.location;
                continue;
            }

            // string_end means we're done
            if (self.check(.string_end)) {
                const end_tok = self.advance();
                if (end_tok.lexeme.len > 0) {
                    try parts.append(self.allocator, .{ .literal = end_tok.lexeme });
                }
                end_loc = end_tok.location;
                break;
            }

            // unexpected token — error recovery
            break;
        }

        return self.create(ast.Expr, .{
            .kind = .{ .string_interp = .{
                .parts = try parts.toOwnedSlice(self.allocator),
            } },
            .location = Location.span(start_tok.location, end_loc),
        });
    }

    /// sub-lex and sub-parse an interpolation expression token.
    /// the lexer gives us the raw text between { and }, we need to
    /// lex it into tokens and parse it as an expression.
    fn parseInterpolationExpr(self: *Parser, interp_tok: Token) ParseError!*const ast.Expr {
        var lex = Lexer.init(interp_tok.lexeme, self.allocator) catch {
            return self.create(ast.Expr, .{
                .kind = .err,
                .location = interp_tok.location,
            });
        };
        defer lex.deinit();

        const sub_tokens = lex.tokenize() catch {
            return self.create(ast.Expr, .{
                .kind = .err,
                .location = interp_tok.location,
            });
        };

        // create a sub-parser for the interpolation expression
        var sub_parser = Parser.init(sub_tokens, interp_tok.lexeme, self.allocator);
        // don't deinit sub_parser.diagnostics — we share the allocator

        const expr = sub_parser.parseExpression() catch {
            return self.create(ast.Expr, .{
                .kind = .err,
                .location = interp_tok.location,
            });
        };
        return expr;
    }

    // ---------------------------------------------------------------
    // patterns (forward declaration — used by match arms)
    // ---------------------------------------------------------------

    /// parse a pattern. full implementation in the next commit,
    /// but match expressions need a basic version.
    fn parsePattern(self: *Parser) ParseError!ast.Pattern {
        const tok = self.peek();

        switch (tok.kind) {
            .underscore => {
                _ = self.advance();
                return .{ .kind = .wildcard, .location = tok.location };
            },
            .int_lit => {
                _ = self.advance();
                return .{ .kind = .{ .int_lit = tok.lexeme }, .location = tok.location };
            },
            .float_lit => {
                _ = self.advance();
                return .{ .kind = .{ .float_lit = tok.lexeme }, .location = tok.location };
            },
            .string_lit => {
                _ = self.advance();
                return .{ .kind = .{ .string_lit = tok.lexeme }, .location = tok.location };
            },
            .kw_true => {
                _ = self.advance();
                return .{ .kind = .{ .bool_lit = true }, .location = tok.location };
            },
            .kw_false => {
                _ = self.advance();
                return .{ .kind = .{ .bool_lit = false }, .location = tok.location };
            },
            .kw_none => {
                _ = self.advance();
                return .{ .kind = .none_lit, .location = tok.location };
            },
            .identifier => {
                _ = self.advance();
                // check for qualified variant: Type.Variant or Type.Variant(fields)
                if (self.check(.dot)) {
                    _ = self.advance();
                    const variant_tok = try self.expect(.identifier);

                    if (self.check(.lparen)) {
                        _ = self.advance();
                        var fields: std.ArrayList(ast.Pattern) = .empty;
                        if (!self.check(.rparen)) {
                            try fields.append(self.allocator, try self.parsePattern());
                            while (self.match(.comma)) {
                                try fields.append(self.allocator, try self.parsePattern());
                            }
                        }
                        const end_tok = try self.expect(.rparen);
                        return .{
                            .kind = .{ .variant = .{
                                .type_name = tok.lexeme,
                                .variant = variant_tok.lexeme,
                                .fields = try fields.toOwnedSlice(self.allocator),
                            } },
                            .location = Location.span(tok.location, end_tok.location),
                        };
                    }

                    return .{
                        .kind = .{ .variant = .{
                            .type_name = tok.lexeme,
                            .variant = variant_tok.lexeme,
                            .fields = &.{},
                        } },
                        .location = Location.span(tok.location, variant_tok.location),
                    };
                }
                return .{ .kind = .{ .binding = tok.lexeme }, .location = tok.location };
            },
            .lparen => {
                _ = self.advance();
                var patterns: std.ArrayList(ast.Pattern) = .empty;
                if (!self.check(.rparen)) {
                    try patterns.append(self.allocator, try self.parsePattern());
                    while (self.match(.comma)) {
                        try patterns.append(self.allocator, try self.parsePattern());
                    }
                }
                const end_tok = try self.expect(.rparen);
                return .{
                    .kind = .{ .tuple = try patterns.toOwnedSlice(self.allocator) },
                    .location = Location.span(tok.location, end_tok.location),
                };
            },
            else => {
                try self.diagnostics.addError(tok.location, "expected pattern");
                self.synchronize();
                return .{ .kind = .wildcard, .location = tok.location };
            },
        }
    }

    // ---------------------------------------------------------------
    // blocks (forward declaration — used by match arms and lambdas)
    // ---------------------------------------------------------------

    /// placeholder for block parsing — full implementation in next commit.
    fn parseBlock(self: *Parser) ParseError!ast.Block {
        const loc = self.peek().location;
        _ = try self.expect(.newline);
        _ = try self.expect(.indent);

        // skip everything until we find the matching dedent
        var depth: u32 = 1;
        while (depth > 0 and self.peek().kind != .eof) {
            if (self.peek().kind == .indent) depth += 1;
            if (self.peek().kind == .dedent) depth -= 1;
            if (depth > 0) _ = self.advance();
        }
        if (self.check(.dedent)) _ = self.advance();

        return .{ .stmts = &.{}, .location = loc };
    }
};

// ---------------------------------------------------------------
// tests
// ---------------------------------------------------------------

const testing = std.testing;

/// helper: lex source, create parser with arena allocator.
/// the arena owns all AST nodes — freed in one shot on deinit.
/// the arena is heap-allocated so the allocator pointer stays stable
/// when this struct is returned by value.
const TestParser = struct {
    parser: Parser,
    tokens: []Token,
    arena: *std.heap.ArenaAllocator,

    fn deinit(self: *TestParser) void {
        self.parser.deinit();
        testing.allocator.free(self.tokens);
        self.arena.deinit();
        testing.allocator.destroy(self.arena);
    }
};

fn testParser(source: []const u8) !TestParser {
    var lex = try Lexer.init(source, testing.allocator);
    defer lex.deinit();

    const tokens = try lex.tokenize();
    const arena = try testing.allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(testing.allocator);

    return .{
        .parser = Parser.init(tokens, source, arena.allocator()),
        .tokens = tokens,
        .arena = arena,
    };
}

test "parse simple named type" {
    var result = try testParser("Int");
    defer result.deinit();

    const ty = try result.parser.parseTypeExpr();
    try testing.expect(ty.kind == .named);
    try testing.expectEqualStrings("Int", ty.kind.named);
}

test "parse generic type" {
    var result = try testParser("List[Int]");
    defer result.deinit();

    const ty = try result.parser.parseTypeExpr();
    try testing.expect(ty.kind == .generic);
    try testing.expectEqualStrings("List", ty.kind.generic.name);
    try testing.expectEqual(@as(usize, 1), ty.kind.generic.args.len);
}

test "parse multi-arg generic type" {
    var result = try testParser("Map[String, Int]");
    defer result.deinit();

    const ty = try result.parser.parseTypeExpr();
    try testing.expect(ty.kind == .generic);
    try testing.expectEqualStrings("Map", ty.kind.generic.name);
    try testing.expectEqual(@as(usize, 2), ty.kind.generic.args.len);
}

test "parse optional type" {
    var result = try testParser("Int?");
    defer result.deinit();

    const ty = try result.parser.parseTypeExpr();
    try testing.expect(ty.kind == .optional);
    try testing.expect(ty.kind.optional.kind == .named);
    try testing.expectEqualStrings("Int", ty.kind.optional.kind.named);
}

test "parse result type" {
    var result = try testParser("Int!");
    defer result.deinit();

    const ty = try result.parser.parseTypeExpr();
    try testing.expect(ty.kind == .result);
    try testing.expect(ty.kind.result.err_type == null);
}

test "parse result type with error type" {
    var result = try testParser("Int!ParseError");
    defer result.deinit();

    const ty = try result.parser.parseTypeExpr();
    try testing.expect(ty.kind == .result);
    try testing.expect(ty.kind.result.err_type != null);
    try testing.expectEqualStrings("ParseError", ty.kind.result.err_type.?.kind.named);
}

test "parse fn type" {
    var result = try testParser("fn(Int, String) -> Bool");
    defer result.deinit();

    const ty = try result.parser.parseTypeExpr();
    try testing.expect(ty.kind == .fn_type);
    try testing.expectEqual(@as(usize, 2), ty.kind.fn_type.params.len);
    try testing.expect(ty.kind.fn_type.return_type != null);
}

test "parse fn type no return" {
    var result = try testParser("fn(Int)");
    defer result.deinit();

    const ty = try result.parser.parseTypeExpr();
    try testing.expect(ty.kind == .fn_type);
    try testing.expect(ty.kind.fn_type.return_type == null);
}

test "parse tuple type" {
    var result = try testParser("(Int, String, Bool)");
    defer result.deinit();

    const ty = try result.parser.parseTypeExpr();
    try testing.expect(ty.kind == .tuple);
    try testing.expectEqual(@as(usize, 3), ty.kind.tuple.len);
}

test "parse nested generic type" {
    var result = try testParser("List[Option[Int]]");
    defer result.deinit();

    const ty = try result.parser.parseTypeExpr();
    try testing.expect(ty.kind == .generic);
    try testing.expectEqualStrings("List", ty.kind.generic.name);

    const inner = ty.kind.generic.args[0];
    try testing.expect(inner.kind == .generic);
    try testing.expectEqualStrings("Option", inner.kind.generic.name);
}

// -- expression tests --

test "parse integer literal" {
    var result = try testParser("42");
    defer result.deinit();

    const expr = try result.parser.parseExpression();
    try testing.expect(expr.kind == .int_lit);
    try testing.expectEqualStrings("42", expr.kind.int_lit);
}

test "parse string literal" {
    var result = try testParser("\"hello\"");
    defer result.deinit();

    const expr = try result.parser.parseExpression();
    try testing.expect(expr.kind == .string_lit);
}

test "parse boolean literals" {
    var t = try testParser("true");
    defer t.deinit();
    const e1 = try t.parser.parseExpression();
    try testing.expect(e1.kind == .bool_lit);
    try testing.expectEqual(true, e1.kind.bool_lit);

    var f = try testParser("false");
    defer f.deinit();
    const e2 = try f.parser.parseExpression();
    try testing.expectEqual(false, e2.kind.bool_lit);
}

test "parse none literal" {
    var result = try testParser("none");
    defer result.deinit();

    const expr = try result.parser.parseExpression();
    try testing.expect(expr.kind == .none_lit);
}

test "parse identifier" {
    var result = try testParser("foo");
    defer result.deinit();

    const expr = try result.parser.parseExpression();
    try testing.expect(expr.kind == .ident);
    try testing.expectEqualStrings("foo", expr.kind.ident);
}

test "parse binary arithmetic" {
    var result = try testParser("1 + 2 * 3");
    defer result.deinit();

    const expr = try result.parser.parseExpression();
    // should be (1 + (2 * 3)) due to precedence
    try testing.expect(expr.kind == .binary);
    try testing.expect(expr.kind.binary.op == .add);
    try testing.expect(expr.kind.binary.left.kind == .int_lit);
    try testing.expect(expr.kind.binary.right.kind == .binary);
    try testing.expect(expr.kind.binary.right.kind.binary.op == .mul);
}

test "parse comparison" {
    var result = try testParser("x >= 10");
    defer result.deinit();

    const expr = try result.parser.parseExpression();
    try testing.expect(expr.kind == .binary);
    try testing.expect(expr.kind.binary.op == .gte);
}

test "parse logical operators" {
    var result = try testParser("a and b or c");
    defer result.deinit();

    const expr = try result.parser.parseExpression();
    // should be ((a and b) or c) — or is lower precedence
    try testing.expect(expr.kind == .binary);
    try testing.expect(expr.kind.binary.op == .@"or");
    try testing.expect(expr.kind.binary.left.kind == .binary);
    try testing.expect(expr.kind.binary.left.kind.binary.op == .@"and");
}

test "parse not" {
    var result = try testParser("not x");
    defer result.deinit();

    const expr = try result.parser.parseExpression();
    try testing.expect(expr.kind == .unary);
    try testing.expect(expr.kind.unary.op == .not);
}

test "parse unary negate" {
    var result = try testParser("-42");
    defer result.deinit();

    const expr = try result.parser.parseExpression();
    try testing.expect(expr.kind == .unary);
    try testing.expect(expr.kind.unary.op == .negate);
    try testing.expect(expr.kind.unary.operand.kind == .int_lit);
}

test "parse function call" {
    var result = try testParser("foo(1, 2)");
    defer result.deinit();

    const expr = try result.parser.parseExpression();
    try testing.expect(expr.kind == .call);
    try testing.expectEqual(@as(usize, 2), expr.kind.call.args.len);
}

test "parse named arguments" {
    var result = try testParser("foo(x = 1, y = 2)");
    defer result.deinit();

    const expr = try result.parser.parseExpression();
    try testing.expect(expr.kind == .call);
    try testing.expectEqualStrings("x", expr.kind.call.args[0].name.?);
    try testing.expectEqualStrings("y", expr.kind.call.args[1].name.?);
}

test "parse method call" {
    var result = try testParser("x.foo(1)");
    defer result.deinit();

    const expr = try result.parser.parseExpression();
    try testing.expect(expr.kind == .method_call);
    try testing.expectEqualStrings("foo", expr.kind.method_call.method);
    try testing.expectEqual(@as(usize, 1), expr.kind.method_call.args.len);
}

test "parse field access" {
    var result = try testParser("x.y");
    defer result.deinit();

    const expr = try result.parser.parseExpression();
    try testing.expect(expr.kind == .field_access);
    try testing.expectEqualStrings("y", expr.kind.field_access.field);
}

test "parse index" {
    var result = try testParser("x[0]");
    defer result.deinit();

    const expr = try result.parser.parseExpression();
    try testing.expect(expr.kind == .index);
    try testing.expect(expr.kind.index.index.kind == .int_lit);
}

test "parse unwrap and try" {
    var result = try testParser("x?");
    defer result.deinit();
    const e1 = try result.parser.parseExpression();
    try testing.expect(e1.kind == .unwrap);

    var result2 = try testParser("x!");
    defer result2.deinit();
    const e2 = try result2.parser.parseExpression();
    try testing.expect(e2.kind == .try_expr);
}

test "parse chained postfix" {
    var result = try testParser("a.b.c(1).d");
    defer result.deinit();

    const expr = try result.parser.parseExpression();
    // should be ((((a).b).c(1)).d)
    try testing.expect(expr.kind == .field_access);
    try testing.expectEqualStrings("d", expr.kind.field_access.field);
    try testing.expect(expr.kind.field_access.object.kind == .method_call);
}

test "parse grouped expression" {
    var result = try testParser("(1 + 2)");
    defer result.deinit();

    const expr = try result.parser.parseExpression();
    try testing.expect(expr.kind == .grouped);
    try testing.expect(expr.kind.grouped.kind == .binary);
}

test "parse tuple" {
    var result = try testParser("(1, 2, 3)");
    defer result.deinit();

    const expr = try result.parser.parseExpression();
    try testing.expect(expr.kind == .tuple);
    try testing.expectEqual(@as(usize, 3), expr.kind.tuple.len);
}

test "parse list literal" {
    var result = try testParser("[1, 2, 3]");
    defer result.deinit();

    const expr = try result.parser.parseExpression();
    try testing.expect(expr.kind == .list);
    try testing.expectEqual(@as(usize, 3), expr.kind.list.len);
}

test "parse empty list" {
    var result = try testParser("[]");
    defer result.deinit();

    const expr = try result.parser.parseExpression();
    try testing.expect(expr.kind == .list);
    try testing.expectEqual(@as(usize, 0), expr.kind.list.len);
}

test "parse empty map" {
    var result = try testParser("{}");
    defer result.deinit();

    const expr = try result.parser.parseExpression();
    try testing.expect(expr.kind == .map);
    try testing.expectEqual(@as(usize, 0), expr.kind.map.len);
}

test "parse map literal" {
    var result = try testParser("{\"a\": 1, \"b\": 2}");
    defer result.deinit();

    const expr = try result.parser.parseExpression();
    try testing.expect(expr.kind == .map);
    try testing.expectEqual(@as(usize, 2), expr.kind.map.len);
}

test "parse set literal" {
    var result = try testParser("{1, 2, 3}");
    defer result.deinit();

    const expr = try result.parser.parseExpression();
    try testing.expect(expr.kind == .set);
    try testing.expectEqual(@as(usize, 3), expr.kind.set.len);
}

test "parse if expression" {
    var result = try testParser("if x: 1 else: 2");
    defer result.deinit();

    const expr = try result.parser.parseExpression();
    try testing.expect(expr.kind == .if_expr);
    try testing.expect(expr.kind.if_expr.then_expr.kind == .int_lit);
    try testing.expect(expr.kind.if_expr.else_expr.kind == .int_lit);
}

test "parse lambda short form" {
    var result = try testParser("fn(x) => x * 2");
    defer result.deinit();

    const expr = try result.parser.parseExpression();
    try testing.expect(expr.kind == .lambda);
    try testing.expectEqual(@as(usize, 1), expr.kind.lambda.params.len);
    try testing.expect(expr.kind.lambda.body == .expr);
}

test "parse pipe operator" {
    var result = try testParser("x | y | z");
    defer result.deinit();

    const expr = try result.parser.parseExpression();
    try testing.expect(expr.kind == .binary);
    try testing.expect(expr.kind.binary.op == .pipe);
    // left-associative: ((x | y) | z)
    try testing.expect(expr.kind.binary.left.kind == .binary);
}

test "parse string interpolation" {
    var result = try testParser("\"hello {name}!\"");
    defer result.deinit();

    const expr = try result.parser.parseExpression();
    try testing.expect(expr.kind == .string_interp);
    // parts: "hello " + name + "!"
    try testing.expectEqual(@as(usize, 3), expr.kind.string_interp.parts.len);
    try testing.expect(expr.kind.string_interp.parts[0] == .literal);
    try testing.expect(expr.kind.string_interp.parts[1] == .expr);
    try testing.expect(expr.kind.string_interp.parts[2] == .literal);
}

test "parse self" {
    var result = try testParser("self");
    defer result.deinit();

    const expr = try result.parser.parseExpression();
    try testing.expect(expr.kind == .self_expr);
}
