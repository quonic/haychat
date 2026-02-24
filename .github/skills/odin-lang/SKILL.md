# Odin Language

Use this skill when writing or reviewing Odin code.

## Goals

- Produce idiomatic Odin code that is clear and explicit.
- Prefer simple, procedural designs and explicit data flow.
- Use Odin tooling commands correctly during implementation and verification.

## Language Essentials

### Declarations

- Inferred declaration: `value := expression`
- Typed declaration: `count: int = 0`
- Constants: `MAX_CONNECTIONS :: 1024`

### Procedures

- Procedures are declared with `proc`.
- Multiple return values are common and preferred over exception-style flow.
- Keep parameter names descriptive and avoid one-letter identifiers unless conventional.

### Control Flow

- Use `if`, `switch`, and `for`.
- Odin uses a single `for` construct for loop patterns.
- Prefer straightforward loops over overly compact control logic.

### Types and Conversions

- Keep types explicit when readability benefits.
- Use explicit conversions where required instead of relying on implicit behavior.
- Prefer concrete types for public APIs and important boundaries.

### Composite Types

- Use structs for grouped state and enums for closed sets of values.
- For struct literals, either use named fields for all values or positional values for all values; do not mix styles in one literal.

### Collections

- Use `len(collection)` for slices, arrays, and strings.
- Prefer slices for dynamic sequences and arrays when fixed-size semantics matter.

## Packages and Imports

- Organize code by package directories.
- Import with Odin package paths, including namespaced roots like `core:` and `vendor:` when appropriate.
- Keep imports minimal and remove unused dependencies.

## Tooling Quick Reference

Run commands from the intended package/project root:

- Typecheck: `odin check .`
- Build: `odin build .`
- Run: `odin run .`
- Test: `odin test .`
- Generate docs: `odin doc .`

## Common Pitfalls

- Mixing named and positional struct fields in a single literal.
- Overusing implicit type inference where explicit types would improve clarity.
- Forgetting explicit conversion between numeric or distinct types.
- Using non-idiomatic collection length checks instead of `len(...)`.

## Response Style for Coding Tasks

When applying this skill:

- Return minimal, focused edits that match existing project style.
- Explain key Odin-specific decisions briefly.
- Validate changes with the smallest relevant Odin command before broader checks.
