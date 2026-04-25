# DevTool Manager (dtm)

A command-line tool to manage development tools like JDK, Maven, Gradle, Go, Node and Python.

## Features

- **Pull**: Download and install specific versions of development tools
- **Set**: Activate a version globally (writes `~/.dtmrc` and applies to current shell)
- **Use**: Activate a version for the current shell only (no persistence)
- **List**: View all installed versions
- **Current**: Show the active version of a tool
- **Available**: Query the upstream registry for installable versions (all tools)
- **Remove**: Uninstall specific versions
- **`.tool-versions` auto-switch**: asdf-style per-project version pinning with optional auto-apply on `cd`

## Supported Tools

- **Java/JDK** - Eclipse Temurin (default), Azul Zulu, Amazon Corretto, BellSoft Liberica
- **Node.js** - Prebuilt tarballs from nodejs.org (sha256 verified, LTS-aware)
- **Python** - Prebuilt CPython from `astral-sh/python-build-standalone` (sha256 verified)

Additional tools shipped via the [candidate descriptor model](#candidates-descriptor-based-tools):

- **Maven** - Apache Maven, Maven Central metadata (sha512)
- **Gradle** - Gradle Build Tool, services.gradle.org (sha256)
- **Go** - Go Programming Language with isolated per-version GOPATH (sha256)
- **Kotlin** - JetBrains Kotlin compiler from GitHub releases (sha256)
- **Scala** - Scala 3 compiler from `scala/scala3` GitHub releases (sha256)
- **sbt** - Scala build tool from `sbt/sbt` GitHub releases (sha256)
- **Ant** - Apache Ant from archive.apache.org (sha512)
- **Terraform** - HashiCorp Terraform from releases.hashicorp.com (sha256)
- **kubectl** - Kubernetes CLI from dl.k8s.io (sha256)
- **Helm** - Kubernetes package manager from get.helm.sh (sha256)
- **Docker** - Docker engine static binaries from download.docker.com (no sidecar checksum)

Run `dtm tools` for the live list (always reflects shipped + user descriptors).

## Installation

### Quick install (curl)

Requires `git` (used both for the initial clone and for `dtm self-update`).

```bash
curl -fsSL https://raw.githubusercontent.com/HeshanSudarshana/devtool-manager/main/bootstrap.sh | bash
```

To skip prompts (CI / unattended):

```bash
curl -fsSL https://raw.githubusercontent.com/HeshanSudarshana/devtool-manager/main/bootstrap.sh | bash -s -- --yes
```

The bootstrap script clones the repository to `~/.local/share/devtool-manager`
and then runs `install.sh` from there. The clone directory must persist —
`dtm` is symlinked from it and `dtm self-update` does a `git pull` against it.

Overrides:

| Variable      | Default                                                            | Purpose                              |
| ------------- | ------------------------------------------------------------------ | ------------------------------------ |
| `DTM_REPO`    | `https://github.com/HeshanSudarshana/devtool-manager.git`          | Source git URL                       |
| `DTM_REF`     | `main`                                                             | Branch, tag, or commit to check out  |
| `DTM_SRC_DIR` | `~/.local/share/devtool-manager`                                   | Where to clone the source tree       |

Pin to a specific commit for reproducible installs:

```bash
DTM_REF=<commit-sha> curl -fsSL https://raw.githubusercontent.com/HeshanSudarshana/devtool-manager/main/bootstrap.sh | bash
```

If you would rather review the script before executing it (recommended for any
`curl | bash` pattern), download it first:

```bash
curl -fsSLo bootstrap.sh https://raw.githubusercontent.com/HeshanSudarshana/devtool-manager/main/bootstrap.sh
less bootstrap.sh
bash bootstrap.sh
```

### Manual install (clone)

1. Clone this repository
2. Run the installation script:

```bash
git clone https://github.com/HeshanSudarshana/devtool-manager.git
cd devtool-manager
./install.sh
```

The installer will:
- ✅ Install dtm to `~/.local/bin/dtm`
- ✅ Set up auto-apply wrapper (dtm.sh) in your shell config
- ✅ Install shell completion (bash / zsh / fish)

### Post-install

**Restart your shell or run:**

```bash
source ~/.bashrc  # or source ~/.zshrc
```

This enables automatic environment variable application when using `dtm set` commands.

## Usage

### Java/JDK Management

dtm supports multiple Java distributions. Specify one with `<dist>@<version>`;
a bare version implies the default (`temurin`).

| Dist       | Provider                  | Notes                              |
| ---------- | ------------------------- | ---------------------------------- |
| `temurin`  | Eclipse Temurin (default) | sha256 verified                    |
| `zulu`     | Azul Zulu OpenJDK         | sha256 verified                    |
| `corretto` | Amazon Corretto           | sha256; current-latest-of-major only |
| `liberica` | BellSoft Liberica         | sha1 verified (only hash exposed)  |

```bash
# Temurin (default) — bare version
dtm pull java 21
dtm pull java 21.0.5

# Other distributions
dtm pull java zulu@21
dtm pull java corretto@17
dtm pull java liberica@21
dtm pull java liberica@21.0.11+11
```

Set a Java version as active:

```bash
# Set latest installed Temurin 21
dtm set java 21

# Set a specific Zulu install
dtm set java zulu@21.0.11
```

**The changes are automatically applied to your current shell!** No need to source anything manually - the wrapper function takes care of it.

If you haven't sourced `dtm.sh` yet (or in a new shell before adding it to your config):

```bash
source /home/heshan/development/devtools/devtool-manager/dtm.sh
```

Or, if the auto-apply wrapper is not set up, you can manually source the configuration:

```bash
source ~/.dtmrc
```

List installed Java versions:

```bash
dtm list java
```

Remove a Java version:

```bash
dtm remove java 11.0.21
```

### Maven Management

```bash
# Pull latest Maven 3.9
dtm pull maven 3.9

# Pull specific version
dtm pull maven 3.9.6

# Set active version (auto-applies to shell)
dtm set maven 3.9

# List installed versions
dtm list maven

# Remove a version
dtm remove maven 3.9.5
```

### Gradle Management

```bash
# Pull latest Gradle 8.x
dtm pull gradle 8

# Pull specific version
dtm pull gradle 8.5

# Set active version (auto-applies to shell)
dtm set gradle 8

# List installed versions
dtm list gradle

# Remove a version
dtm remove gradle 8.4
```

### Go Management

**Note:** Each Go version gets its own isolated GOPATH workspace.

```bash
# Pull latest Go 1.21
dtm pull go 1.21

# Pull specific version
dtm pull go 1.21.5

# Set active version (auto-applies to shell)
dtm set go 1.21

# Each version has isolated workspace
# GOROOT: ~/development/devtools/go/1.21.x
# GOPATH: ~/development/devtools/go-workspaces/1.21.x

# List installed versions
dtm list go

# Remove a version
dtm remove go 1.20.11
```

### Node.js Management

Native — pulls prebuilt tarballs from `nodejs.org/dist`, verified against the
release `SHASUMS256.txt`. No nvm dependency.

```bash
# Pull (install) Node.js versions
dtm pull node 20          # Install latest Node 20.x
dtm pull node 18.19.0     # Install specific version
dtm pull node lts         # Install latest LTS

# Set active version (auto-applies to shell)
dtm set node 20

# List installed versions
dtm list node

# Query upstream for installable versions
dtm available node        # Majors with LTS marker
dtm available node 22     # All 22.x patches

# Remove a version
dtm remove node 18.19.0
```

Sets `NODE_HOME` and prepends `$NODE_HOME/bin` to `PATH`. Tarballs land in
`$DTM_HOME/node/<version>/`.

### Python Management

Native — pulls prebuilt CPython from
[`astral-sh/python-build-standalone`](https://github.com/astral-sh/python-build-standalone)
releases (the same source `uv` and `mise` use). Sha256 verified. No source
build, no compilers, no `sudo`.

```bash
# Pull (install) Python versions
dtm pull python 3.12      # Latest 3.12.x in newest PBS release
dtm pull python 3.12.7    # Specific patch (must exist in a PBS release)

# Set active version (auto-applies to shell)
dtm set python 3.12.7

# List installed versions
dtm list python

# Query upstream for installable versions
dtm available python      # All CPython versions in the latest PBS release
dtm available python 3.13 # Filter to a series

# Remove a version
dtm remove python 3.11.7
```

Sets `PYTHON_HOME` and prepends `$PYTHON_HOME/bin` to `PATH`. Tarballs land in
`$DTM_HOME/python/<version>/`.

> **Version coverage diverges from pyenv.** PBS ships official CPython
> releases only — no PyPy, no anaconda, no source builds. If `dtm available
> python` doesn't show a version, it's not in a PBS release.

Migrating from nvm/pyenv? Run `dtm doctor` — the `[migration]` section
detects existing `~/.nvm` / `~/.pyenv` installs and prints the corresponding
`dtm pull` commands for each.

### `set` vs `use`

- `dtm set <tool> <version>` — writes the activation to `~/.dtmrc` so new shells inherit it (and applies it to the current shell).
- `dtm use <tool> <version>` — applies only to the current shell. Nothing is persisted to `~/.dtmrc`.

```bash
# global (default, persists)
dtm set java 21

# this shell only
dtm use java 17
```

### Per-project `.tool-versions` (asdf-style)

Drop a `.tool-versions` file in a project root listing one tool per line:

```
java 21
go 1.22
node 20
python 3.12.1
```

Lines starting with `#` are comments. asdf aliases (`nodejs`, `golang`) are recognized.

Apply manually from any directory inside the project:

```bash
# walks up from $PWD, applies each line via `dtm use`
dtm use java 21   # or run a helper, see auto-switch below
```

Or enable **auto-switch on `cd`** by exporting `DTM_AUTO_SWITCH=1` *before* sourcing `dtm.sh`:

```bash
# in ~/.bashrc / ~/.zshrc, before sourcing dtm.sh
export DTM_AUTO_SWITCH=1
source /path/to/devtool-manager/dtm.sh
```

When enabled, dtm walks up from the current directory whenever the prompt is shown (zsh `chpwd` hook / bash `PROMPT_COMMAND`) and applies the nearest `.tool-versions`. Re-applies are skipped when neither the file path nor its mtime changed, so the hook is cheap on no-op cds. Leaving the project tree does **not** revert previously applied versions — they persist until you explicitly switch or open a new shell.

### Listing available (installable) versions

Query the upstream registry for versions you could install. Supported for all tools (`java`, `maven`, `gradle`, `go`, `node`, `python`).

```bash
# Java major releases on Temurin (default; LTS marked)
dtm available java

# All GA patch versions for a specific Temurin major
dtm available java 21

# Other distributions
dtm available java zulu          # Zulu majors
dtm available java zulu@21       # Zulu 21 patches
dtm available java liberica@17   # Liberica 17 patches
dtm available java corretto      # Corretto-supported majors

# Recent Maven / Gradle / Go / Node / Python releases
dtm available maven
dtm available gradle
dtm available go
dtm available node               # Majors with LTS marker
dtm available python             # CPython versions in the latest PBS release

# Filter by prefix
dtm available maven 3.9
dtm available gradle 8
dtm available go 1.22
dtm available node 22
dtm available python 3.13
```

## Candidates (descriptor-based tools)

Most tools ship as **candidates**: small key=value descriptor files under
`modules/candidates/<name>.conf` that drive the generic engine in
`modules/_engine.sh`. Adding a tool means writing a descriptor — no shell
code. Each descriptor declares where to download from, how to verify the
payload, where to find the version list, and where the binary lives inside
the install dir. The engine then provides `pull` / `set` / `use` / `list` /
`current` / `available` / `update` / `remove` for free.

### Descriptor fields

```bash
# --- identity & filesystem layout ---
candidate_name=<id>                     # matches filename (without .conf)
candidate_home_var=<ENV_NAME>           # e.g. KOTLIN_HOME — exported on activation
candidate_extra_vars="<VAR1> <VAR2>"    # additional vars pointing at home dir (e.g. M2_HOME)
candidate_bin_subdir=bin                # subdir under home prepended to PATH
candidate_binary_name=<file>            # executable filename (defaults to basename of binary_check)
candidate_binary_check=bin/<binary>     # path proving a valid install (post-extract sanity check)

# --- archive handling ---
candidate_archive_format=<fmt>          # tar.gz | tgz | tar.xz | zip | binary
candidate_archive_layout=<layout>       # nested        — single top-level dir, contents become install_dir
                                        # flat          — extract directly into install_dir
                                        # flat_to_bin   — single binary at archive root, install as bin/<name>
                                        # nested_to_bin — single top-level dir w/ a binary, install just the binary
                                        # binary        — auto when archive_format=binary

# --- download URLs (templated with ${VERSION}, ${OS}, ${ARCH}, env vars) ---
candidate_download_url='https://.../${VERSION}/foo-${VERSION}-${OS}-${ARCH}.tar.gz'
candidate_checksum_url='https://.../${VERSION}/foo-${VERSION}-${OS}-${ARCH}.tar.gz.sha256'
candidate_checksum_algo=sha256          # sha256 (default) | sha512 | sha1
candidate_checksum_format=single        # single — file body is the bare hash
                                        # multi  — lines `<hash>  <filename>`, grep by basename

# --- per-platform URL aliases (keys: candidate_os_<dtm_os>, candidate_arch_<dtm_arch>) ---
candidate_os_linux=linux                # default; override per tool
candidate_os_mac=darwin
candidate_arch_x64=amd64
candidate_arch_aarch64=arm64

# --- version listing strategy ---
candidate_version_strategy=<name>       # github_releases | hashicorp_releases | maven_central |
                                        # gradle_versions | go_dl | apache_dist
candidate_version_strategy_arg=<arg>    # strategy-dependent (see table below)
candidate_version_filter='<regex>'      # ERE applied to listed versions
candidate_version_tag_prefix=v          # stripped from upstream tags (e.g. v, go)

# --- post-install / workspace (advanced) ---
candidate_post_install_fn=<fn>          # shell function called as: <fn> <install_dir> <version>
candidate_workspace_var=GOPATH          # secondary env var pointing at a per-version sibling dir
candidate_workspace_subdir=go-workspaces
candidate_workspace_bin=bin             # prepended to PATH after bin_subdir
candidate_workspace_init=src,pkg,bin    # subdirs created on pull
```

### Version strategies

| Strategy             | Arg shape                                           | Example                                 |
| -------------------- | --------------------------------------------------- | --------------------------------------- |
| `github_releases`    | `<owner>/<repo>`                                    | `JetBrains/kotlin`                      |
| `hashicorp_releases` | `<product>` (paginated via `?after=<timestamp>`)    | `terraform`                             |
| `maven_central`      | `<artifact_path>`                                   | `org/apache/maven/apache-maven`         |
| `gradle_versions`    | (ignored — uses `services.gradle.org/versions/all`) | —                                       |
| `go_dl`              | (ignored — uses `go.dev/dl/?mode=json`)             | —                                       |
| `apache_dist`        | `<dist_path>;<filename_prefix>;<filename_suffix>`   | `ant/binaries;apache-ant-;-bin.tar.gz`  |
| `dir_index`          | `<base_url>;<filename_prefix>;<filename_suffix>`    | `https://download.docker.com/linux/static/stable/x86_64/;docker-;.tgz` |

### User-defined candidates

Drop a `*.conf` file in `~/.dtm/candidates/` (override via `DTM_USER_CANDIDATES`)
to add a tool without forking dtm. User descriptors are loaded *after* shipped
ones, so a same-named user file overrides the built-in. Run `dtm doctor` to
confirm dtm sees them; `dtm tools` lists every registered candidate.

### Example: kubectl as a single binary

```bash
# ~/.dtm/candidates/kubectl.conf
candidate_name=kubectl
candidate_home_var=KUBECTL_HOME
candidate_binary_check=bin/kubectl
candidate_archive_format=binary
candidate_binary_name=kubectl
candidate_download_url='https://dl.k8s.io/release/v${VERSION}/bin/${OS}/${ARCH}/kubectl'
candidate_checksum_url='https://dl.k8s.io/release/v${VERSION}/bin/${OS}/${ARCH}/kubectl.sha256'
candidate_os_linux=linux
candidate_os_mac=darwin
candidate_arch_x64=amd64
candidate_arch_aarch64=arm64
candidate_version_strategy=github_releases
candidate_version_strategy_arg=kubernetes/kubernetes
candidate_version_tag_prefix=v
candidate_version_filter='^[0-9]+\.[0-9]+\.[0-9]+$'
```

## Directory Structure

By default, all tools are installed under `~/development/devtools/` (configurable via `DTM_HOME`):

```
~/development/devtools/   (or $DTM_HOME)
├── java/
│   ├── 11.0.21/
│   ├── 17.0.9/
│   └── ...
├── maven/
│   ├── 3.9.6/
│   └── ...
├── gradle/
│   ├── 8.5/
│   └── ...
├── go/
│   ├── 1.21.5/
│   └── ...
├── go-workspaces/
│   ├── 1.21.5/
│   │   ├── src/
│   │   ├── pkg/
│   │   └── bin/
│   └── ...
├── node/
│   ├── 20.18.0/
│   └── ...
└── python/
    ├── 3.12.7/
    └── ...
```

To change the installation directory, see the [Configuration](#configuration) section.

## Configuration

### DTM Home Directory

By default, dtm installs all tools under `~/development/devtools/`. You can customize this location:

**Option 1: Using the config command (recommended)**
```bash
# View current DTM_HOME
dtm config home

# Set custom installation directory
dtm config home /path/to/your/devtools

# Restart shell or source the config
source ~/.dtmconfig
```

**Option 2: Set DTM_HOME environment variable**
```bash
# Add to your ~/.bashrc or ~/.zshrc
export DTM_HOME="/path/to/your/devtools"
```

**Option 3: Edit ~/.dtmconfig directly**
```bash
# Create or edit ~/.dtmconfig
echo 'export DTM_HOME="/path/to/your/devtools"' > ~/.dtmconfig

# Source it in your shell config
echo 'source ~/.dtmconfig' >> ~/.bashrc  # or ~/.zshrc
```

**Priority order:**
1. `DTM_HOME` environment variable (highest priority)
2. `DTM_HOME` value in `~/.dtmconfig`
3. Default: `~/development/devtools` (lowest priority)

### Tool Configuration

The tool creates a configuration file at `~/.dtmrc` which contains environment variables for the active tool versions. This file is updated by the `dtm set` command.

### Proxy and Mirrors

dtm uses `curl` for all network requests, so the standard proxy environment
variables are honored automatically — you do not need to configure anything
inside dtm:

```bash
export HTTPS_PROXY=http://proxy.corp:3128
export HTTP_PROXY=http://proxy.corp:3128
export NO_PROXY=localhost,127.0.0.1,.corp
```

Set these in your shell rc, in `~/.dtmconfig`, or per-invocation. `curl` reads
them on every request.

You can also redirect dtm to alternative upstream registries (corporate
caches, Adoptium / Maven / Gradle / Go mirrors) via these env vars:

| Variable           | Default                                    | Used by                |
| ------------------ | ------------------------------------------ | ---------------------- |
| `DTM_TEMURIN_API`  | `https://api.adoptium.net/v3`              | `dtm pull/available java` (Temurin) |
| `DTM_MAVEN_REPO`   | `https://repo.maven.apache.org/maven2`     | `dtm available/update maven` (metadata) |
| `DTM_MAVEN_DIST`   | `https://archive.apache.org/dist/maven`    | `dtm pull maven` (binaries + sha512) |
| `DTM_APACHE_DIST`  | `https://archive.apache.org/dist`          | `apache_dist` strategy (e.g. `dtm pull/available ant`) |
| `DTM_GRADLE_DIST`  | `https://services.gradle.org`              | `dtm pull/available gradle` |
| `DTM_GO_DIST`      | `https://go.dev`                           | `dtm pull/available go` |
| `DTM_GO_CHECKSUM`  | `https://dl.google.com/go`                 | `dtm pull go` (sha256 sidecars) |
| `DTM_NODE_DIST`    | `https://nodejs.org/dist`                  | `dtm pull/available node` (tarballs + SHASUMS256.txt) |
| `DTM_PBS_REPO`     | `https://api.github.com/repos/astral-sh/python-build-standalone` | `dtm available python` (release listing) |
| `DTM_PBS_DIST`     | `https://github.com/astral-sh/python-build-standalone/releases/download` | `dtm pull python` (tarballs + sha256) |
| `DTM_PBS_LATEST`   | `https://raw.githubusercontent.com/astral-sh/python-build-standalone/latest-release/latest-release.json` | `dtm pull/available python` (resolve latest tag) |
| `DTM_DOCKER_DIST`  | `https://download.docker.com`              | `dtm pull/available docker` (static tarballs + index) |
| `DTM_USER_CANDIDATES` | `~/.dtm/candidates`                     | dir scanned for user-defined `*.conf` descriptors |
| `DTM_HASHICORP_MAX_PAGES` | `25`                                | safety cap on `hashicorp_releases` pagination (20 results/page) |

Persist them by adding to `~/.dtmconfig`:

```bash
# ~/.dtmconfig
export DTM_HOME="$HOME/development/devtools"
export HTTPS_PROXY="http://proxy.corp:3128"
export DTM_MAVEN_REPO="https://nexus.corp/repository/maven-public"
export DTM_MAVEN_DIST="https://nexus.corp/repository/apache-maven"
export DTM_TEMURIN_API="https://adoptium.mirror.corp/v3"
```

dtm sources `~/.dtmconfig` on every invocation. Verify the active configuration
with `dtm doctor` (look for the `[network]` section, or use `--json` for the
machine-readable form).

> Note: only Temurin is mirror-aware on the Java side; the Zulu, Corretto, and
> Liberica fetchers still talk to their upstream APIs directly.

## Requirements

- Bash 4.0 or later
- curl
- jq (JSON parsing)
- tar (and unzip for Gradle)
- Linux or macOS

## How It Works

### Java/JDK

1. **Pull**: Downloads JDK from the chosen distribution's API (Temurin, Zulu,
   Corretto, or Liberica)
   - Queries the API for the latest version when only a major is specified
   - Downloads the appropriate tarball for your OS and architecture
   - Verifies the checksum (sha256, or sha1 for Liberica) before extracting
   - Extracts Temurin to `~/development/devtools/java/<version>/`; other
     distributions to `~/development/devtools/java/<dist>-<version>/`
   - Cleans up the downloaded tarball

2. **Set**: Configures environment variables
   - Finds the matching installed version
   - Updates `~/.dtmrc` with `JAVA_HOME` and `PATH`
   - Displays instructions to source the configuration

3. **List**: Shows all installed versions with active version highlighted

4. **Remove**: Safely removes an installed version with confirmation

## Examples

Complete workflow examples:

### Java
```bash
# Install Java 11
dtm pull java 11

# Activate it (auto-applies immediately!)
dtm set java 11

# Verify
java -version

# See all installed versions
dtm list java
```

### Multiple Java versions
```bash
# Install multiple versions
dtm pull java 11
dtm pull java 17
dtm pull java 21

# List them
dtm list java

# Switch between versions
dtm set java 11
java -version

dtm set java 17
java -version
```

### Go with separate workspaces
```bash
# Install Go 1.21
dtm pull go 1.21

# Activate it
dtm set go 1.21

# Each Go version has its own GOPATH
echo $GOROOT  # ~/development/devtools/go/1.21.x
echo $GOPATH  # ~/development/devtools/go-workspaces/1.21.x
```

### Node.js
```bash
# Install latest LTS
dtm pull node lts

# Or a specific major / patch
dtm pull node 20
dtm pull node 20.18.0

# Activate it
dtm set node 20

# Verify
node --version
npm --version
```

### Python
```bash
# Install latest 3.12.x in the newest python-build-standalone release
dtm pull python 3.12

# Or a specific patch
dtm pull python 3.12.7

# Activate it
dtm set python 3.12.7

# Verify
python3 --version
pip3 --version
```

### Unified Management
```bash
# Manage all your dev tools with one consistent interface!
dtm set java 17
dtm set go 1.21
dtm set node 20
dtm set python 3.12.7
dtm set maven 3.9.6
dtm set gradle 8.5

# All changes apply immediately to your current shell!
```

## Contributing

**Preferred path: write a candidate descriptor.** Most new tools fit the
generic engine — drop a `<name>.conf` under `modules/candidates/` (or
`~/.dtm/candidates/` for personal tools) following the
[descriptor format](#descriptor-fields). No shell code, full feature parity
(pull/set/use/list/current/available/update/remove, JSON, `.tool-versions`,
doctor coverage). If the upstream uses a new release listing scheme, add a
`strategy_<name>_list` function in `modules/_engine.sh` and reference it from
`candidate_version_strategy`.

**Legacy per-tool modules** (`modules/{java,node,python}.sh`) only exist for
tools whose distribution model doesn't fit the descriptor (multi-distribution
Java; LTS-aware Node; PBS-flavored Python). Each implements:

- `pull_<tool>` - Download and install
- `set_<tool>` - Activate version
- `list_<tool>` - List installed versions
- `current_<tool>` - Print the active version
- `available_<tool>` - Query upstream for installable versions (optional)
- `remove_<tool>` - Remove version

### Tests

Unit tests live under `tests/` and run with [bats-core](https://github.com/bats-core/bats-core).
They cover pure helpers only — no network, no real downloads.

```bash
# Arch / CachyOS
sudo pacman -S bats shellcheck
# macOS
brew install bats-core shellcheck
# Debian / Ubuntu
sudo apt-get install bats shellcheck

bats tests/
shellcheck dtm dtm.sh install.sh modules/*.sh
```

CI runs both on every push (`.github/workflows/ci.yml`) on Linux and macOS.
dtm requires bash 4+ (uses `declare -gA`); the macOS-default bash 3.2 is not
supported.

## License

Apache License 2.0
