# Fish completion for dtm (DevTool Manager)
#
# Install:
#   cp dtm.fish ~/.config/fish/completions/

function __dtm_root
    if set -q DTM_HOME; and test -n "$DTM_HOME"
        echo $DTM_HOME
        return
    end
    if test -f $HOME/.dtmconfig
        set -l line (grep -E '^[[:space:]]*export[[:space:]]+DTM_HOME=' $HOME/.dtmconfig 2>/dev/null | tail -1)
        set line (string replace -r '^[^=]*=' '' -- $line)
        set line (string trim -c '"\'' -- $line)
        if test -n "$line"
            echo (eval echo $line)
            return
        end
    end
    echo $HOME/development/devtools
end

function __dtm_installed_versions
    set -l tool $argv[1]
    set -l root (__dtm_root)/$tool
    test -d $root; or return 0
    for d in $root/*/
        test -d $d; or continue
        # Skip the active-version symlink (`current/`).
        test -L (string trim -r -c '/' -- $d); and continue
        echo (basename $d)
    end
end

function __dtm_cmd
    set -l cmd (commandline -opc)
    if test (count $cmd) -ge 2
        echo $cmd[2]
    end
end

function __dtm_tool
    set -l cmd (commandline -opc)
    if test (count $cmd) -ge 3
        echo $cmd[3]
    end
end

function __dtm_at_token
    set -l cmd (commandline -opc)
    test (count $cmd) -eq $argv[1]
end

complete -c dtm -f

# Top-level commands (only when no subcommand chosen yet)
complete -c dtm -n '__dtm_at_token 1' -a pull        -d 'Download and install a tool version'
complete -c dtm -n '__dtm_at_token 1' -a set         -d 'Set tool version globally'
complete -c dtm -n '__dtm_at_token 1' -a use         -d 'Set tool version for current shell only'
complete -c dtm -n '__dtm_at_token 1' -a list        -d 'List installed versions'
complete -c dtm -n '__dtm_at_token 1' -a current     -d 'Print active version of a tool'
complete -c dtm -n '__dtm_at_token 1' -a available   -d 'Query remote for installable versions'
complete -c dtm -n '__dtm_at_token 1' -a update      -d 'Bump active install to latest patch'
complete -c dtm -n '__dtm_at_token 1' -a remove      -d 'Remove an installed version'
complete -c dtm -n '__dtm_at_token 1' -a doctor      -d 'Diagnose dtm environment'
complete -c dtm -n '__dtm_at_token 1' -a self-update -d 'Update dtm itself via git pull'
complete -c dtm -n '__dtm_at_token 1' -a config      -d 'Get or set dtm configuration'

# Tool argument
set -l tool_cmds pull set use list current available update remove
for c in $tool_cmds
    complete -c dtm -n "__dtm_at_token 2; and __dtm_cmd | string match -q $c" -a 'java maven gradle go node python'
end

# config subcommand
complete -c dtm -n '__dtm_at_token 2; and __dtm_cmd | string match -q config' -a home -d 'Get or set DTM_HOME'

# config home <path>
complete -c dtm -n '__dtm_at_token 3; and __dtm_cmd | string match -q config; and __dtm_tool | string match -q home' -F

# Installed-version completion for set/use/remove
for c in set use remove
    complete -c dtm -n "__dtm_at_token 3; and __dtm_cmd | string match -q $c" -a '(__dtm_installed_versions (__dtm_tool))'
end

# available java filters
complete -c dtm -n '__dtm_at_token 3; and __dtm_cmd | string match -q available; and __dtm_tool | string match -q java' \
    -a 'temurin zulu corretto liberica 8 11 17 21'
