#!/bin/sh
# Install a pre-merge-commit git hook that runs `zebra typecheck-merge` on
# every .zbr file with conflict markers after an auto-merge attempt.
#
# Usage (from repo root):
#   sh tools/install_merge_hook.sh
#
# The hook is informational (exit 0 always) — it reports type errors on each
# side of a conflict but does not block the commit. Wrap the zebra call with
# an exit-1 check if you want blocking behaviour.

set -e

HOOK=.git/hooks/pre-merge-commit
cat > "$HOOK" << 'EOF'
#!/bin/sh
# Zebra typecheck-merge hook — informational, always exits 0.
# Runs `zebra typecheck-merge` on any .zbr file that has conflict markers.
for f in $(git diff --name-only --diff-filter=U 2>/dev/null | grep '\.zbr$'); do
    if [ -f "$f" ]; then
        zebra typecheck-merge "$f" >&2
    fi
done
exit 0
EOF

chmod +x "$HOOK"
echo "Installed typecheck-merge hook at $HOOK"
