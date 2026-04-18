# Installation

This repo includes [cactus](https://github.com/cactus-compute/cactus) as a git submodule, so the clone step differs slightly from the original README.

## Clone with submodules

```bash
git clone --recurse-submodules https://github.com/jinxi97/voice-agents-hack.git
cd voice-agents-hack
```

If you already cloned without `--recurse-submodules`:

```bash
cd voice-agents-hack
git submodule update --init --recursive
```

## Set up cactus

The `cactus/` directory is already populated by the submodule, so skip the `git clone` step from the root README. Continue from Step 3:

```bash
cd cactus && source ./setup && cd ..   # re-run in a new terminal
cactus build --python
cactus download google/functiongemma-270m-it --reconvert
```

Then follow Steps 6-10 in [README.md](README.md) for the cactus API key, Gemini key, and optional cloud fallback setup.

## Updating the submodule

To pull the latest cactus changes later:

```bash
git submodule update --remote cactus
```
