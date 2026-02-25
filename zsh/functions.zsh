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

    if [ "$git_dir" = ".git" ] ||  [ -z "$git_dir" ]; then
        # assuming it's under the project root
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
    local bare_repo_dir
    bare_repo_dir=$(find "$project_root" -maxdepth 1 -type d -name "*.git" | head -n 1)

    local repo_dir
    if [ -n "$bare_repo_dir" ]; then
        repo_dir="$bare_repo_dir"
    else
        repo_dir="$project_root"
    fi

    local current_branch
    current_branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null)

    if git -C "$repo_dir" show-ref --verify --quiet "refs/heads/$branch"; then
        git -C "$repo_dir" worktree add "$wt_path" "$branch"
    elif git -C "$repo_dir" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
        git -C "$repo_dir" worktree add "$wt_path" --track -b "$branch" "origin/$branch"
    elif [ -n "$current_branch" ]; then
        git -C "$repo_dir" worktree add "$wt_path" -b "$branch" "$current_branch"
    else
        git -C "$repo_dir" worktree add "$wt_path" -b "$branch"
    fi

    cd "$wt_path" || return
}

gd() {
    local target="$1"

    if [ -z "$target" ]; then
        echo "Usage: gd <path|branch>"
        return 1
    fi

    # Find project root in the same way as `gg`.
    local git_dir
    git_dir=$(git rev-parse --git-dir 2>/dev/null)
    local return_code=$?
    if [ $return_code -ne 0 ]; then
        echo "Error: not under a project" >&2
        return 1
    fi

    local project_root
    if [ "$git_dir" = ".git" ] || [ -z "$git_dir" ]; then
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

    local bare_repo_dir
    bare_repo_dir=$(find "$project_root" -maxdepth 1 -type d -name "*.git" | head -n 1)

    local repo_dir
    if [ -n "$bare_repo_dir" ]; then
        repo_dir="$bare_repo_dir"
    else
        repo_dir="$project_root"
    fi

    local wt_path
    if [ -d "$target" ]; then
        wt_path=$(cd "$target" && pwd -P)
    elif [ -d "$project_root/$target" ]; then
        wt_path=$(cd "$project_root/$target" && pwd -P)
    else
        wt_path=$(git -C "$repo_dir" worktree list --porcelain | awk -v target="$target" '
            /^worktree / { wt = substr($0, 10) }
            /^branch / {
                br = $2
                short_br = br
                sub("^refs/heads/", "", short_br)
                n = split(wt, parts, "/")
                base = parts[n]
                if (target == br || target == short_br || target == wt || target == base) {
                    print wt
                    exit
                }
            }
        ')
    fi

    if [ -z "$wt_path" ]; then
        echo "Error: could not find a worktree for '$target'" >&2
        return 1
    fi

    git -C "$repo_dir" worktree remove "$wt_path"
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

# Completion for `gd`: suggest local branches and worktree paths.
_gd() {
    local -a branches worktrees all
    local out

    if git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
        branches=(${(f)"$(git for-each-ref --sort=-committerdate --format='%(refname:short)' refs/heads 2>/dev/null)"})
        worktrees=(${(f)"$(git worktree list --porcelain 2>/dev/null | awk '/^worktree / { print substr($0, 10) }')"})
    elif [ -d .git ]; then
        branches=(${(f)"$(git -C .git for-each-ref --sort=-committerdate --format='%(refname:short)' refs/heads 2>/dev/null)"})
        worktrees=(${(f)"$(git -C .git worktree list --porcelain 2>/dev/null | awk '/^worktree / { print substr($0, 10) }')"})
    else
        return 1
    fi

    all=("${branches[@]}" "${worktrees[@]}")
    [[ ${#all[@]} -eq 0 ]] && return 1
    compadd -o nosort -Q -- $all
}
compdef _gd gd

alias gw="git worktree list"
