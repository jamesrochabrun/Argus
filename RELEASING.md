# Releasing Argus

## Create a New Release

1. Commit all changes to `main`
2. Create and push a version tag:
   ```bash
   git tag v1.2.0
   git push origin v1.2.0
   ```
3. GitHub Actions automatically:
   - Builds universal binary (arm64 + x86_64)
   - Creates `argus-macos-universal.tar.gz`
   - Uploads to GitHub release

## If Release Fails

```bash
# Delete the failed release and tag
gh release delete v1.2.0 --yes
git push origin --delete v1.2.0
git tag -d v1.2.0

# Fix the issue, commit, push to main
# Then create a new tag
git tag v1.2.1
git push origin v1.2.1
```

## User Installation

```bash
curl -fsSL https://raw.githubusercontent.com/jamesrochabrun/Argus/main/install.sh | sh
```

## User Uninstall

```bash
rm -f ~/.local/bin/argus-mcp ~/.local/bin/argus-select
# Also remove "argus" from mcpServers in ~/.claude.json
```
