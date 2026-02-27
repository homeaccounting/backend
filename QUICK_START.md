# Quick Start Guide

## 🚀 Regular Development (Default)

Uses published Hackage packages - no setup needed!

```bash
cabal build all
cabal test all
```

## 🔧 Local Eventium Development

Need to modify eventium? Easy:

```bash
# Enable local packages
cp cabal.project.local.example cabal.project.local
cabal clean
cabal build all
```

Switch back to Hackage:

```bash
rm cabal.project.local
cabal clean
cabal build all
```

## 📚 Documentation

- **[EVENTIUM_MIGRATION_COMPLETE.md](docs/EVENTIUM_MIGRATION_COMPLETE.md)** - How the migration works
- **[LOCAL_EVENTIUM_DEVELOPMENT.md](docs/LOCAL_EVENTIUM_DEVELOPMENT.md)** - Detailed local dev guide
- **[README.md](README.md)** - Full project documentation

## 💡 Common Tasks

### Check which packages you're using

```bash
cabal build all --dry-run -v | grep eventium
```

- Shows Hackage if using published packages
- Shows `../lib/eventium/` if using local packages

### Force clean rebuild

```bash
cabal clean
rm -rf dist-newstyle
cabal build all
```

### Update dependencies

```bash
cabal update
cabal build all
```

## ❓ Troubleshooting

### Build fails after switching modes

```bash
cabal clean
rm -rf dist-newstyle
cabal build all
```

### "Package not found" errors

```bash
# Update Hackage index
cabal update

# Verify eventium is on Hackage
cabal info eventium-core
```

### Local changes not taking effect

```bash
# Verify local mode is enabled
ls -la cabal.project.local  # Should exist

# Force rebuild
cabal clean
cabal build all
```

## 🎯 Remember

- ✅ **Default = Hackage** (fastest, most reliable)
- ✅ **Local = Development only** (`cabal.project.local` is gitignored)
- ✅ **CI always uses Hackage** (no local packages in CI)

---

**Most developers never need local packages!**  
Just `cabal build all` and you're good to go. 🎉


