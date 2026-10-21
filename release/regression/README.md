# Regression checks

Each `*.sh` file here is mounted read-only into the new image at
`/release/regression/` and run with `sh` as root, with no network. It must
exit 0 only when the issue it covers is fixed. Add one for each issue a
release is meant to fix once a reproducer is available.
