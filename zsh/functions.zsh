gg() {
    local branch="$1"

    if [ -z "$branch" ]; then
        echo "Usage: git go <branch>"
        return 1
    fi

    # Step 1: find project root
    local git_dir
    git_dir=$(git rev-parse --git-dir 2>/dev/null)
    local return_code=$?
    if [ $return_code -ne 0 ]; then
        echo "Error: not under a project" >&2
        return 1
    fi

    if [ "$git_dir" = ".git" ]; then
        # under the project root
        project_root=$(pwd)
    elif [ "$(git rev-parse --is-bare-repository 2>/dev/null)" = "true" ]; then
        if [ "$git_dir" = "." ]; then
            git_dir=$(pwd)
        fi
        project_root=$(dirname "$git_dir")
    else
        git_dir=$(git rev-parse --show-toplevel)
        project_root=$(dirname "$git_dir")
    fi

    # Path of the target worktree (sanitize branch for filesystem path)
    local sanitized_branch
    sanitized_branch=$(printf %s "$branch" | tr -cs 'A-Za-z0-9._-' '-')
    local wt_path="$project_root/$sanitized_branch"

    # Step 2: if worktree exists, cd into it
    if [ -d "$wt_path" ]; then
        cd "$wt_path" || return
        return 0
    fi

    # Step 3: otherwise create the worktree
    git -C "$project_root" worktree add "$wt_path" "$branch" 2>/dev/null \
        || git -C "$project_root" worktree add "$wt_path" -b "$branch"

    cd "$wt_path" || return
}

# Completion for `gg`: suggest local branches.
_gg() {
    local -a branches
    local out

    if git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
        out=$(git for-each-ref --sort=-committerdate --format='%(refname:short)' refs/heads 2>/dev/null)
    elif [ -d .git ]; then
        out=$(git -C .git for-each-ref --sort=-committerdate --format='%(refname:short)' refs/heads 2>/dev/null)
    else
        return 1
    fi

    [[ -z $out ]] && return 1
    branches=(${=out})
    compadd -o nosort -Q -- $branches
}
compdef _gg gg

alias gw="git worktree list"
