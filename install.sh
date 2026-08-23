#!/usr/bin/env bash
set -e

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

case "$(uname -s)" in
    Darwin) os="Darwin"; platform_os="macos" ;;
    Linux)  os="Linux"; platform_os="linux" ;;
    MINGW* | MSYS* | CYGWIN*) os="Windows"; platform_os="windows" ;;
    *) echo "Unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac

case "$(uname -m)" in
    x86_64|amd64|AMD64) arch="x86_64" ;;
    arm64|aarch64|ARM64) arch="arm64" ;;
    *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

# Rosetta may report x86_64 on Apple Silicon. Prefer the native arm64 build.
if [ "$os" = "Darwin" ] && [ "$arch" = "x86_64" ]; then
    sysctl_bin="$(command -v sysctl || echo /usr/sbin/sysctl)"
    if [ "$("$sysctl_bin" -n hw.optional.arm64 2>/dev/null || true)" = "1" ]; then
        echo "Apple Silicon detected (Rosetta shell); installing native arm64 build." >&2
        arch="arm64"
    fi
fi

if [ "$os" = "Windows" ]; then
    archive="switchrail_${os}_${arch}.zip"
    binary_name="switchrail.exe"
else
    archive="switchrail_${os}_${arch}.tar.gz"
    binary_name="switchrail"
fi

if [ -n "$TARGET" ]; then
    version="${TARGET#v}"
    tag="v${version}"
    release_base="https://github.com/${REPO}/releases/download/${tag}"
    display_version="$tag"
else
    release_base="https://github.com/${REPO}/releases/latest/download"
    display_version="latest"
fi

tmpdir="$(mktemp -d 2>/dev/null || mktemp -d -t switchrail-install)"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT INT TERM

archive_path="$tmpdir/$archive"
checksums_path="$tmpdir/checksums.txt"
extract_dir="$tmpdir/extract"
mkdir -p "$extract_dir" "$BIN_DIR"

echo "Installing Switchrail ${display_version} (${platform_os}/${arch})..." >&2
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

if [ "$os" = "Windows" ]; then
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

installed="$BIN_DIR/$binary_name"
new_binary="$BIN_DIR/${binary_name}.new.$$"
cp "$binary_path" "$new_binary"
chmod +x "$new_binary" 2>/dev/null || true

if [ "$os" = "Windows" ]; then
    old_binary="$BIN_DIR/${binary_name}.old"
    rm -f "$old_binary" 2>/dev/null || true
    if [ -e "$installed" ] && ! mv -f "$installed" "$old_binary" 2>/dev/null; then
        rm -f "$new_binary" 2>/dev/null || true
        echo "Error: existing $binary_name is locked. Stop Switchrail and retry." >&2
        exit 1
    fi
    if ! mv -f "$new_binary" "$installed"; then
        [ -e "$old_binary" ] && mv -f "$old_binary" "$installed" 2>/dev/null || true
        echo "Error: failed to install $binary_name" >&2
        exit 1
    fi
    rm -f "$old_binary" 2>/dev/null || true
else
    mv -f "$new_binary" "$installed"
fi

echo "Switchrail installed to $installed" >&2

path_has_dir() {
    case ":$PATH:" in *":$1:"*) return 0 ;; *) return 1 ;; esac
}

if [ "$os" != "Windows" ] && ! path_has_dir "$BIN_DIR"; then
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
        echo "Restart your terminal, then run 'switchrail'." >&2
    else
        echo "Add $BIN_DIR to PATH:" >&2
        echo '  export PATH="$HOME/.switchrail/bin:$PATH"' >&2
    fi
elif [ "$os" = "Windows" ]; then
    echo "To use Switchrail from cmd.exe or PowerShell, add %USERPROFILE%\\.switchrail\\bin to PATH." >&2
else
    echo "Run 'switchrail' to get started." >&2
fi
