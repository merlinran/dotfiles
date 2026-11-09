#!/bin/sh
#
# Homebrew
#
# This installs some of the common dependencies needed (or at least desired)
# using Homebrew.
#
# NOTE: the old entrypoint was removed upstream. Homebrew 3 replaced the Ruby
# installer with a shell script and renamed the default branch, so
# `ruby -e "$(curl -fsSL .../master/install)"` is a hard 404 now. Linuxbrew is
# archived as well -- Linux uses the same installer.

set -eu

# Check for Homebrew
if ! command -v brew >/dev/null 2>&1
then
  echo "  Installing Homebrew for you."

  # The installer wants a password (sudo) and a "Press RETURN" confirmation.
  # When we are not attached to a terminal, drop the RETURN prompt so the run
  # does not hang; sudo may still prompt if it needs to. (Upstream aborts if
  # INTERACTIVE and NONINTERACTIVE are both set, so leave it alone then.)
  if ! test -t 0 && test -z "${INTERACTIVE:-}"
  then
    export NONINTERACTIVE=1
  fi

  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  # Put the new brew on this shell's PATH so the callers (bin/dot, script/install)
  # can use it immediately. Apple Silicon installs to /opt/homebrew, Intel macOS
  # to /usr/local, Linux to ~/.linuxbrew or /home/linuxbrew/.linuxbrew.
  for prefix in /opt/homebrew /usr/local /home/linuxbrew/.linuxbrew "$HOME/.linuxbrew"
  do
    if test -x "$prefix/bin/brew"
    then
      eval "$("$prefix/bin/brew" shellenv)"
      echo "  Installed Homebrew at $prefix"
      break
    fi
  done

  if ! command -v brew >/dev/null 2>&1
  then
    echo "  Homebrew install failed: brew is still not on PATH." >&2
    exit 1
  fi
fi

exit 0
