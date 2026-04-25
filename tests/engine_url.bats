#!/usr/bin/env bats

load test_helper

setup() {
    load_dtm
    candidate_reset
}

@test "candidate_render_url substitutes \${VERSION}" {
    OS=linux ARCH=x64
    run candidate_render_url 'https://example.com/foo-${VERSION}.tgz' '1.2.3'
    [ "$status" -eq 0 ]
    [ "$output" = "https://example.com/foo-1.2.3.tgz" ]
}

@test "candidate_render_url substitutes \${OS} via per-candidate alias" {
    OS=linux ARCH=x64
    candidate_os_linux="pc-linux"
    run candidate_render_url 'https://example.com/foo-${OS}.tgz' '1.0'
    [ "$status" -eq 0 ]
    [ "$output" = "https://example.com/foo-pc-linux.tgz" ]
}

@test "candidate_render_url substitutes \${ARCH} via per-candidate alias" {
    OS=linux ARCH=aarch64
    candidate_arch_aarch64="arm64"
    run candidate_render_url 'https://example.com/foo-${ARCH}.tgz' '1.0'
    [ "$status" -eq 0 ]
    [ "$output" = "https://example.com/foo-arm64.tgz" ]
}

@test "candidate_render_url falls back to raw OS when no alias" {
    OS=linux ARCH=x64
    run candidate_render_url 'https://example.com/${OS}/${ARCH}/foo' '1.0'
    [ "$status" -eq 0 ]
    [ "$output" = "https://example.com/linux/x64/foo" ]
}

@test "candidate_render_url expands env vars in template" {
    OS=linux ARCH=x64
    export DTM_FAKE_MIRROR="https://mirror.example"
    run candidate_render_url '${DTM_FAKE_MIRROR}/foo-${VERSION}.tgz' '2.0'
    unset DTM_FAKE_MIRROR
    [ "$status" -eq 0 ]
    [ "$output" = "https://mirror.example/foo-2.0.tgz" ]
}

@test "candidate_render_url errors on undefined env var" {
    OS=linux ARCH=x64
    unset DTM_DEFINITELY_NOT_SET 2>/dev/null || true
    run candidate_render_url '${DTM_DEFINITELY_NOT_SET}/foo' '1.0'
    [ "$status" -ne 0 ]
}

@test "candidate_render_url handles multiple substitutions" {
    OS=mac ARCH=aarch64
    candidate_os_mac="darwin"
    candidate_arch_aarch64="arm64"
    run candidate_render_url 'https://x.example/${OS}-${ARCH}/v${VERSION}/bin' '3.1.4'
    [ "$status" -eq 0 ]
    [ "$output" = "https://x.example/darwin-arm64/v3.1.4/bin" ]
}

@test "candidate_render_url passes through templates with no placeholders" {
    OS=linux ARCH=x64
    run candidate_render_url 'https://example.com/static.tgz' '1.0'
    [ "$status" -eq 0 ]
    [ "$output" = "https://example.com/static.tgz" ]
}
