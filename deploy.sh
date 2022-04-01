#!/bin/bash
# Program:
#   发布Hugo生成文件到GitHub Pages
# If a command fails then the deploy stops

set -e

printf "\033[0;32mDeploying updates to GitHub...\033[0m\n"

# Build the project.
Hugo # --minify # if using a theme, replace with `Hugo -t <YOURTHEME>`

# Go To Public folder
cd public

# Add changes to git.
git add .

# Commit changes.
msg="Published on $(date +'%Y-%m-%d %H:%M:%S')"
if [ -n "$*" ]; then
    msg="$*"
fi
git commit -m "$msg"

git pull --rebase origin master
# Push source and build repos.
git push -f origin master


# Push source
cd ..

# Add changes to git.
git add .

git commit -m "$msg"

git pull --rebase origin master
# Push source and build repos.
git push -f origin source 
