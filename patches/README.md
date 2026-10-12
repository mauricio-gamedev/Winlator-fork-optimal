# Fork patches

Put reviewed `.patch` files in this directory. GitHub Actions applies each patch to the pinned `upstream/app` checkout before compiling.

Rules:
- Keep each change small and reversible.
- Generate patches against the exact upstream app revision pinned under `upstream`.
- Verify each patch with `git apply --check` and a CI build.
- Do not change Box64, graphics-driver, or resolution defaults globally until a baseline build is green and compatibility risks are documented.
