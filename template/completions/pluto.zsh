#compdef pluto
# zsh completion for pluto. Sourced from your rc file by the installer's shell block.
#
# pluto takes no project names: it is one entry point, and projects are handled inside the
# conversation. Only its own flags are completed.
#
# The `noglob pluto` alias does not interfere: zsh maps noglob to its own _precommand
# handler, which strips the modifier and completes the real command.

_pluto() {
  local -a commands
  commands=(
    '--list:list registered projects'
    '-l:list registered projects'
    '--status:git / mtime state of every project'
    '-q:cheap model for this call'
    '--quick:cheap model for this call'
    '--deep:default model for this call'
    '--help:usage'
    '--version:version'
  )
  if (( CURRENT == 2 )); then
    _describe -t commands 'pluto command' commands
  fi
  return 0
}

# compdef exists only once compinit has run. If this file is sourced too early, say so
# rather than failing silently at the first TAB.
if (( $+functions[compdef] )); then
  compdef _pluto pluto
else
  print -u2 "pluto: completion needs compinit — source completions/pluto.zsh after it"
fi
