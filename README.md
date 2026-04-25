# DevTool Manager (dtm)

A command-line tool to manage development tools like JDK, Maven, Gradle, Go, Node and Python.

## Features

- **Pull**: Download and install specific versions of development tools
- **Set**: Activate a version globally (writes `~/.dtmrc` and applies to current shell)
- **Use**: Activate a version for the current shell only (no persistence)
- **List**: View all installed versions
- **Current**: Show the active version of a tool
- **Available**: Query the upstream registry for installable versions (java/maven/gradle/go)
- **Remove**: Uninstall specific versions
- **`.tool-versions` auto-switch**: asdf-style per-project version pinning with optional auto-apply on `cd`

## Supported Tools

- **Java/JDK** - Eclipse Temurin (native implementation)
- **Maven** - Apache Maven (native implementation)
- **Gradle** - Gradle Build Tool (native implementation)
- **Go** - Go Programming Language (native implementation with separate GOPATH per version)
- **Node.js** - Wraps nvm for full Node.js management
- **Python** - Wraps pyenv for full Python management

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
- ✅ **Optionally install nvm** (interactive prompt)
- ✅ **Optionally install pyenv** (interactive prompt)

3. **Restart your shell or run:**

```bash
source ~/.bashrc  # or source ~/.zshrc
```

This enables automatic environment variable application when using `dtm set` commands.

## Usage

### Java/JDK Management

Download and install Java versions from Eclipse Temurin:

```bash
# Pull latest Java 11
dtm pull java 11

# Pull specific Java version
dtm pull java 11.0.21

# Pull latest Java 17
dtm pull java 17

# Pull specific Java 17 version
dtm pull java 17.0.9
```

Set a Java version as active:

```bash
# Set Java 11 (uses latest installed 11.x version)
dtm set java 11

# Set specific Java version
dtm set java 11.0.21
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

### Node.js (via nvm)

dtm wraps nvm to provide a consistent interface while leveraging nvm's power:

```bash
# Pull (install) Node.js versions
dtm pull node 20          # Install latest Node 20.x
dtm pull node 18.19.0     # Install specific version
dtm pull node --lts       # Install latest LTS

# Set active version (auto-applies to shell)
dtm set node 20

# List installed versions
dtm list node

# Remove a version
dtm remove node 18.19.0
```

**Requirements:** nvm is required.
- ✅ **Auto-install**: When you first use `dtm pull node`, it will offer to install nvm for you
- ✅ **Or install manually**:
  ```bash
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh | bash
  ```

**Benefits:**
- Uses nvm under the hood - all nvm features available
- Consistent dtm interface across all tools
- Auto-applies version changes to current shell
- Can still use `nvm` commands directly

### Python (via pyenv)

dtm wraps pyenv to provide a consistent interface while leveraging pyenv's power:

```bash
# Pull (install) Python versions
dtm pull python 3.12.1    # Install Python 3.12.1
dtm pull python 3.11.7    # Install Python 3.11.7

# Set active version (auto-applies to shell)
dtm set python 3.12.1

# List installed versions
dtm list python

# Remove a version
dtm remove python 3.11.7
```

**Requirements:** pyenv is required.
- ✅ **Auto-install**: When you first use `dtm pull python`, it will offer to install pyenv and build dependencies for you
  - **Note:** Unlike Node.js (pre-built binaries), Python must be compiled from source
  - Build dependencies will be automatically installed for:
    - **Arch Linux** (pacman: base-devel, openssl, zlib, xz, tk)
    - **Debian/Ubuntu** (apt-get: build-essential, libssl-dev, zlib1g-dev, etc.)
    - **RHEL/Fedora/CentOS** (yum: gcc, zlib-devel, openssl-devel, etc.)
    - **macOS** (requires Xcode Command Line Tools)
- ✅ **Or install manually**:
  ```bash
  curl https://pyenv.run | bash
  ```
  
  Then add to your `~/.bashrc` or `~/.zshrc`:
  ```bash
  export PYENV_ROOT="$HOME/.pyenv"
  export PATH="$PYENV_ROOT/bin:$PATH"
  eval "$(pyenv init -)"
  ```

**Benefits:**
- Uses pyenv under the hood - all pyenv features available
- Consistent dtm interface across all tools
- Auto-applies version changes to current shell
- Can still use `pyenv` commands directly
- See available versions: `pyenv install --list`

### `set` vs `use`

- `dtm set <tool> <version>` — writes the activation to `~/.dtmrc` so new shells inherit it (and applies it to the current shell). For Python it also runs `pyenv global`.
- `dtm use <tool> <version>` — applies only to the current shell. Nothing is persisted to `~/.dtmrc`. For Python this uses `pyenv shell` instead of `pyenv global` so other shells are unaffected.

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

Lines starting with `#` are comments. asdf aliases (`nodejs`, `golang`) are also recognized.

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

Query the upstream registry for versions you could install. Supported for `java`, `maven`, `gradle`, and `go`. For `node` and `python`, use `nvm ls-remote` and `pyenv install --list` directly.

```bash
# Java major releases on Temurin (LTS marked)
dtm available java

# All GA patch versions for a specific Java major
dtm available java 21

# Recent Maven / Gradle / Go releases
dtm available maven
dtm available gradle
dtm available go

# Filter by prefix
dtm available maven 3.9
dtm available gradle 8
dtm available go 1.22
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
└── go-workspaces/
    ├── 1.21.5/
    │   ├── src/
    │   ├── pkg/
    │   └── bin/
    └── ...
```

**Node.js** and **Python** are managed via nvm and pyenv respectively, which handle their own directory structures.

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

📖 **For detailed configuration guide with examples, see [DTM_HOME_CONFIGURATION.md](DTM_HOME_CONFIGURATION.md)**

### Tool Configuration

The tool creates a configuration file at `~/.dtmrc` which contains environment variables for the active tool versions. This file is updated by the `dtm set` command.

## Requirements

- Bash 4.0 or later
- curl
- tar (and unzip for Gradle)
- Python 3 (for JSON parsing)
- Linux or macOS
  - **Arch Linux** (pacman)
  - **Debian/Ubuntu** (apt-get)
  - **RHEL/Fedora/CentOS** (yum/dnf)
  - **macOS** (homebrew recommended for dependencies)

## How It Works

### Java/JDK

1. **Pull**: Downloads JDK from Eclipse Temurin's API
   - Queries the API for the latest version if only major version is specified
   - Downloads the appropriate tarball for your OS and architecture
   - Extracts to `~/development/devtools/java/<version>/`
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

### Node.js (via nvm)
```bash
# Install Node 20
dtm pull node 20

# Activate it
dtm set node 20

# Verify
node --version
npm --version

# All nvm commands still work
nvm install --lts
nvm use 18
```

### Python (via pyenv)
```bash
# Install Python 3.12
dtm pull python 3.12.1

# Activate it
dtm set python 3.12.1

# Verify
python --version
pip --version

# All pyenv commands still work
pyenv install 3.11.7
pyenv global 3.11.7
```

### Unified Management
```bash
# Manage all your dev tools with one consistent interface!
dtm set java 17
dtm set go 1.21
dtm set node 20
dtm set python 3.12.1
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
