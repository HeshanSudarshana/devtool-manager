#!/usr/bin/env bats

load test_helper

setup() {
    load_dtm
}

# --- verify_checksum ---------------------------------------------------------

@test "verify_checksum accepts matching sha256" {
    local f="$BATS_TEST_TMPDIR/payload"
    printf 'hello' > "$f"
    # SHA-256 of "hello"
    local hash="2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
    run verify_checksum "$f" "$hash" sha256
    [ "$status" -eq 0 ]
}

@test "verify_checksum rejects mismatched sha256" {
    local f="$BATS_TEST_TMPDIR/payload"
    printf 'hello' > "$f"
    run verify_checksum "$f" "deadbeef" sha256
    [ "$status" -ne 0 ]
    [[ "$output" == *"Checksum mismatch"* ]]
}

@test "verify_checksum rejects empty expected hash" {
    local f="$BATS_TEST_TMPDIR/payload"
    printf 'hello' > "$f"
    run verify_checksum "$f" "" sha256
    [ "$status" -ne 0 ]
}

@test "verify_checksum rejects unsupported algo" {
    local f="$BATS_TEST_TMPDIR/payload"
    printf 'hello' > "$f"
    run verify_checksum "$f" "abc" md5
    [ "$status" -ne 0 ]
}

@test "verify_checksum tolerates uppercase / whitespace in expected" {
    local f="$BATS_TEST_TMPDIR/payload"
    printf 'hello' > "$f"
    local hash="  2CF24DBA5FB0A30E26E83B2AC5B9E29E1B161E5C1FA7425E73043362938B9824  "
    run verify_checksum "$f" "$hash" sha256
    [ "$status" -eq 0 ]
}

# --- dtm_clean_dtmrc_for -----------------------------------------------------

@test "dtm_clean_dtmrc_for removes export VAR= line" {
    local rc="$BATS_TEST_TMPDIR/.dtmrc"
    cat > "$rc" <<'EOF'
export JAVA_HOME="/opt/java/21"
export PATH="${JAVA_HOME}/bin:${PATH}"
export OTHER=keep
EOF
    DTM_CONFIG="$rc" dtm_clean_dtmrc_for JAVA_HOME
    run cat "$rc"
    [[ "$output" != *JAVA_HOME=* ]]
    [[ "$output" == *"export OTHER=keep"* ]]
}

@test "dtm_clean_dtmrc_for removes PATH lines referencing the var" {
    local rc="$BATS_TEST_TMPDIR/.dtmrc"
    cat > "$rc" <<'EOF'
export JAVA_HOME="/opt/java/21"
export PATH="${JAVA_HOME}/bin:${PATH}"
export PATH="$JAVA_HOME/bin:$PATH"
export PATH="${OTHER_HOME}/bin:${PATH}"
EOF
    DTM_CONFIG="$rc" dtm_clean_dtmrc_for JAVA_HOME
    run cat "$rc"
    [[ "$output" != *JAVA_HOME* ]]
    [[ "$output" == *"OTHER_HOME"* ]]
}

@test "dtm_clean_dtmrc_for is a no-op when rc file missing" {
    DTM_CONFIG="$BATS_TEST_TMPDIR/no-such-file" run dtm_clean_dtmrc_for JAVA_HOME
    [ "$status" -eq 0 ]
}

# --- dtm_resolved_path -------------------------------------------------------

@test "dtm_resolved_path resolves a directory symlink" {
    local real="$BATS_TEST_TMPDIR/real"
    local link="$BATS_TEST_TMPDIR/link"
    mkdir -p "$real"
    ln -s "$real" "$link"
    run dtm_resolved_path "$link"
    [ "$status" -eq 0 ]
    [ "$output" = "$(cd "$real" && pwd -P)" ]
}

@test "dtm_resolved_path returns input on missing path with non-zero exit" {
    run dtm_resolved_path "$BATS_TEST_TMPDIR/does-not-exist"
    [ "$status" -ne 0 ]
    [ "$output" = "$BATS_TEST_TMPDIR/does-not-exist" ]
}
