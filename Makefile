.PHONY: build test run clean fmt check

build:
	zig build

test:
	zig build test

run:
	zig build run

clean:
	rm -rf .zig-cache zig-out

fmt:
	zig fmt src/

check:
	zig build test 2>&1
