#!/usr/bin/env bats

load test_helper

setup() {
    load_dtm
    candidate_reset
}

@test "candidate_filter_versions strips version_tag_prefix" {
    candidate_version_tag_prefix="v"
    run candidate_filter_versions $'v1.0\nv1.1\nv2.0'
    [ "$status" -eq 0 ]
    [ "$output" = $'1.0\n1.1\n2.0' ]
}

@test "candidate_filter_versions applies version_filter regex" {
    candidate_version_filter='^1\.'
    run candidate_filter_versions $'1.0\n1.1\n2.0\n2.1'
    [ "$status" -eq 0 ]
    [ "$output" = $'1.0\n1.1' ]
}

@test "candidate_filter_versions sorts naturally and dedups" {
    run candidate_filter_versions $'1.10\n1.2\n1.10\n1.9'
    [ "$status" -eq 0 ]
    [ "$output" = $'1.2\n1.9\n1.10' ]
}

@test "candidate_filter_versions drops blank lines" {
    run candidate_filter_versions $'1.0\n\n2.0\n'
    [ "$status" -eq 0 ]
    [ "$output" = $'1.0\n2.0' ]
}

@test "candidate_filter_versions handles empty input" {
    run candidate_filter_versions ''
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "candidate_filter_versions combines prefix strip + filter + sort" {
    candidate_version_tag_prefix="v"
    candidate_version_filter='^1\.'
    run candidate_filter_versions $'v2.0\nv1.10\nv1.2\nv1.10'
    [ "$status" -eq 0 ]
    [ "$output" = $'1.2\n1.10' ]
}
