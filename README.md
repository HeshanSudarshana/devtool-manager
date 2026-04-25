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
- **Maven** - Apache Maven (native implementation)
- **Gradle** - Gradle Build Tool (native implementation)
- **Go** - Go Programming Language (native implementation with separate GOPATH per version)
- **Node.js** - Prebuilt tarballs from nodejs.org (sha256 verified, LTS-aware)
- **Python** - Prebuilt CPython from `astral-sh/python-build-standalone` (sha256 verified)

## Installation

1. Clone or download this repository
2. Run the installation script:

```bash
cd /home/heshan/development/devtools/devtool-manager
./install.sh
```

The installer will:
- ✅ Install dtm to `~/.local/bin/dtm`
- ✅ Set up auto-apply wrapper (dtm.sh) in your shell config
- ✅ Install shell completion (bash / zsh / fish)

3. **Restart your shell or run:**

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
| `DTM_GRADLE_DIST`  | `https://services.gradle.org`              | `dtm pull/available gradle` |
| `DTM_GO_DIST`      | `https://go.dev`                           | `dtm pull/available go` |
| `DTM_GO_CHECKSUM`  | `https://dl.google.com/go`                 | `dtm pull go` (sha256 sidecars) |
| `DTM_NODE_DIST`    | `https://nodejs.org/dist`                  | `dtm pull/available node` (tarballs + SHASUMS256.txt) |
| `DTM_PBS_REPO`     | `https://api.github.com/repos/astral-sh/python-build-standalone` | `dtm available python` (release listing) |
| `DTM_PBS_DIST`     | `https://github.com/astral-sh/python-build-standalone/releases/download` | `dtm pull python` (tarballs + sha256) |
| `DTM_PBS_LATEST`   | `https://raw.githubusercontent.com/astral-sh/python-build-standalone/latest-release/latest-release.json` | `dtm pull/available python` (resolve latest tag) |

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

The modular structure makes it easy to add support for more tools. Each tool has its own module in the `modules/` directory implementing:

- `pull_<tool>` - Download and install
- `set_<tool>` - Activate version
- `list_<tool>` - List installed versions
- `current_<tool>` - Print the active version
- `available_<tool>` - Query upstream for installable versions (optional)
- `remove_<tool>` - Remove version

## License

Apache License 2.0
