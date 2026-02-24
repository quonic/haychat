# Tooling Flow

Typical local iteration loop:

1. `odin check .`
2. `odin test .`
3. `odin build .`
4. `odin run .`

Notes:

- Start with the narrowest command that validates the recent change.
- Run from the correct package or project root.
