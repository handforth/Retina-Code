# plugin_unterminated.zsh — second Zsh sample: a prompt/plugin script.
# It ends inside an unterminated heredoc, then inside an unterminated quote within it.

0=${(%):-%N}
PLUGIN_DIR=${0:A:h}
typeset -gA _plug_cache
typeset -g _plug_version="1.4.2"

(( $+commands[git] )) || { print -u2 "git is required"; return 1 }

_plug_log() {
  local level=$1; shift
  local color
  case $level in
    (debug) color=8 ;;
    (info)  color=4 ;;
    (warn)  color=3 ;;
    (error) color=1 ;;
    (*)     color=7 ;;
  esac
  print -P "%F{$color}[${(U)level}]%f $*" >&2
}

_plug_git_branch() {
  local ref
  ref=$(command git symbolic-ref --quiet HEAD 2>/dev/null) || \
    ref=$(command git rev-parse --short HEAD 2>/dev/null) || return 0
  print -n -- "${ref#refs/heads/}"
}

_plug_git_dirty() {
  local -a st
  st=("${(@f)$(command git status --porcelain=v1 2>/dev/null)}")
  (( ${#st[@]} > 0 )) && [[ -n ${st[1]} ]] && print -n "*"
}

_plug_precmd() {
  local exit_code=$?
  local elapsed=$(( EPOCHREALTIME - ${_plug_cache[start]:-$EPOCHREALTIME} ))
  local branch="$(_plug_git_branch)"
  local dirty="$(_plug_git_dirty)"
  local -a parts=()
  [[ -n $branch ]] && parts+=("%F{magenta} ${branch}${dirty}%f")
  (( elapsed > 2 )) && parts+=("%F{yellow}$(printf '%.1fs' $elapsed)%f")
  (( exit_code != 0 )) && parts+=("%F{red}✘ ${exit_code}%f")
  PROMPT="%F{cyan}%~%f ${(j: :)parts}"$'\n'"%(!.#.❯) "
  unset '_plug_cache[start]'
}

_plug_preexec() {
  _plug_cache[start]=$EPOCHREALTIME
  _plug_cache[last_cmd]=$1
}

autoload -Uz add-zsh-hook
add-zsh-hook precmd _plug_precmd
add-zsh-hook preexec _plug_preexec

# Widgets
_plug_sudo_toggle() {
  if [[ $BUFFER == sudo\ * ]]; then
    BUFFER=${BUFFER#sudo }
  else
    BUFFER="sudo $BUFFER"
  fi
  CURSOR=$#BUFFER
}
zle -N _plug_sudo_toggle
bindkey '\e\e' _plug_sudo_toggle

# Completion function
_plug_complete() {
  local -a subcmds
  subcmds=(
    'install:install a plugin'
    'update:update all plugins'
    "remove:remove a plugin (it's permanent)"
    'list:list installed plugins'
  )
  _arguments -C \
    '(-h --help)'{-h,--help}'[show help]' \
    '(-v --verbose)'{-v,--verbose}'[verbose output]' \
    '1: :->cmd' \
    '*:: :->args' && return
  case $state in
    cmd) _describe -t commands 'plug command' subcmds ;;
    args) _files -g '*.zsh(-.)' ;;
  esac
}
compdef _plug_complete plug

plug() {
  local cmd=${1:-list}; shift 2>/dev/null
  case $cmd in
    install)
      local repo=$1 dest="$PLUGIN_DIR/plugins/${${1:t}%.git}"
      [[ -d $dest ]] && { _plug_log warn "already installed: $dest"; return 0 }
      command git clone --depth=1 "https://github.com/${repo}.git" "$dest" &&
        _plug_log info "installed ${repo}"
      ;;
    update)
      for d in $PLUGIN_DIR/plugins/*(/N); do
        ( cd "$d" && command git pull --ff-only -q ) &
      done
      wait
      ;;
    remove)
      rm -rf -- "$PLUGIN_DIR/plugins/${1:?plugin name required}"
      ;;
    list)
      print -l -- $PLUGIN_DIR/plugins/*(/N:t)
      ;;
    *)
      _plug_log error "unknown command '$cmd'"
      return 64
      ;;
  esac
}

# Load plugins in sorted order, skipping disabled ones
for f in $PLUGIN_DIR/plugins/*/*.plugin.zsh(N-.on); do
  [[ ${f:h:t} == (#i)disabled-* ]] && continue
  source "$f" || _plug_log error "failed to source ${f:t}"
done

# Expansion edge cases on line boundaries
long_value="first line \
second line joined"
array=(
  "element one"
  'element two'
  $'element\tthree'
)
math=$((
  1 + 2
  * 3
))
subst=$(
  echo "multi-line"
  echo "command substitution"
)

# The final heredoc is never terminated, and contains an unbalanced quote.
cat > "$PLUGIN_DIR/README.generated" <<README
# Plug ${_plug_version}

Usage: plug [install|update|remove|list] "args"
Generated on $(date '+%Y-%m-%d') by ${USER}.
It's missing the terminator line, and this "quote never closes
plug install user/repo
