#!/usr/bin/env fish
# Fish shell lexer stress: quoting, command substitution, variables, functions
# Fish has no heredocs; strings and (cmd) substitutions are the tricky parts.

set -gx EDITOR nvim
set -gx PATH $HOME/.local/bin $PATH
set -U fish_greeting ""
set -l items one "two words" 'three' four\ five
set -g count 0x1F
set --erase OLD_VAR

# Quoting forms
set s1 'single quotes: no $expansion, only \' and \\ escapes'
set s2 "double quotes: $HOME and $USER and (not substituted) and \$literal \"escaped\""
set s3 "command substitution in quotes: $(date +%s) works in fish 3.4+"
set s4 unquoted\ with\ escaped\ spaces
set s5 "trailing backslash \\"
set s6 "multi-line double
quoted string with $USER"
set s7 'multi-line single
quoted string'
set s8 "unterminated double quote at end of line
set s9 after
set s10 \x41é\U0001F600\t\n\e\a\b\r\cA
set s11 "nested $(echo "inner $(echo "deepest")")"
set s12 it\'s
set s13 'brace {a,b} not expanded in quotes'

# Command substitution
set now (date +%s)
set files (ls -1 | string match -r '\.fish$')
set nested (dirname (realpath (command -v fish)))
set lines (string split \n -- (cat /etc/hosts))
echo (math "1 + 2 * 3") (math 10 / 3) (math -s0 "2 ^ 10")
set -l dollar_paren $(pwd)

# Variables and indexing
echo $items[1] $items[-1] $items[2..3] $items[..2] (count $items)
echo $$indirect
echo {$HOME}/suffix $HOME/path
echo $status $pipestatus $argv $argv[1] (status filename) (status line-number)
set -q VAR; and echo "VAR is set"
set -q VAR[1]; or echo "VAR is empty"

# Brace and wildcard expansion
echo {a,b,c}.txt file{1,2,3} {x,y}{1,2}
ls *.fish **/*.md ?.txt
echo ~ ~/projects ~root

# Control flow
if test -n "$EDITOR"; and test -x (command -v $EDITOR)
    echo "editor: $EDITOR"
else if set -q VISUAL
    echo "visual: $VISUAL"
else
    echo "no editor"
end

for f in *.log
    echo "log: $f"
end

for i in (seq 1 2 10)
    if test $i -gt 5
        break
    end
    continue
end

while read -l line
    echo "read: $line"
end < /etc/hostname

switch (uname)
    case Linux
        echo linux
    case Darwin
        echo mac
    case 'CYGWIN*' 'MINGW*'
        echo windows
    case '*'
        echo unknown
end

begin
    echo "grouped"
    echo "commands"
end > /tmp/grouped.txt

not true; or echo "negated"
true && echo "and operator (fish 3.0+)"
false || echo "or operator"
! false; and echo "bang negation"

# Functions
function greet --description 'Say hello' --argument-names name greeting
    set -q name[1]; or set name World
    set -q greeting[1]; or set greeting Hello
    printf '%s, %s!\n' $greeting $name
    return 0
end

function fish_prompt
    set -l last_status $status
    set -l color (set_color green)
    test $last_status -ne 0; and set color (set_color red)
    echo -n -s $color (prompt_pwd) (set_color normal) ' ❯ '
end

function fish_right_prompt
    set -l branch (git branch --show-current 2>/dev/null)
    test -n "$branch"; and echo -n (set_color magenta)" $branch"(set_color normal)
end

function __on_pwd --on-variable PWD
    test -f .nvmrc; and nvm use --silent
end

function mkcd -d "make a dir and cd into it"
    mkdir -p -- $argv[1]; and cd -- $argv[1]
end

# Abbreviations and aliases
abbr -a gco git checkout
abbr -a --position anywhere -- L '| less'
alias ll 'ls -la'
alias gs="git status -sb"

# String builtin with regex
string replace -r '(\w+)@(\w+)' '$2 at $1' user@example
string match -rq '^\d{3}-\d{4}$' -- 555-1234; and echo "phone"
string escape --style=regex 'a.b*c'
string join ', ' $items
string upper -- (string trim "  padded  ")
string repeat -n 3 'ab'

# Redirections
echo error >&2
command 2>/dev/null
command &> /tmp/all.log
command 2>&1 | tee log.txt
command >? /tmp/noclobber.txt
command ^/dev/null   # old fish stderr redirection syntax

# Numbers in math
math 0x10 + 0b101 + 1e3 + 1.5 - .5
math "floor(3.7) + ceil(1.2) + abs(-5) % 3"

# Comment with 'quotes' and "doubles" and (parens) and $vars
echo done # trailing comment
