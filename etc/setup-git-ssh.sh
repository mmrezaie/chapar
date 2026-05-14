#!/usr/bin/env bash
set -euo pipefail

# Configure this checkout to use GitHub over SSH without reading ~/.ssh.
# The private key should come from SSH_AUTH_SOCK; this script does not configure
# or read identity files.

GITHUB_ED25519_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl'
GITHUB_ED25519_FINGERPRINT='SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU'

usage() {
  cat <<'EOF'
Usage: etc/setup-git-ssh.sh [--print-command|--unset]

Configure this repository's local Git SSH command so git subcommands can use
GitHub SSH remotes without reading ~/.ssh/config, ~/.ssh/known_hosts, or private
key files.

Requirements for push/fetch over SSH after setup:
  - SSH_AUTH_SOCK points at an accessible ssh-agent socket with a GitHub key
  - outbound DNS and SSH to github.com:22 are permitted

Options:
  --print-command   Print the safe GIT_SSH_COMMAND value without editing config
  --unset           Remove the repository-local core.sshCommand override
EOF
}

quote_for_shell() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\''/g")"
}

prepare_known_hosts() {
  known_hosts=$(git rev-parse --git-path info/github_known_hosts)
  case "$known_hosts" in
    /*) ;;
    *) known_hosts="$repo_root/$known_hosts" ;;
  esac
  mkdir -p "$(dirname "$known_hosts")"

  {
    printf '# GitHub SSH host key pinned by etc/setup-git-ssh.sh\n'
    printf '# Expected ED25519 fingerprint: %s\n' "$GITHUB_ED25519_FINGERPRINT"
    printf 'github.com %s\n' "$GITHUB_ED25519_KEY"
  } > "$known_hosts"
  chmod 0644 "$known_hosts"

  actual_fingerprint=$(ssh-keygen -lf "$known_hosts" | awk 'NR == 1 {print $2}')
  if [ "$actual_fingerprint" != "$GITHUB_ED25519_FINGERPRINT" ]; then
    printf 'error: pinned GitHub host key fingerprint mismatch\n' >&2
    printf 'expected: %s\n' "$GITHUB_ED25519_FINGERPRINT" >&2
    printf 'actual:   %s\n' "$actual_fingerprint" >&2
    exit 1
  fi
}

build_ssh_command() {
  known_hosts_q=$(quote_for_shell "$known_hosts")
  printf '%s\n' "ssh -F /dev/null -o UserKnownHostsFile=$known_hosts_q -o GlobalKnownHostsFile=/dev/null -o StrictHostKeyChecking=yes -o UpdateHostKeys=no -o CheckHostIP=no -o IdentityFile=none -o IdentitiesOnly=no -o BatchMode=yes"
}

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
  printf 'error: run this inside a Git worktree\n' >&2
  exit 1
}
cd "$repo_root"

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  --unset)
    if git config --local --get core.sshCommand >/dev/null; then
      unset_error=$(git config --local --unset core.sshCommand 2>&1) || {
        printf 'error: could not remove repository-local core.sshCommand override.\n' >&2
        printf '%s\n' "$unset_error" >&2
        exit 1
      }
      printf 'Removed repository-local core.sshCommand override.\n'
    else
      printf 'No repository-local core.sshCommand override is set.\n'
    fi
    exit 0
    ;;
  --print-command)
    prepare_known_hosts
    build_ssh_command
    exit 0
    ;;
  '')
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

prepare_known_hosts
ssh_command=$(build_ssh_command)

config_error=$(git config --local core.sshCommand "$ssh_command" 2>&1) || {
  printf 'warning: could not update repository-local .git/config.\n' >&2
  printf '%s\n' "$config_error" >&2
  printf '\nPrepared known_hosts anyway. For one command, run:\n' >&2
  printf '  GIT_SSH_COMMAND="$(bash ./etc/setup-git-ssh.sh --print-command)" git <subcommand>\n' >&2
  exit 0
}

printf 'Configured repository-local Git SSH command.\n'
printf 'Known hosts file: %s\n' "$known_hosts"
printf 'Verified GitHub ED25519 fingerprint: %s\n' "$GITHUB_ED25519_FINGERPRINT"
printf '\nNext checks:\n'
printf '  ssh-add -l\n'
printf '  git ls-remote origin HEAD\n'
