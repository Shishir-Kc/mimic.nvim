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
# prompts a Mason download. This script only clones plugins, unless you pass
# --tools / --tools-only, which install a default set of language tools through
# Mason (opt-in, never implicit).

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
  install.sh --tools[=LIST]
                        after installing, also install language tools via Mason
  install.sh --tools-only[=LIST]
                        skip the plugin install; only install language tools
  install.sh --help     this help

LIST is a comma separated subset of: python,rust,c,java,js (default: all).
"c" covers C and C++, "js" covers JavaScript and TypeScript. Default packages:
  python  basedpyright ruff
  rust    rust-analyzer   (rustfmt and clippy come from rustup)
  c       clangd clang-format
  java    jdtls google-java-format
  js      typescript-language-server prettier eslint_d

Language tools are downloaded only when you pass --tools or --tools-only (or
run :Mimic install later). Combine with --demo to install them into the demo.
USAGE
}

DEMO=0
FORCE=0
TOOLS=0
TOOLS_ONLY=0
TOOL_LANGS="all"
while [ $# -gt 0 ]; do
  case "$1" in
    --demo) DEMO=1 ;;
    --force) FORCE=1 ;;
    --tools) TOOLS=1 ;;
    --tools=*)
      TOOLS=1
      TOOL_LANGS=${1#--tools=}
      ;;
    --tools-only)
      TOOLS=1
      TOOLS_ONLY=1
      ;;
    --tools-only=*)
      TOOLS=1
      TOOLS_ONLY=1
      TOOL_LANGS=${1#--tools-only=}
      ;;
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
  if [ "$TOOLS" -eq 1 ]; then
    warn "--tools skipped: install the plugin spec first, then rerun with --tools-only"
  fi
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

# Map the requested languages to Mason package names. One language server plus
# the usual formatter per language; alternatives (pyright, vtsls, ...) are left
# to :Mimic install so two servers never compete for the same project.
tool_packages() {
  _langs=$(printf '%s' "$TOOL_LANGS" | tr ',' ' ')
  [ "$_langs" = "all" ] && _langs="python rust c java js"
  _out=""
  for _lang in $_langs; do
    case "$_lang" in
      python) _out="$_out basedpyright ruff" ;;
      rust) _out="$_out rust-analyzer" ;;
      c | cpp | clang) _out="$_out clangd clang-format" ;;
      java) _out="$_out jdtls google-java-format" ;;
      js | ts | javascript | typescript)
        _out="$_out typescript-language-server prettier eslint_d"
        ;;
      *) die "unknown language in --tools: $_lang (use python,rust,c,java,js)" ;;
    esac
  done
  printf '%s\n' $_out | sort -u | tr '\n' ' '
}

# Warn about runtimes Mason needs to build a package, before the long download.
check_runtimes() {
  case " $1 " in
    *" typescript-language-server "* | *" prettier "* | *" eslint_d "*)
      command -v npm >/dev/null 2>&1 || warn "npm not found: JS/TS tools will fail to install"
      ;;
  esac
  case " $1 " in
    *" basedpyright "* | *" ruff "*)
      command -v python3 >/dev/null 2>&1 || warn "python3 not found: Python tools will fail to install"
      ;;
  esac
  case " $1 " in
    *" jdtls "* | *" google-java-format "*)
      command -v java >/dev/null 2>&1 || warn "java not found: jdtls needs a JDK to run"
      ;;
  esac
}

# Install packages through Mason using the user's own config (so Mason's data
# dir and registry match what mimic detects). $1 = NVIM_APPNAME or empty.
install_tools() {
  PACKAGES=$(tool_packages)
  msg "Installing language tools via Mason: $PACKAGES"
  check_runtimes "$PACKAGES"

  cat > "$TMP/tools.lua" <<'EOF'
local pkgs = vim.split(vim.env.MIMIC_TOOLS or "", "%s+", { trimempty = true })

local function finish(code)
  vim.cmd((code == 0) and "qa!" or "cquit")
end

local lazy_ok, lazy = pcall(require, "lazy")
if lazy_ok then
  pcall(lazy.load, { plugins = { "mason.nvim" } })
end

local ok, mason = pcall(require, "mason")
if not ok then
  print("tools-error: mason.nvim is not available in this config")
  return finish(1)
end
if mason.has_setup ~= true and vim.fn.exists(":MasonInstall") ~= 2 then
  pcall(mason.setup)
end

local registry = require("mason-registry")
local refreshed = false
registry.refresh(function() refreshed = true end)
vim.wait(60000, function() return refreshed end, 100)

local failed = 0
for _, name in ipairs(pkgs) do
  local got, pkg = pcall(registry.get_package, name)
  if not got then
    print(("tool-fail:%s:not in the Mason registry"):format(name))
    failed = failed + 1
  elseif pkg:is_installed() then
    print(("tool-ok:%s:already installed"):format(name))
  else
    local done, err = false, nil
    local started, handle = pcall(function()
      return pkg:install({}, function(success, result)
        if not success then err = tostring(result) end
        done = true
      end)
    end)
    if not started then
      print(("tool-fail:%s:%s"):format(name, tostring(handle)))
      failed = failed + 1
    else
      vim.wait(900000, function() return done end, 200)
      if done and not err and pkg:is_installed() then
        print(("tool-ok:%s:installed"):format(name))
      else
        local reason = (err or "timed out"):gsub("%s+", " "):sub(1, 160)
        print(("tool-fail:%s:%s"):format(name, reason))
        failed = failed + 1
      end
    end
  end
end
print("tools-failed:" .. failed)
finish(0)
EOF

  _appname=${1:-${NVIM_APPNAME:-}}
  if command -v timeout >/dev/null 2>&1; then
    TOOLS_OUT=$(env MIMIC_TOOLS="$PACKAGES" ${_appname:+NVIM_APPNAME="$_appname"} \
      timeout 1800 nvim --headless -u "$NVIM_CONFIG/init.lua" -l "$TMP/tools.lua" 2>&1) || true
  else
    TOOLS_OUT=$(env MIMIC_TOOLS="$PACKAGES" ${_appname:+NVIM_APPNAME="$_appname"} \
      nvim --headless -u "$NVIM_CONFIG/init.lua" -l "$TMP/tools.lua" 2>&1) || true
  fi

  printf '%s\n' "$TOOLS_OUT" | grep '^tools-error:' | while IFS= read -r line; do
    warn "$line"
  done
  printf '%s\n' "$TOOLS_OUT" | grep '^tool-ok:' | while IFS=: read -r _ name note; do
    msg "  ok    $name ($note)"
  done
  printf '%s\n' "$TOOLS_OUT" | grep '^tool-fail:' | while IFS=: read -r _ name note; do
    warn "  FAIL  $name: $note"
  done
  if ! printf '%s\n' "$TOOLS_OUT" | grep -q '^tools-failed:'; then
    warn "tool installer did not finish; run :Mimic install inside Neovim for details"
  elif ! printf '%s\n' "$TOOLS_OUT" | grep -q '^tools-failed:0$'; then
    warn "some tools failed; retry with :Mimic install or :Mason"
  fi

  case " $PACKAGES " in
    *" rust-analyzer "*)
      if command -v rustup >/dev/null 2>&1; then
        msg "Rust: rustfmt and clippy come from rustup: rustup component add rustfmt clippy"
      else
        msg "Rust: install rustup for rustfmt and clippy (https://rustup.rs)"
      fi
      ;;
  esac
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

if [ "$TOOLS_ONLY" -eq 1 ]; then
  [ "$DEMO" -eq 1 ] && die "--tools-only cannot be combined with --demo; use --demo --tools"
  [ -f "$NVIM_CONFIG/init.lua" ] || die "$NVIM_CONFIG/init.lua not found; is this the right Neovim config?"
  install_tools ""
elif [ "$DEMO" -eq 1 ]; then
  demo
  if [ "$TOOLS" -eq 1 ]; then
    NVIM_CONFIG="$DEMO_CFG"
    install_tools "$DEMO_APPNAME"
  fi
else
  install
  if [ "$TOOLS" -eq 1 ]; then
    install_tools ""
  fi
fi
