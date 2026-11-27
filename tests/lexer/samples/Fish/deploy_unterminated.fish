# deploy_unterminated.fish — second Fish sample.
# Argument parsing, completions, events; ends inside an unterminated single-quoted string.

function __deploy_usage
    echo 'Usage: deploy [-e|--env ENV] [-n|--dry-run] [-v|--verbose] <service>...'
    echo ''
    echo "Environments: dev, staging, prod (default: \"dev\")"
end

function __deploy_log -a level
    set -e argv[1]
    set -l colors debug brblack info blue warn yellow error red
    set -l idx (contains -i -- $level $colors)
    set -l color normal
    test -n "$idx"; and set color $colors[(math $idx + 1)]
    printf '%s[%s]%s %s\n' (set_color $color) (string upper $level) (set_color normal) "$argv" >&2
end

function deploy --description 'Deploy one or more services'
    argparse --name=deploy 'h/help' 'e/env=' 'n/dry-run' 'v/verbose' 'r/retries=!_validate_int --min 0 --max 10' -- $argv
    or begin
        __deploy_usage
        return 64
    end

    if set -q _flag_help
        __deploy_usage
        return 0
    end

    set -l env (string lower -- (set -q _flag_env; and echo $_flag_env; or echo dev))
    set -l retries (set -q _flag_retries; and echo $_flag_retries; or echo 3)
    if not contains -- $env dev staging prod
        __deploy_log error "unknown environment '$env'"
        return 1
    end

    if test (count $argv) -eq 0
        __deploy_log error 'no services given'
        __deploy_usage
        return 64
    end

    set -l registry "registry.example.com/$env"
    set -l sha (git rev-parse --short HEAD 2>/dev/null; or echo unknown)
    set -l started (date +%s)

    for svc in $argv
        set -l image "$registry/$svc:$sha"
        set -l attempt 1
        __deploy_log info "deploying $svc → $image (attempt $attempt/$retries)"
        if set -q _flag_dry_run
            echo "would run: kubectl -n $env set image deployment/$svc $svc=$image"
            continue
        end
        while test $attempt -le $retries
            if kubectl -n $env set image deployment/$svc $svc=$image 2>/tmp/deploy.err
                and kubectl -n $env rollout status deployment/$svc --timeout=120s
                __deploy_log info "$svc deployed"
                break
            end
            __deploy_log warn "attempt $attempt failed: "(string collect < /tmp/deploy.err)
            set attempt (math $attempt + 1)
            sleep (math "2 ^ $attempt")
        end
        if test $attempt -gt $retries
            __deploy_log error "giving up on $svc after $retries attempts"
            return 2
        end
    end

    set -l elapsed (math (date +%s) - $started)
    __deploy_log info (printf 'done in %ds (%s)' $elapsed (string join ', ' -- $argv))
    emit deploy_finished $env $argv
end

function __deploy_on_finish --on-event deploy_finished
    set -l env $argv[1]
    set -e argv[1]
    if test "$env" = prod
        curl -fsS -X POST -H 'Content-Type: application/json' \
            -d (printf '{"text": "Deployed %s to prod"}' (string join ' ' $argv)) \
            "$SLACK_WEBHOOK_URL" >/dev/null
        or __deploy_log warn 'slack notification failed'
    end
end

function __deploy_on_exit --on-event fish_exit
    rm -f /tmp/deploy.err
end

# Completions
complete -c deploy -f
complete -c deploy -s h -l help -d 'Show help'
complete -c deploy -s e -l env -x -a 'dev staging prod' -d 'Target environment'
complete -c deploy -s n -l dry-run -d "Print commands, don't run them"
complete -c deploy -s v -l verbose -d 'Verbose output'
complete -c deploy -s r -l retries -x -a '(seq 0 10)' -d 'Retry count'
complete -c deploy -a '(kubectl get deployments -o name 2>/dev/null | string replace deployment/ "")' -d 'Service'

# Universal-variable driven config
set -q DEPLOY_DEFAULT_ENV; or set -U DEPLOY_DEFAULT_ENV dev
set -q SLACK_WEBHOOK_URL; or set -gx SLACK_WEBHOOK_URL 'https://hooks.example.com/services/XXX'

# Edge cases at line boundaries
set -l multi_cmd (
    echo first
    echo second
)
set -l joined "line one \
line two"
set -l escaped_newline line\
continued
set -l list \
    alpha \
    beta \
    'gamma delta'
echo $list[2..-1]
echo "quote with (parens) and {braces} and [brackets] inside"
echo 'single with $no and (no) expansion'
echo "dollar at end $"
echo "escaped dollar \$HOME and escaped paren \(not\)"
echo before # comment with "quotes" and 'more
echo after

# Functions with special flags and event handlers
function __deploy_on_signal --on-signal INT
    __deploy_log warn 'interrupted; cleaning up'
    rm -f /tmp/deploy.err
end

function __deploy_on_job --on-job-exit caller
    __deploy_log debug "job exited: $argv"
end

function deploy-status --wraps kubectl
    for env in dev staging prod
        set -l pods (kubectl -n $env get pods -o name 2>/dev/null | count)
        printf '%-8s %3d pods\n' $env $pods
    end
end

# String manipulation pipelines
set -l versions (git tag --list 'v*' | string replace -r '^v' '' | sort -V)
set -l latest $versions[-1]
set -l parts (string split . -- $latest)
set -l next_patch (math $parts[3] + 1)
echo "next: v$parts[1].$parts[2].$next_patch"
string match -q -r '^\d+\.\d+\.\d+$' -- $latest; or echo "bad version '$latest'"
printf '%s\n' $versions | string match -e -- '-rc'
set -l padded (string pad -w 10 -c '.' -- 'right')
set -l shortened (string shorten -m 8 -- 'a very long string')

# The final string below never closes.
set -l notes 'Remember to rotate the deploy keys.
It'\''s escaped here, but the next apostrophe opens a new string that never ends: it's
deploy --env prod api web
end
