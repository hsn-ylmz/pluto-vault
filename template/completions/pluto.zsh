#compdef pluto
# zsh completion for pluto. Sourced from your rc file by the installer's shell block.
#
# Project names come from `pluto --names`, which reads projects/*.md on every call — so a
# project created a second ago completes without regenerating anything. The cost is one
# subshell per TAB: a directory listing and some awk.
#
# The `noglob pluto` alias does not interfere: zsh maps noglob to its own _precommand
# handler, which strips the modifier and completes the real command.

_pluto() {
  local -a commands projects
  commands=(
    '--list:list registered projects'
    '-l:list registered projects'
    '--names:one project name per line'
    '--path:print a project directory and exit'
    '--create:register a new project'
    '--edit:open a project entry in $EDITOR'
    '--remove:delete a project entry'
    '--status:git / mtime state of every project'
    '--ask:force the rest to be a question'
    '--help:usage'
    '--version:version'
  )
  # _describe takes the NAME of an array, not its values.
  projects=(${(f)"$(pluto --names 2>/dev/null)"})

  if (( CURRENT == 2 )); then
    _describe -t commands 'pluto command' commands
    _describe -t projects 'project' projects
    return
  fi

  # --path / --edit / --remove each take exactly one project name.
  case "${words[2]}" in
    --path|--edit|--remove)
      (( CURRENT == 3 )) && _describe -t projects 'project' projects
      return
      ;;
  esac

  # After a project name the rest is free text or agent flags — nothing useful to offer.
  return 0
}

# compdef exists only once compinit has run. If this file is sourced too early, say so
# rather than failing silently at the first TAB.
if (( $+functions[compdef] )); then
  compdef _pluto pluto
else
  print -u2 "pluto: completion needs compinit — source completions/pluto.zsh after it"
fi
