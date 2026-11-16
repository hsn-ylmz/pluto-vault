# bash completion for pluto. Sourced from your rc file by the installer's shell block.
#
# pluto takes no project names: it is one entry point, and projects are handled inside the
# conversation. Only its own flags are completed.

_pluto_complete() {
  local cur commands
  cur="${COMP_WORDS[COMP_CWORD]}"
  commands="--list -l --status --help -h --version -q --quick --deep"

  if [ "$COMP_CWORD" -eq 1 ]; then
    COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
  fi
}
complete -F _pluto_complete pluto
