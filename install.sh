#!/bin/sh
# mimic.nvim one-command installer.
#
#   sh -c 'curl -fsSL https://raw.githubusercontent.com/Shishir-Kc/mimic.nvim/main/install.sh | sh'
#
# Adds mimic to a lazy.nvim-managed Neovim config and syncs it headlessly.
# LazyVim-style configs (auto-loaded lua/plugins/) get a spec file written;
# other lazy configs get manual paste instructions. --demo builds an isolated
# NVIM_APPNAME=mimic-demo config that never touches a real one.
#
# mimic never installs language tools itself: only an explicit :Mimic install
# prompts a Mason download. This script only ever clones plugins.

set -eu

REPO_URL="https://github.com/Shishir-Kc/mimic.nvim"
DEMO_APPNAME="mimic-demo"

msg() { printf '%s\n' "$*"; }
warn() { printf 'install.sh: %s\n' "$*" >&2; }
die() { warn "$*"; exit 1; }

usage() {
  cat <<'USAGE'
mimic.nvim installer

  install.sh            add mimic to the current lazy.nvim Neovim config
  install.sh --demo     try mimic in an isolated NVIM_APPNAME=mimic-demo config
  install.sh --force    overwrite an existing mimic spec file
  install.sh --help     this help

Only :Mimic install ever downloads language tools, never this script.
Bare buffers first: run "sh install.sh --demo" and open a Rust file from a
crate with a Cargo.toml.
USAGE
}

DEMO=0
FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --demo) DEMO=1 ;;
    --force) FORCE=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown flag: $1"
      ;;
  esac
  shift
done

command -v git >/dev/null 2>&1 || die "git is required (install git, then rerun)"
command -v nvim >/dev/null 2>&1 || die "neovim (nvim) is required (install Neovim 0.11.3+, then rerun)"

# Scratch dir for the one-off lua scripts nvim runs. Cleaned on exit.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/mimic-install.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
trap 'rm -rf "$TMP"' INT
trap 'rm -rf "$TMP"' TERM

# --- Ask Neovim for the real stdpaths and its version. Uses -l (no user init)
# --- so the query is fast and deterministic; stdpath honors NVIM_APPNAME itself.
# Note: --headless print() lands on stderr, so stderr is captured too.
cat > "$TMP/paths.lua" <<'EOF'
print("CONFIG:" .. vim.fn.stdpath("config"))
print("DATA:" .. vim.fn.stdpath("data"))
local v = vim.version() or {}
print("V:" .. (v.major or 0) .. " " .. (v.minor or -1) .. " " .. (v.patch or -1))
EOF

NVIM_OUT=$(nvim --headless -l "$TMP/paths.lua" 2>&1) ||
  die "could not run nvim headlessly to resolve stdpath"

NVIM_CONFIG=$(printf '%s\n' "$NVIM_OUT" | grep -m1 '^CONFIG:' | sed 's/^CONFIG://')
NVIM_DATA=$(printf '%s\n' "$NVIM_OUT" | grep -m1 '^DATA:' | sed 's/^DATA://')
NVIM_VERSION_LINE=$(printf '%s\n' "$NVIM_OUT" | grep -m1 '^V:' | sed 's/^V://' | head -1)

[ -n "$NVIM_CONFIG" ] || die "could not resolve nvim config directory"
[ -n "$NVIM_DATA" ] || die "could not resolve nvim data directory"

NVIM_MAJOR=$(printf '%s' "$NVIM_VERSION_LINE" | cut -d ' ' -f 1)
NVIM_MINOR=$(printf '%s' "$NVIM_VERSION_LINE" | cut -d ' ' -f 2)
NVIM_PATCH=$(printf '%s' "$NVIM_VERSION_LINE" | cut -d ' ' -f 3)
# Development builds count as new enough; only warn on stable releases below.
if [ "$NVIM_MAJOR" -eq 0 ] && [ "$NVIM_MINOR" -lt 11 ]; then
  warn "Neovim $NVIM_MAJOR.$NVIM_MINOR.$NVIM_PATCH found; mimic wants 0.11.3+"
elif [ "$NVIM_MAJOR" -eq 0 ] && [ "$NVIM_MINOR" -eq 11 ] && [ "$NVIM_PATCH" -lt 3 ]; then
  warn "Neovim $NVIM_MAJOR.$NVIM_MINOR.$NVIM_PATCH found; mimic wants 0.11.3+"
fi

manual_instructions() {
  cat <<'MANUAL'
This config is not a lazy.nvim setup with auto-loaded specs, so the installer
did not write anything. Paste the spec below wherever your plugins are:

```lua
{
  "Shishir-Kc/mimic.nvim",
  event = "VeryLazy",
  dependencies = {
    "neovim/nvim-lspconfig",
    "stevearc/conform.nvim",
    "mfussenegger/nvim-lint",
    "mason-org/mason.nvim",
  },
  opts = {},
}
```

Or build a throwaway config with: sh install.sh --demo
See https://github.com/Shishir-Kc/mimic.nvim#installation for details.
MANUAL
}

install() {
  if [ ! -f "$NVIM_CONFIG/init.lua" ]; then
    die "$NVIM_CONFIG/init.lua not found; is this the right Neovim config? (NVIM_APPNAME=$NVIM_APPNAME)"
  fi

  # Is this a lazy.nvim config? The lockfile is the strongest signal.
  if [ ! -f "$NVIM_CONFIG/lazy-lock.json" ]; then
    if ! grep -qsE 'require\("lazy"\)|require\(."lazy"?\)|lazy\.setup|LazyVim' "$NVIM_CONFIG/init.lua"; then
      manual_instructions
      exit 0
    fi
    warn "no lazy-lock.json found; continuing because init.lua mentions lazy.nvim"
  fi

  # Only LazyVim-style configs auto-load every file in lua/plugins/. For those
  # the installer writes the spec; anything else gets paste instructions.
  PLUGINS_DIR="$NVIM_CONFIG/lua/plugins"
  SPEC="$PLUGINS_DIR/mimic.lua"
  if [ ! -d "$PLUGINS_DIR" ]; then
    manual_instructions
    exit 0
  fi

  if [ -e "$SPEC" ] && [ "$FORCE" -ne 1 ]; then
    die "$SPEC already exists (delete it first, or rerun with --force)"
  fi

  msg "Writing $SPEC"
  cat > "$SPEC" <<'EOF'
-- mimic.nvim, written by install.sh: https://github.com/Shishir-Kc/mimic.nvim
-- Undo config changes with :Mimic reload or :Mimic toggle. Language tools are
-- installed only by an explicit :Mimic install.
return {
  {
    "Shishir-Kc/mimic.nvim",
    event = "VeryLazy",
    dependencies = {
      "neovim/nvim-lspconfig",
      "stevearc/conform.nvim",
      "mfussenegger/nvim-lint",
      "mason-org/mason.nvim",
    },
    opts = {},
  },
}
EOF

  # Finish the install headlessly with the user's own config: lazy resolves
  # NVIM_APPNAME and clones mimic plus whatever declared deps are missing.
  cat > "$TMP/sync.lua" <<'EOF'
local ok, err = pcall(function()
  require("lazy").sync({ wait = true })
end)
if not ok then
  print("lazy-sync-error: " .. tostring(err))
end
vim.schedule(function()
  local okcfg, cfg = pcall(require, "lazy.core.config")
  local spec = okcfg and cfg.plugins["mimic.nvim"] or nil
  print("mimic-installed:" .. tostring(spec ~= nil and spec._.installed == true))
  local okmod = pcall(require, "mimic")
  print("mimic-loadable:" .. tostring(okmod))
  vim.cmd("qa!")
end)
EOF

  msg "Syncing lazy.nvim (cloning mimic.nvim and missing dependencies)..."
  SYNC_OUT=sync-output
  if command -v timeout >/dev/null 2>&1; then
    SYNC_OUT=$(timeout 600 nvim --headless -u "$NVIM_CONFIG/init.lua" -l "$TMP/sync.lua" 2>&1) || true
  else
    SYNC_OUT=$(nvim --headless -u "$NVIM_CONFIG/init.lua" -l "$TMP/sync.lua" 2>&1) || true
  fi

  printf '%s\n' "$SYNC_OUT" | grep 'lazy-sync-error' | while IFS= read -r line; do
    warn "$line"
  done

  if printf '%s\n' "$SYNC_OUT" | grep -q 'mimic-installed:true'; then
    msg "mimic.nvim is installed."
  elif printf '%s\n' "$SYNC_OUT" | grep -q 'mimic-installed:false'; then
    warn 'lazy.nvim did not report mimic.nvim installed; restart Neovim and check :Lazy'
  else
    warn 'sync output missing; restart Neovim and check :Lazy'
  fi
  if printf '%s\n' "$SYNC_OUT" | grep -q 'mimic-loadable:true'; then
    : # module resolves; the plugin waits for VeryLazy like any spec
  else
    warn 'mimic module not loadable yet; check :Lazy for the clone'
  fi

  cat <<'NEXT'
Next steps:
  - Restart Neovim, then :checkhealth mimic
  - Open any buffer, run :Mimic status to see what mimic would do
  - :Mimic install (explicit and interactive) adds missing Mason-published
    language tools; it never does this on its own
NEXT
}

demo() {
  XDG_CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
  XDG_DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}
  DEMO_CFG="$XDG_CONFIG_HOME/$DEMO_APPNAME"
  DEMO_DATA="$XDG_DATA_HOME/$DEMO_APPNAME"

  if [ -e "$DEMO_CFG" ] || [ -e "$DEMO_DATA" ]; then
    die "$DEMO_APPNAME already exists; remove it first: rm -rf '$DEMO_CFG' '$DEMO_DATA'"
  fi

  msg "Building an isolated $DEMO_APPNAME config..."
  mkdir -p "$DEMO_DATA/lazy"

  clone_plugin() { # url dir
    git clone --depth 1 --filter=blob:none "$1" "$2" ||
      { warn "git clone failed: $1"; exit 1; }
  }
  clone_plugin "https://github.com/folke/lazy.nvim.git" \
    "$DEMO_DATA/lazy/lazy.nvim"
  clone_plugin "$REPO_URL" "$DEMO_DATA/lazy/mimic.nvim"
  clone_plugin "https://github.com/neovim/nvim-lspconfig.git" \
    "$DEMO_DATA/lazy/nvim-lspconfig"
  clone_plugin "https://github.com/stevearc/conform.nvim.git" \
    "$DEMO_DATA/lazy/conform.nvim"
  clone_plugin "https://github.com/mfussenegger/nvim-lint.git" \
    "$DEMO_DATA/lazy/nvim-lint"
  clone_plugin "https://github.com/mason-org/mason.nvim.git" \
    "$DEMO_DATA/lazy/mason.nvim"

  mkdir -p "$DEMO_CFG"
  cat > "$DEMO_CFG/init.lua" <<'EOF'
-- mimic.nvim demo config, generated by install.sh --demo.
-- Isolated through NVIM_APPNAME; the parent setup is untouched.
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
  { "Shishir-Kc/mimic.nvim", opts = {} },
  { "neovim/nvim-lspconfig" },
  { "stevearc/conform.nvim" },
  { "mfussenegger/nvim-lint" },
  { "mason-org/mason.nvim" },
}, {
  install = { colorscheme = { "habamax" } },
  checker = { enabled = false },
})
EOF

  cat <<NEXT
Demo config ready:

  NVIM_APPNAME=$DEMO_APPNAME nvim

Open a Rust file from a crate directory (one with Cargo.toml) and type a
member access such as rand:: to see suggestions; :Mimic status explains what
mimic detected. The demo is throwaway:
  rm -rf '$DEMO_CFG' '$DEMO_DATA'
NEXT
}

if [ "$DEMO" -eq 1 ]; then
  demo
else
  install
fi
