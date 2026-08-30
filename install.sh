#!/usr/bin/env bash
set -eu

REPO="nekstep/switchrail-releases"
TARGET="${1:-}"
BIN_DIR="${SWITCHRAIL_BIN_DIR:-$HOME/.switchrail/bin}"

if [[ -n "$TARGET" ]] && [[ ! "$TARGET" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9._-]+)?$ ]]; then
    echo "Invalid version format: $TARGET (expected X.Y.Z, vX.Y.Z, or prerelease suffix)" >&2
    exit 1
fi

DOWNLOADER=""
if command -v curl >/dev/null 2>&1; then
    DOWNLOADER="curl"
elif command -v wget >/dev/null 2>&1; then
    DOWNLOADER="wget"
else
    echo "Either curl or wget is required but neither is installed" >&2
    exit 1
fi

download_file() {
    local url="$1" output="$2"
    if [ "$DOWNLOADER" = "curl" ]; then
        curl -fsSL --retry 3 --retry-delay 1 -o "$output" "$url"
    else
        wget -q -O "$output" "$url"
    fi
}

download_text() {
    local url="$1"
    if [ "$DOWNLOADER" = "curl" ]; then
        curl -fsSL --retry 3 --retry-delay 1 "$url"
    else
        wget -q -O - "$url"
    fi
}

resolve_latest_tag() {
    local response tag
    response="$(download_text "https://api.github.com/repos/${REPO}/releases/latest")" || return 1
    tag="$(printf '%s\n' "$response" | sed -n 's/^[[:space:]]*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"

    if [[ ! "$tag" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9._-]+)?$ ]]; then
        echo "Error: GitHub returned an invalid latest release tag: ${tag:-<empty>}" >&2
        return 1
    fi

    printf '%s\n' "$tag"
}

report_installed_version() {
    local preferred="$1" command_name="$2" candidate="" output=""

    if [ -f "$preferred" ]; then
        candidate="$preferred"
    elif command -v "$command_name" >/dev/null 2>&1; then
        candidate="$(command -v "$command_name")"
    fi

    if [ -z "$candidate" ]; then
        echo "Installed: not found" >&2
        return
    fi

    if output="$("$candidate" --version 2>/dev/null)" && [ -n "$output" ]; then
        output="$(printf '%s\n' "$output" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
        echo "Installed: $output" >&2
    else
        echo "Installed: version unavailable" >&2
    fi
    echo "  $candidate" >&2
}

case "$(uname -s)" in
    Darwin) os="darwin"; platform_os="macos" ;;
    Linux)  os="linux"; platform_os="linux" ;;
    MINGW* | MSYS* | CYGWIN*) os="windows"; platform_os="windows" ;;
    *) echo "Unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac

case "$(uname -m)" in
    x86_64|amd64|AMD64) arch="amd64" ;;
    arm64|aarch64|ARM64) arch="arm64" ;;
    *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

# Rosetta may report x86_64 on Apple Silicon. Prefer the native arm64 build.
if [ "$os" = "darwin" ] && [ "$arch" = "amd64" ]; then
    sysctl_bin="$(command -v sysctl || echo /usr/sbin/sysctl)"
    if [ "$("$sysctl_bin" -n hw.optional.arm64 2>/dev/null || true)" = "1" ]; then
        echo "Apple Silicon detected (Rosetta shell); installing native arm64 build." >&2
        arch="arm64"
    fi
fi

if [ "$os" = "windows" ]; then
    binary_name="switchrail.exe"
    alias_name="swr.exe"
else
    binary_name="switchrail"
    alias_name="swr"
fi

installed="$BIN_DIR/$binary_name"
alias_path="$BIN_DIR/$alias_name"
report_installed_version "$installed" "$binary_name"

# Refuse to replace an unrelated command in a custom bin directory. A Windows
# alias installed by this script is byte-identical to the primary executable;
# Unix aliases are always relative links to the neighboring binary.
if [ "$os" = "windows" ]; then
    if [ -e "$alias_path" ] && { [ ! -f "$installed" ] || ! cmp -s "$installed" "$alias_path"; }; then
        echo "Error: refusing to replace existing $alias_path because it is not the installed Switchrail binary." >&2
        exit 1
    fi
elif [ -L "$alias_path" ]; then
    alias_target="$(readlink "$alias_path" 2>/dev/null || true)"
    if [ "$alias_target" != "$binary_name" ]; then
        echo "Error: refusing to replace existing symlink $alias_path -> ${alias_target:-<unreadable>}." >&2
        exit 1
    fi
elif [ -e "$alias_path" ]; then
    echo "Error: refusing to replace existing $alias_path because it is not a Switchrail symlink." >&2
    exit 1
fi

if [ -n "$TARGET" ]; then
    version="${TARGET#v}"
    tag="v${version}"
    release_base="https://github.com/${REPO}/releases/download/${tag}"
    display_version="$tag"
else
    if ! tag="$(resolve_latest_tag)"; then
        echo "Error: cannot resolve the latest Switchrail release" >&2
        exit 1
    fi
    release_base="https://github.com/${REPO}/releases/download/${tag}"
    display_version="$tag"
fi

archive_version="${display_version#v}"

if [ "$os" = "windows" ]; then
    archive="switchrail_${archive_version}_${os}_${arch}.zip"
else
    archive="switchrail_${archive_version}_${os}_${arch}.tar.gz"
fi

tmpdir="$(mktemp -d 2>/dev/null || mktemp -d -t switchrail-install)"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT INT TERM

archive_path="$tmpdir/$archive"
checksums_path="$tmpdir/checksums.txt"
extract_dir="$tmpdir/extract"
mkdir -p "$extract_dir" "$BIN_DIR"

echo "Downloading: Switchrail ${display_version} (${platform_os}/${arch})" >&2
echo "  Downloading $archive..." >&2
if ! download_file "${release_base}/${archive}" "$archive_path"; then
    echo "Error: release asset not found: ${release_base}/${archive}" >&2
    exit 1
fi

# Verify GoReleaser checksums when available.
if download_file "${release_base}/checksums.txt" "$checksums_path" 2>/dev/null; then
    expected="$(awk -v file="$archive" '$2 == file { print $1; exit }' "$checksums_path")"
    if [ -z "$expected" ]; then
        echo "Error: $archive is missing from checksums.txt" >&2
        exit 1
    fi

    if command -v sha256sum >/dev/null 2>&1; then
        actual="$(sha256sum "$archive_path" | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
        actual="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
    else
        echo "Warning: no SHA-256 tool found; skipping checksum verification." >&2
        actual="$expected"
    fi

    if [ "$actual" != "$expected" ]; then
        echo "Error: checksum mismatch for $archive" >&2
        exit 1
    fi
    echo "  Checksum verified." >&2
else
    echo "  Warning: checksums.txt not found; continuing without checksum verification." >&2
fi

if [ "$os" = "windows" ]; then
    if command -v unzip >/dev/null 2>&1; then
        unzip -q "$archive_path" -d "$extract_dir"
    else
        echo "Error: unzip is required on Windows Git Bash/MSYS2." >&2
        exit 1
    fi
else
    tar -xzf "$archive_path" -C "$extract_dir"
fi

binary_path="$(find "$extract_dir" -type f -name "$binary_name" -print -quit)"
if [ -z "$binary_path" ]; then
    echo "Error: $binary_name not found inside $archive" >&2
    exit 1
fi

chmod +x "$binary_path" 2>/dev/null || true

new_binary="$BIN_DIR/${binary_name}.new.$$"
cp "$binary_path" "$new_binary"
chmod +x "$new_binary" 2>/dev/null || true

if [ "$os" = "windows" ]; then
    new_alias="$BIN_DIR/${alias_name}.new.$$"
    old_binary="$BIN_DIR/${binary_name}.old"
    old_alias="$BIN_DIR/${alias_name}.old"
    cp "$binary_path" "$new_alias"
    chmod +x "$new_alias" 2>/dev/null || true
    rm -f "$old_binary" "$old_alias" 2>/dev/null || true

    moved_binary=false
    moved_alias=false
    if [ -e "$alias_path" ]; then
        if ! mv -f "$alias_path" "$old_alias" 2>/dev/null; then
            rm -f "$new_binary" "$new_alias" 2>/dev/null || true
            echo "Error: existing $alias_name is locked. Stop Switchrail and retry." >&2
            exit 1
        fi
        moved_alias=true
    fi
    if [ -e "$installed" ] && ! mv -f "$installed" "$old_binary" 2>/dev/null; then
        [ "$moved_alias" = true ] && mv -f "$old_alias" "$alias_path" 2>/dev/null || true
        rm -f "$new_binary" "$new_alias" 2>/dev/null || true
        echo "Error: existing $binary_name is locked. Stop Switchrail and retry." >&2
        exit 1
    fi
    [ -e "$old_binary" ] && moved_binary=true

    if ! mv -f "$new_binary" "$installed"; then
        [ "$moved_binary" = true ] && mv -f "$old_binary" "$installed" 2>/dev/null || true
        [ "$moved_alias" = true ] && mv -f "$old_alias" "$alias_path" 2>/dev/null || true
        rm -f "$new_binary" "$new_alias" 2>/dev/null || true
        echo "Error: failed to install $binary_name" >&2
        exit 1
    fi
    if ! mv -f "$new_alias" "$alias_path"; then
        rm -f "$installed" 2>/dev/null || true
        [ "$moved_binary" = true ] && mv -f "$old_binary" "$installed" 2>/dev/null || true
        [ "$moved_alias" = true ] && mv -f "$old_alias" "$alias_path" 2>/dev/null || true
        rm -f "$new_alias" 2>/dev/null || true
        echo "Error: failed to install $alias_name; the previous installation was restored." >&2
        exit 1
    fi
    rm -f "$old_binary" "$old_alias" 2>/dev/null || true
else
    mv -f "$new_binary" "$installed"
    if [ ! -L "$alias_path" ]; then
        new_alias="$BIN_DIR/${alias_name}.new.$$"
        rm -f "$new_alias" 2>/dev/null || true
        ln -s "$binary_name" "$new_alias"
        mv -f "$new_alias" "$alias_path"
    fi
fi

echo "Switchrail installed to $installed" >&2
echo "Short command installed to $alias_path" >&2

path_has_dir() {
    case ":$PATH:" in *":$1:"*) return 0 ;; *) return 1 ;; esac
}

if [ "$os" != "windows" ] && ! path_has_dir "$BIN_DIR"; then
    user_shell="$(basename "${SHELL:-}")"
    config_file=""
    case "$user_shell" in
        bash) config_file="$HOME/.bashrc" ;;
        zsh)  config_file="$HOME/.zshrc" ;;
        fish) config_file="$HOME/.config/fish/config.fish" ;;
    esac

    if [ -n "$config_file" ]; then
        mkdir -p "$(dirname "$config_file")"
        if [ "$user_shell" = "fish" ]; then
            new_block='# >>> switchrail installer >>>
fish_add_path $HOME/.switchrail/bin
# <<< switchrail installer <<<'
        else
            new_block='# >>> switchrail installer >>>
export PATH="$HOME/.switchrail/bin:$PATH"
# <<< switchrail installer <<<'
        fi

        if grep -qs "switchrail installer" "$config_file" 2>/dev/null; then
            tmp="$config_file.tmp.$$"
            awk '
                /# >>> switchrail installer >>>/ { skip=1; next }
                /# <<< switchrail installer <<</ { skip=0; next }
                !skip { print }
            ' "$config_file" > "$tmp" && mv "$tmp" "$config_file"
        else
            [ -f "$config_file" ] && cp "$config_file" "$config_file.bak.$(date +%s)"
        fi
        printf '\n%s\n' "$new_block" >> "$config_file"
        echo "  Added $BIN_DIR to PATH in $config_file." >&2
        echo "Restart your terminal, then run 'switchrail' or 'swr'." >&2
    else
        echo "Add $BIN_DIR to PATH:" >&2
        echo '  export PATH="$HOME/.switchrail/bin:$PATH"' >&2
    fi
elif [ "$os" = "windows" ]; then
    echo "To use Switchrail from cmd.exe or PowerShell, add %USERPROFILE%\\.switchrail\\bin to PATH." >&2
else
    echo "Run 'switchrail' or 'swr' to get started." >&2
fi
