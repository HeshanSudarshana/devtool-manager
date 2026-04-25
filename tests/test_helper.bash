# Common test helpers. Sourced from each .bats file.

load_dtm() {
    export NO_COLOR=1
    export DTM_HOME="${BATS_TEST_TMPDIR}/dtm-root"
    mkdir -p "$DTM_HOME"

    DTM_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export DTM_DIR

    # The BASH_SOURCE guard at the bottom of `dtm` skips main() when sourced.
    # shellcheck source=/dev/null
    source "$DTM_DIR/dtm"
    # main() normally calls source_modules; do it explicitly for unit tests.
    source_modules
}
