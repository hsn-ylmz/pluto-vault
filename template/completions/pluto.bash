# bash completion for pluto. Sourced from your rc file by the installer's shell block.
#
# Project names come from `pluto --names`, read fresh on every TAB, so a project created a
# second ago completes without regenerating anything.

_pluto_complete() {
  local cur prev commands
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  commands="--list -l --names --path --create --edit --remove --status --ask --help -h --version"

  case "$prev" in
    --path|--edit|--remove)
      mapfile -t COMPREPLY < <(compgen -W "$(pluto --names 2>/dev/null)" -- "$cur") 2>/dev/null \
        || COMPREPLY=( $(compgen -W "$(pluto --names 2>/dev/null)" -- "$cur") )
      return
      ;;
  esac

  if [ "$COMP_CWORD" -eq 1 ]; then
    COMPREPLY=( $(compgen -W "$commands $(pluto --names 2>/dev/null)" -- "$cur") )
  fi
}
complete -F _pluto_complete pluto
