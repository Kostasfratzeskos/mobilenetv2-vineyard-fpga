#!/usr/bin/env bash
set -euo pipefail
# One-time setup for the thesis git repository.
if [ -d .git ]; then
  echo ".git already exists - skipping git init."
else
  git init
fi
git add .
git commit -m "Initial commit: project scaffold, plan, and design-decision log"
git branch -M main
echo
echo "Repo initialized. Next steps:"
echo "  1. Create an empty repo on GitHub/GitLab (do NOT add a README)."
echo "  2. git remote add origin <your-repo-url>"
echo "  3. git push -u origin main"
