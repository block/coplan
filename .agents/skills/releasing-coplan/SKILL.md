---
name: releasing-coplan
description: "Publish the coplan-engine gem to RubyGems. Use when releasing a new version, publishing the gem, or bumping the version."
---

# Releasing coplan-engine

Publish the `coplan-engine` gem to RubyGems.org.

## Steps

### 1. Bump the version

Edit `engine/lib/coplan/version.rb` and update `CoPlan::VERSION` to the new version number.

### 2. Commit the version bump

```bash
git add engine/lib/coplan/version.rb
git commit -m "Bump version to vX.Y.Z"
```

### 3. Tag the release

```bash
git tag vX.Y.Z
git push origin main --tags
```

### 4. Build and publish the gem

```bash
cd engine
gem build coplan.gemspec
gem push coplan-engine-X.Y.Z.gem
```

This will prompt for RubyGems MFA. The human must complete this step interactively.

### 5. Create a GitHub release

```bash
gh release create vX.Y.Z --generate-notes
```

## Version guidelines

- **Patch** (0.1.x): bug fixes, docs changes
- **Minor** (0.x.0): new features, non-breaking changes
- **Major** (x.0.0): breaking API changes
