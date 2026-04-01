#!/usr/bin/env bash
# install.sh — Install the build-mcp-server skill for Claude Code and/or Cursor IDE
#
# Usage:
#   ./install.sh                  Install for both Claude Code and Cursor (default)
#   ./install.sh --claude-only    Claude Code only
#   ./install.sh --cursor-only    Cursor IDE only
#   ./install.sh --symlink        Symlink instead of copy (edits auto-propagate; dev mode)
#   ./install.sh --uninstall      Remove installed files from both IDEs
#   ./install.sh --help           Show this help
#
# Install locations:
#   Claude Code  ~/.claude/skills/build-mcp-server/    (directory with SKILL.md)
#   Cursor       ~/.cursor/skills/build-mcp-server/    (directory with SKILL.md)

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'  # reset

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_NAME="build-mcp-server"
SKILL_SOURCE="$SCRIPT_DIR/skills/$SKILL_NAME"

CLAUDE_SKILLS_DIR="$HOME/.claude/skills"
CLAUDE_TARGET="$CLAUDE_SKILLS_DIR/$SKILL_NAME"

CURSOR_SKILLS_DIR="$HOME/.cursor/skills"
CURSOR_TARGET="$CURSOR_SKILLS_DIR/$SKILL_NAME"

# ── Defaults ──────────────────────────────────────────────────────────────────
DO_CLAUDE=false
DO_CURSOR=false
USE_SYMLINK=false
DO_UNINSTALL=false
EXPLICIT_TARGET=false

# ── Helpers ───────────────────────────────────────────────────────────────────
info()    { echo -e "${BLUE}  $*${NC}"; }
success() { echo -e "${GREEN}✓ $*${NC}"; }
warn()    { echo -e "${YELLOW}⚠ $*${NC}"; }
error()   { echo -e "${RED}✗ $*${NC}" >&2; }
bold()    { echo -e "${BOLD}$*${NC}"; }

backup_if_exists() {
  local path="$1"
  if [[ -e "$path" || -L "$path" ]]; then
    local backup="${path}.bak.$(date +%Y%m%d_%H%M%S)"
    mv "$path" "$backup"
    info "Backed up existing installation → $(basename "$backup")"
  fi
}

show_help() {
  bold "\nMCP Builder Skill Installer"
  echo ""
  echo "  Installs the /build-mcp-server skill at the user level so it is"
  echo "  available in every session — no per-project setup needed."
  echo ""
  bold "Usage:"
  echo "  ./install.sh [options]"
  echo ""
  bold "Options:"
  echo "  (none)           Install for Claude Code and Cursor (default)"
  echo "  --claude-only    Install for Claude Code only"
  echo "  --cursor-only    Install for Cursor IDE only"
  echo "  --symlink        Symlink source instead of copying (dev mode)"
  echo "  --uninstall      Remove the skill from both IDEs"
  echo "  --help           Show this help"
  echo ""
  bold "Install locations:"
  echo "  Claude Code  $CLAUDE_TARGET/"
  echo "  Cursor       $CURSOR_TARGET/"
  echo ""
}

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --claude-only)  DO_CLAUDE=true; DO_CURSOR=false; EXPLICIT_TARGET=true ;;
    --cursor-only)  DO_CLAUDE=false; DO_CURSOR=true; EXPLICIT_TARGET=true ;;
    --symlink|-s)   USE_SYMLINK=true ;;
    --uninstall)    DO_UNINSTALL=true ;;
    --help|-h)      show_help; exit 0 ;;
    *)
      error "Unknown option: $1"
      echo "Run './install.sh --help' for usage."
      exit 1
      ;;
  esac
  shift
done

# ── Interactive target selection (when no --claude-only / --cursor-only given) ─
if ! $EXPLICIT_TARGET && ! $DO_UNINSTALL; then
  echo ""
  bold "Where would you like to install the skill?"
  echo "  1) Claude Code only  (~/.claude/skills/)"
  echo "  2) Cursor only       (~/.cursor/skills/)"
  echo "  3) Both (default)"
  echo ""
  printf "  Enter choice [1/2/3]: "
  read -r choice
  case "$choice" in
    1) DO_CLAUDE=true;  DO_CURSOR=false ;;
    2) DO_CLAUDE=false; DO_CURSOR=true  ;;
    *)  DO_CLAUDE=true;  DO_CURSOR=true  ;;
  esac
fi

# ── Validate source ───────────────────────────────────────────────────────────
if [[ ! -d "$SKILL_SOURCE" ]]; then
  error "Skill source not found: $SKILL_SOURCE"
  echo "  Run this script from the root of the mcp-builder repository."
  exit 1
fi

if [[ ! -f "$SKILL_SOURCE/SKILL.md" ]]; then
  error "SKILL.md not found in $SKILL_SOURCE"
  exit 1
fi

# ── Uninstall ─────────────────────────────────────────────────────────────────
do_uninstall() {
  bold "\nUninstalling $SKILL_NAME..."
  local removed=0

  if [[ -e "$CLAUDE_TARGET" || -L "$CLAUDE_TARGET" ]]; then
    rm -rf "$CLAUDE_TARGET"
    success "Claude Code: removed $CLAUDE_TARGET"
    removed=$((removed + 1))
  else
    info "Claude Code: not installed, nothing to remove"
  fi

  if [[ -e "$CURSOR_TARGET" || -L "$CURSOR_TARGET" ]]; then
    rm -rf "$CURSOR_TARGET"
    success "Cursor: removed $CURSOR_TARGET"
    removed=$((removed + 1))
  else
    info "Cursor: not installed, nothing to remove"
  fi

  [[ $removed -gt 0 ]] && echo "" && bold "Uninstall complete."
}

# ── Claude Code install ───────────────────────────────────────────────────────
install_claude() {
  bold "\nInstalling for Claude Code..."

  mkdir -p "$CLAUDE_SKILLS_DIR"
  backup_if_exists "$CLAUDE_TARGET"

  if $USE_SYMLINK; then
    ln -s "$SKILL_SOURCE" "$CLAUDE_TARGET"
    info "Symlinked: $CLAUDE_TARGET → $SKILL_SOURCE"
  else
    cp -r "$SKILL_SOURCE" "$CLAUDE_TARGET"
    info "Copied to: $CLAUDE_TARGET"
  fi

  success "Claude Code: /$SKILL_NAME skill installed"
  info "Usage: type /$SKILL_NAME in any Claude Code session"
}

# ── Cursor install ────────────────────────────────────────────────────────────
# Cursor discovers skills from ~/.cursor/skills/<skill-name>/SKILL.md
# The directory structure mirrors the source: SKILL.md + references/ + assets/
install_cursor() {
  bold "\nInstalling for Cursor IDE..."

  # Warn (don't fail) if Cursor doesn't appear to be installed
  if [[ ! -d "$HOME/.cursor" && ! -d "/Applications/Cursor.app" ]]; then
    warn "Cursor installation not detected — installing skill directory anyway."
    warn "If Cursor is installed elsewhere, move $CURSOR_TARGET/ to the correct skills directory."
  fi

  mkdir -p "$CURSOR_SKILLS_DIR"
  backup_if_exists "$CURSOR_TARGET"

  if $USE_SYMLINK; then
    ln -s "$SKILL_SOURCE" "$CURSOR_TARGET"
    info "Symlinked: $CURSOR_TARGET → $SKILL_SOURCE"
  else
    cp -r "$SKILL_SOURCE" "$CURSOR_TARGET"
    info "Copied to: $CURSOR_TARGET/"
  fi

  local ref_count
  ref_count="$(ls "$SKILL_SOURCE/references"/*.md 2>/dev/null | wc -l | tr -d ' ')"
  info "Includes: SKILL.md + $ref_count reference files + assets/"
  success "Cursor: /$SKILL_NAME skill installed"
  info "Usage: in Cursor Agent chat, the skill activates automatically based on your request"
}

# ── Main ──────────────────────────────────────────────────────────────────────
echo ""
bold "MCP Builder Skill Installer"
bold "==========================="

if $DO_UNINSTALL; then
  do_uninstall
  exit 0
fi

$DO_CLAUDE && install_claude
$DO_CURSOR && install_cursor

echo ""
bold "Installation complete."
echo ""

if $DO_CLAUDE && $DO_CURSOR; then
  bold "Next steps:"
  echo "  Claude Code  → open a session and type: /build-mcp-server"
  echo "  Cursor       → open Agent chat and describe your MCP server — the skill activates automatically"
elif $DO_CLAUDE; then
  bold "Next step:"
  echo "  Claude Code  → open a session and type: /build-mcp-server"
elif $DO_CURSOR; then
  bold "Next step:"
  echo "  Cursor       → open Agent chat and describe your MCP server — the skill activates automatically"
fi

echo ""

if $USE_SYMLINK; then
  bold "Symlink mode active:"
  echo "  Edits to $SKILL_SOURCE propagate immediately to both Claude Code and Cursor."
fi
