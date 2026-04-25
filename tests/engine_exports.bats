#!/usr/bin/env bats

load test_helper

setup() {
    load_dtm
    candidate_reset
}

@test "candidate_emit_exports emits home_var and PATH" {
    candidate_home_var="KOTLIN_HOME"
    candidate_bin_subdir="bin"
    run candidate_emit_exports "/opt/kotlin/1.9.0"
    [ "$status" -eq 0 ]
    [[ "$output" == *'export KOTLIN_HOME="/opt/kotlin/1.9.0"'* ]]
    [[ "$output" == *'export PATH="${KOTLIN_HOME}/bin:${PATH}"'* ]]
}

@test "candidate_emit_exports emits extra_vars" {
    candidate_home_var="JAVA_HOME"
    candidate_bin_subdir="bin"
    candidate_extra_vars="JDK_HOME JRE_HOME"
    run candidate_emit_exports "/opt/jdk/21"
    [ "$status" -eq 0 ]
    [[ "$output" == *'export JDK_HOME="/opt/jdk/21"'* ]]
    [[ "$output" == *'export JRE_HOME="/opt/jdk/21"'* ]]
}

@test "candidate_emit_exports without home_var uses bare home path" {
    candidate_home_var=""
    candidate_bin_subdir="bin"
    run candidate_emit_exports "/opt/kubectl/1.30"
    [ "$status" -eq 0 ]
    [[ "$output" == *'export PATH="/opt/kubectl/1.30/bin:${PATH}"'* ]]
    [[ "$output" != *KOTLIN_HOME* ]]
}

@test "candidate_emit_exports adds workspace_var when set" {
    candidate_home_var="GOROOT"
    candidate_bin_subdir="bin"
    candidate_workspace_var="GOPATH"
    candidate_workspace_bin="bin"
    run candidate_emit_exports "/opt/go/1.22" "/opt/go-workspaces/1.22"
    [ "$status" -eq 0 ]
    [[ "$output" == *'export GOROOT="/opt/go/1.22"'* ]]
    [[ "$output" == *'export GOPATH="/opt/go-workspaces/1.22"'* ]]
    [[ "$output" == *'${GOROOT}/bin:${GOPATH}/bin:${PATH}'* ]]
}

@test "candidate_emit_exports skips workspace export when workspace empty" {
    candidate_home_var="GOROOT"
    candidate_bin_subdir="bin"
    candidate_workspace_var="GOPATH"
    candidate_workspace_bin="bin"
    run candidate_emit_exports "/opt/go/1.22" ""
    [ "$status" -eq 0 ]
    [[ "$output" != *GOPATH* ]]
}
