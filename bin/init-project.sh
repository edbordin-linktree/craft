#!/usr/bin/env bash
set -euo pipefail

# init-project.sh — Scaffold a new craft project instance
#
# Usage: init-project.sh <project-name>
#
# Creates a new project folder in projects/<project-name> by copying
# the templates/ structure and replacing placeholders.

CRAFT_ROOT="${CRAFT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TEMPLATES_DIR="$CRAFT_ROOT/templates"
PROJECTS_DIR="${CRAFT_PROJECTS:-$CRAFT_ROOT/projects}"

# Portable sed -i wrapper (macOS vs GNU)
_sed_i() {
    if sed --version 2>/dev/null | grep -q GNU; then
        sed -i -E "$@"
    else
        sed -i "" -E "$@"
    fi
}

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <project-name>"
    echo "Example: $0 trust-content-mod"
    exit 1
fi

PROJECT_NAME="$1"
PROJECT_DIR="$PROJECTS_DIR/$PROJECT_NAME"

if [[ -d "$PROJECT_DIR" ]]; then
    echo "Error: Project '$PROJECT_NAME' already exists at $PROJECT_DIR"
    exit 1
fi

echo "Creating project: $PROJECT_NAME"

# Ensure projects directory exists
mkdir -p "$PROJECTS_DIR"

# Copy template structure (plugins are NOT under templates/ — they live as a
# shared library at $CRAFT_ROOT/plugins/ and are referenced from the project's
# craft.conf via PLUGINS=).
cp -R "$TEMPLATES_DIR" "$PROJECT_DIR"

# Create additional directories not in templates
mkdir -p "$PROJECT_DIR/docs/milestones"
mkdir -p "$PROJECT_DIR/docs/adrs"
mkdir -p "$PROJECT_DIR/docs/context"
mkdir -p "$PROJECT_DIR/repos"

# Rename .template files to their actual names and replace placeholders
DATE=$(date +%Y-%m-%d)

# Resolve operator name: explicit env var > git config > $USER
# Strip newlines/CRs in case the source emits warnings on stdout — otherwise
# the downstream sed substitution chokes on "unescaped newline in pattern".
OPERATOR_NAME="${OPERATOR_NAME:-$(git config user.name 2>/dev/null || echo "${USER:-operator}")}"
OPERATOR_NAME="$(printf '%s' "$OPERATOR_NAME" | tr -d '\n\r')"

# Resolve GitHub reviewer: explicit env var > gh CLI > empty
GITHUB_REVIEWER="${GITHUB_REVIEWER:-$(gh api user -q .login 2>/dev/null || echo "")}"
GITHUB_REVIEWER="$(printf '%s' "$GITHUB_REVIEWER" | tr -d '\n\r')"

# Resolve branch prefix: explicit env var > empty
BRANCH_PREFIX="${BRANCH_PREFIX:-}"

# Ensure craft.conf exists (not a .template, just a default)
if [[ ! -f "$PROJECT_DIR/craft.conf" ]]; then
    cp "$TEMPLATES_DIR/craft.conf" "$PROJECT_DIR/craft.conf"
fi

# Set resolved values in project config
_sed_i "s/^# OPERATOR_NAME=$/OPERATOR_NAME=\"${OPERATOR_NAME}\"/" "$PROJECT_DIR/craft.conf"
if [[ -n "$GITHUB_REVIEWER" ]]; then
    _sed_i "s/^# GITHUB_REVIEWER=$/GITHUB_REVIEWER=\"${GITHUB_REVIEWER}\"/" "$PROJECT_DIR/craft.conf"
fi
if [[ -n "$BRANCH_PREFIX" ]]; then
    _sed_i "s/^# BRANCH_PREFIX=$/BRANCH_PREFIX=\"${BRANCH_PREFIX}\"/" "$PROJECT_DIR/craft.conf"
fi

# Replace placeholders in .template files
for template in "$PROJECT_DIR"/docs/*.template "$PROJECT_DIR"/.claude/*.template "$PROJECT_DIR"/*.template; do
    [[ -f "$template" ]] || continue
    target="${template%.template}"
    sed "s/{{PROJECT_NAME}}/$PROJECT_NAME/g; s/{{DATE}}/$DATE/g; s/{{TIMESTAMP}}/$DATE/g; s/{{OPERATOR_NAME}}/$OPERATOR_NAME/g; s/{{GITHUB_REVIEWER}}/$GITHUB_REVIEWER/g; s|{{BRANCH_PREFIX}}|$BRANCH_PREFIX|g" "$template" > "$target"
    rm "$template"
done

# Replace placeholders in non-template files (skills, docs)
while IFS= read -r -d '' mdfile; do
    _sed_i "s/\\{\\{OPERATOR_NAME\\}\\}/$OPERATOR_NAME/g; s/\\{\\{GITHUB_REVIEWER\\}\\}/$GITHUB_REVIEWER/g; s|\\{\\{BRANCH_PREFIX\\}\\}|$BRANCH_PREFIX|g" "$mdfile"
done < <(find "$PROJECT_DIR" -name '*.md' -type f -print0)

echo ""
echo "Project created at: $PROJECT_DIR"
echo ""
echo "Next steps:"
echo "  1. Edit $PROJECT_DIR/docs/plan.md with your project plan"
echo "  2. Add repos:  cd $PROJECT_DIR/repos && git worktree add <path> <branch>"
echo "  3. Update $PROJECT_DIR/.claude/CLAUDE.md with repo table"
echo "  4. Run /generate-milestone to create your first milestone"
echo ""
