#!/usr/bin/env zsh
# Zsh lexer stress: heredocs, parameter expansion, command substitution, globs, quoting
emulate -L zsh
setopt extended_glob null_glob no_unset pipe_fail
zmodload zsh/datetime

typeset -gA CONFIG=(
  [name]="lexer-test"
  [path]='/usr/local/bin'
  ["quoted key"]=value
)
typeset -a items=(one "two words" 'three' $'four\tfive' "six $HOME")
typeset -i count=0x1F
integer n=8#17
float pi=3.14159
local -r readonly_var="can't change"

# Quoting forms
s1='single quotes: no $expansion, no \escapes, no `cmd`'
s2="double quotes: $HOME ${USER:-nobody} $(whoami) `date` \$literal \"escaped\""
s3=$'ANSI-C quoting: \n \t \x41 \u00e9 \e[1m bold \e[0m \' single'
s4=$"locale string $LANG"
s5="nested: $(echo "inner $(echo "deepest ${HOME}")")"
s6="trailing backslash \\"
s7="multi-line double
quoted string with $USER"
s8='it'\''s concatenated quoting'
s9="unterminated double quote at end of line
s10=after
s11=no\ quotes\ with\ escaped\ spaces

# Parameter expansion
echo ${var}
echo ${var:-default} ${var:=assign} ${var:?error message} ${var:+alternate}
echo ${#var} ${var#prefix} ${var##*/} ${var%suffix} ${var%%.*}
echo ${var/old/new} ${var//all/new} ${var:2:5} ${var: -3}
echo ${(U)var} ${(L)var} ${(j:,:)items} ${(s:/:)PATH} ${(k)CONFIG} ${(v)CONFIG}
echo ${(qq)var} ${(f)"$(ls)"} ${(@)items[2,-1]} ${items[(r)t*]} ${#items}
echo ${${var#*.}%%/*} ${(%):-%n@%m} ${=spaced} ${~pattern} ${^items}.bak
echo ${CONFIG[name]} ${CONFIG[(I)*a*]} $items[1] $#items $@ $* $# $? $$ $! $0 $1 ${10}
echo "${array[@]}" "${array[*]}" "${!indirect}"

# Arithmetic
(( count += 1, n *= 2 ))
(( result = (count << 2) | 0x0F & ~n ^ 2 ** 3 ))
echo $(( 10 / 3 )) $(( 10 % 3 )) $(( 1.5 * 2 )) $(( 16#FF )) $(( 2#1010 )) $[ 1 + 2 ]
(( count > 10 )) && echo "big"

# Command substitution and process substitution
now=$(date +%s)
old=`date +%Y-%m-%d`
nested=$(dirname "$(readlink -f "$(which zsh)")")
diff <(sort file1) <(sort file2)
tee >(gzip > out.gz) < input.txt
cat =(echo "zsh temp file substitution")

# Heredocs
cat <<EOF
Plain heredoc with $HOME and ${USER} and $(date)
and "quotes" and 'apostrophes' preserved
EOF

cat <<-EOF
	Tab-stripped heredoc (leading tabs removed)
		double tab line
	EOF

cat <<'EOF'
Quoted delimiter: no $expansion and no $(substitution) and no `backticks`
EOF

cat <<"EOF"
Double-quoted delimiter also disables expansion: $HOME
EOF

cat <<A <<B
first heredoc body $USER
A
second heredoc body
B

read -r -d '' json <<JSON || true
{
  "name": "${CONFIG[name]}",
  "count": $count,
  "escaped": "\$not"
}
JSON

cat <<< "here-string with $HOME"
cat <<<'single quoted here-string'

# Globs and qualifiers
print -l **/*.zsh(.N)
print -l *(/) *(@) *(*) *.txt(om[1,5]) **/*(.Lk+100)
print -l ^*.bak (#i)readme* *.(c|h)(pp|xx)# <1-100>.log
ls -d -- *~*.tmp

# Control flow
if [[ -n $var && $var == *.txt && $var =~ '^[a-z]+\.txt$' ]]; then
  echo "matched: $MATCH ${match[1]}"
elif [[ ! -d $dir || -z "$dir" ]] {
  echo "no dir"
} else
  echo "other"
fi

for f in *.log(N); do echo "$f"; done
for i in {1..10..2}; echo $i
for key val in ${(kv)CONFIG}; do print "$key=$val"; done
while (( n-- > 0 )); do :; done
until [[ -f /tmp/ready ]]; do sleep 0.1; done
repeat 3 echo "repeated"
case $1 in
  start|run) echo "starting" ;;
  stop) echo "stopping" ;|
  -h|--help) usage ;&
  *) echo "unknown: $1" ;;
esac
select opt in a b c; do break; done

# Functions
function greet {
  local name=${1:-World}
  print -P "%F{green}Hello, ${name}!%f"
}
greet2() { echo "short form: $*" }
() { echo "anonymous function: $1" } arg
always_demo() {
  { false } always { echo "always block" }
}

# Redirections and pipes
exec 3>&1 4>/dev/null
cmd 2>&1 | tee log.txt |& grep -v noise >> combined.log
cmd &> all.log
cmd >| clobber.txt
{ echo grouped; echo commands } > grouped.txt
coproc { cat }
print -p "to coprocess"

alias ll='ls -la'
alias -g G='| grep'
alias -s txt=less
bindkey '^R' history-incremental-search-backward
autoload -Uz compinit && compinit
zstyle ':completion:*' menu select
PROMPT='%n@%m %~ %# '
RPROMPT=$'%(?.\u2713.%F{red}%?%f)'

# A comment with a 'quote and a "double and a `backtick
echo done # trailing comment with $(not executed)
