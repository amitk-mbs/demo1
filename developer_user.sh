#!/usr/bin/env bash
# ==============================================================================
# Script Name : developer_user.sh (or "developer user")
# Description : Config-Driven Developer Workspace Initializer & Release Manifest Generator.
#               - Reads master repo and submodules from developer_config.json
#               - Recursively initializes all submodules (including nested submodules)
#               - Generates RELEASE_NOTES.md with full hierarchy, commit IDs, and tags
#               - Sets up development/ workspace and automated MATLAB path mounting
# ==============================================================================

set -euo pipefail

# ==============================================================================
# DEFAULT CONFIGURATION
# ==============================================================================
CONFIG_FILE="${CONFIG_FILE:-developer_config.json}"
MASTER_REPO_URL="${REPO_URL:-}"
MASTER_VERSION="${BRANCH:-}"
TARGET_WORKSPACE_DIR=""
declare -A SUBMODULE_VERSION_OVERRIDES=()

ACTION="setup"
SHIFT_TARGET="all"

COLOR_RESET="\033[0m"
COLOR_INFO="\033[1;36m"
COLOR_SUCCESS="\033[1;32m"
COLOR_WARN="\033[1;33m"
COLOR_ERROR="\033[1;31m"
COLOR_HEADER="\033[1;35m"

log_info()    { echo -e "${COLOR_INFO}[INFO]${COLOR_RESET} $*"; }
log_success() { echo -e "${COLOR_SUCCESS}[SUCCESS]${COLOR_RESET} $*"; }
log_warn()    { echo -e "${COLOR_WARN}[WARN]${COLOR_RESET} $*"; }
log_error()   { echo -e "${COLOR_ERROR}[ERROR]${COLOR_RESET} $*"; }
log_header()  { echo -e "${COLOR_HEADER}$*${COLOR_RESET}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ==============================================================================
# CLI ARGUMENT PARSER
# ==============================================================================
print_help() {
    cat << EOF
Usage: $(basename "$0") [ACTION] [OPTIONS]

Actions:
  setup           (Default) Clone repo, init recursive submodules, generate RELEASE_NOTES.md & setup MATLAB
  update          Pull latest updates for master and all recursive submodules
  shift-release   Promote finalized models and scripts from development/ to release/
  status          Display current repository and recursive submodule git status & versions

Options:
  -c, --config <file>            Path to JSON configuration file (default: developer_config.json)
  -r, --repo-url <url>           Git URL of the repository (overrides config file)
  -m, --master-version <ver>     Branch, tag, or commit for master repo (overrides config file)
  -d, --workspace-dir <path>     Directory path for local workspace (overrides default ./<repo_name>)
  --submodule <name>=<version>   Custom tag/branch override for a specific submodule
  --target <filename|all>        Target artifact when using shift-release (default: all)
  -h, --help                     Show this help message and exit

Examples:
  ./developer_user.sh setup
  ./developer_user.sh setup -c "developer_config.json"
  ./developer_user.sh setup -m "develop"
  ./developer_user.sh status
EOF
}

# Scan arguments once to extract --config if specified
ARGS=("$@")
for ((i=0; i<${#ARGS[@]}; i++)); do
    if [[ "${ARGS[i]}" == "-c" || "${ARGS[i]}" == "--config" ]]; then
        CONFIG_FILE="${ARGS[i+1]}"
    fi
done

# ==============================================================================
# CONFIG FILE LOADER (JSON Parser using Python or fallback)
# ==============================================================================
RESOLVED_CONFIG_PATH=""
if [[ -f "$CONFIG_FILE" ]]; then
    RESOLVED_CONFIG_PATH="$CONFIG_FILE"
elif [[ -f "${SCRIPT_DIR}/${CONFIG_FILE}" ]]; then
    RESOLVED_CONFIG_PATH="${SCRIPT_DIR}/${CONFIG_FILE}"
fi

if [[ -n "$RESOLVED_CONFIG_PATH" ]]; then
    log_info "Loading configuration from: ${RESOLVED_CONFIG_PATH}"
    
    if command -v python &>/dev/null || command -v python3 &>/dev/null; then
        PY_CMD=$(command -v python3 || command -v python)
        
        cfg_url=$("$PY_CMD" -c "import json; d=json.load(open('$RESOLVED_CONFIG_PATH')); print(d.get('master_repo',{}).get('url',''))" 2>/dev/null || true)
        cfg_ver=$("$PY_CMD" -c "import json; d=json.load(open('$RESOLVED_CONFIG_PATH')); print(d.get('master_repo',{}).get('version',''))" 2>/dev/null || true)
        cfg_dir=$("$PY_CMD" -c "import json; d=json.load(open('$RESOLVED_CONFIG_PATH')); print(d.get('workspace_dir',''))" 2>/dev/null || true)
        
        [ -n "$cfg_url" ] && [ -z "$MASTER_REPO_URL" ] && MASTER_REPO_URL="$cfg_url"
        [ -n "$cfg_ver" ] && [ -z "$MASTER_VERSION" ] && MASTER_VERSION="$cfg_ver"
        [ -n "$cfg_dir" ] && [ -z "$TARGET_WORKSPACE_DIR" ] && TARGET_WORKSPACE_DIR="$cfg_dir"
        
        # Load submodule versions into bash associative array
        while IFS='=' read -r sub_k sub_v; do
            if [[ -n "$sub_k" && -n "$sub_v" ]]; then
                SUBMODULE_VERSION_OVERRIDES["$sub_k"]="$sub_v"
            fi
        done < <("$PY_CMD" -c "import json; d=json.load(open('$RESOLVED_CONFIG_PATH')); [print(f'{k}={v}') for k,v in d.get('submodules',{}).items()]" 2>/dev/null || true)
    fi
else
    log_info "No configuration file found at '${CONFIG_FILE}'. Operating in dynamic discovery mode."
fi

# Parse remaining CLI options (CLI options override config file)
while [[ $# -gt 0 ]]; do
    case "$1" in
        setup|update|shift-release|status)
            ACTION="$1"
            shift
            ;;
        -c|--config)
            shift 2
            ;;
        -r|--repo-url)
            MASTER_REPO_URL="$2"
            shift 2
            ;;
        -m|--master-version)
            MASTER_VERSION="$2"
            shift 2
            ;;
        -d|--workspace-dir)
            TARGET_WORKSPACE_DIR="$2"
            shift 2
            ;;
        --submodule)
            IFS='=' read -r sub_name sub_ver <<< "$2"
            SUBMODULE_VERSION_OVERRIDES["$sub_name"]="$sub_ver"
            shift 2
            ;;
        --target)
            SHIFT_TARGET="$2"
            shift 2
            ;;
        -h|--help)
            print_help
            exit 0
            ;;
        *)
            log_error "Unknown option or argument: $1"
            print_help
            exit 1
            ;;
    esac
done

[ -z "$MASTER_VERSION" ] && MASTER_VERSION="main"

# Auto-detect repo URL from current git repo if still empty
if [ -z "$MASTER_REPO_URL" ]; then
    if git rev-parse --is-inside-work-tree &>/dev/null; then
        MASTER_REPO_URL=$(git remote get-url origin 2>/dev/null || echo "")
        log_info "Detected Git remote URL: ${MASTER_REPO_URL}"
    fi
fi

if [ -z "$MASTER_REPO_URL" ]; then
    MASTER_REPO_URL="https://github.com/your-org/COE_AKC_FullSystem.git"
    log_warn "No repository URL supplied. Using default: ${MASTER_REPO_URL}"
fi

# Infer workspace directory from repo URL if not explicitly specified
if [ -z "$TARGET_WORKSPACE_DIR" ]; then
    REPO_BASENAME=$(basename "$MASTER_REPO_URL" .git)
    TARGET_WORKSPACE_DIR="./${REPO_BASENAME}"
fi

# Convert relative workspace path to absolute
if [[ "$TARGET_WORKSPACE_DIR" != /* ]] && [[ "$TARGET_WORKSPACE_DIR" != [A-Za-z]:* ]]; then
    TARGET_WORKSPACE_DIR="${SCRIPT_DIR}/${TARGET_WORKSPACE_DIR#./}"
fi

PROJECT_NAME=$(basename "$TARGET_WORKSPACE_DIR")

# ==============================================================================
# PREREQUISITE VALIDATION
# ==============================================================================
if ! command -v git &> /dev/null; then
    log_error "'git' command was not found in system PATH. Git is required."
    exit 1
fi

# ==============================================================================
# RECURSIVE SUBMODULE DISCOVERY HELPER
# ==============================================================================
# Returns an array of submodule relative paths, ordered hierarchically
get_recursive_submodules() {
    local target_dir="$1"
    local subs=()

    if [ ! -d "$target_dir/.git" ]; then
        echo ""
        return
    fi

    # 1. Use git submodule status --recursive to list all submodules at any depth
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            # Format: ' <sha> <path> (<describe>)' or '+<sha> <path> (<describe>)'
            local sub_path
            sub_path=$(echo "$line" | awk '{print $2}')
            [ -n "$sub_path" ] && subs+=("$sub_path")
        fi
    done < <(git -C "$target_dir" submodule status --recursive 2>/dev/null || true)

    # 2. Filesystem fallback: scan top-level subdirectories for .git
    if [ ${#subs[@]} -eq 0 ]; then
        for item in "${target_dir}"/*; do
            if [ -d "$item" ]; then
                if [ -f "$item/.git" ] || [ -d "$item/.git" ]; then
                    subs+=("$(basename "$item")")
                fi
            fi
        done
    fi

    echo "${subs[@]:-}"
}

# ==============================================================================
# MANIFEST GENERATOR: RELEASE_NOTES.md
# ==============================================================================
generate_release_notes() {
    local target_dir="$1"
    local manifest_file="${target_dir}/RELEASE_NOTES.md"

    local current_date
    current_date=$(date '+%Y-%m-%d %H:%M:%S %Z')

    local master_sha
    master_sha=$(git -C "$target_dir" rev-parse HEAD 2>/dev/null || echo "UNKNOWN")
    local master_short_sha="${master_sha:0:8}"
    local master_branch
    master_branch=$(git -C "$target_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "DETACHED")
    local master_tag
    master_tag=$(git -C "$target_dir" describe --tags --exact-match 2>/dev/null || echo "None")
    local master_msg
    master_msg=$(git -C "$target_dir" log -1 --pretty=format:"%s" 2>/dev/null || echo "N/A")
    master_msg_clean=$(echo "$master_msg" | tr '|' '-')
    local master_author
    master_author=$(git -C "$target_dir" log -1 --pretty=format:"%an (%ad)" --date=short 2>/dev/null || echo "N/A")

    log_info "Generating traceability manifest: ${manifest_file}..."

    cat << EOF > "$manifest_file"
# Release & Workspace Traceability Notes

> **Generated Date:** ${current_date}  
> **Workspace Path:** \`${target_dir}\`  

---

## 1. Master Repository

| Property | Value |
| :--- | :--- |
| **Project Name** | **${PROJECT_NAME}** |
| **Repository URL** | \`${MASTER_REPO_URL}\` |
| **Target Requested Version** | \`${MASTER_VERSION}\` |
| **Active Branch / Ref** | \`${master_branch}\` |
| **Active Tag** | \`${master_tag}\` |
| **Commit SHA** | \`${master_short_sha}\` (\`${master_sha}\`) |
| **Latest Commit Note** | ${master_msg_clean} |
| **Author & Date** | ${master_author} |

---

## 2. Submodules & Nested Submodules Hierarchy

EOF

    read -r -a all_subs <<< "$(get_recursive_submodules "$target_dir")"

    if [ ${#all_subs[@]} -eq 0 ]; then
        echo "*No submodules detected in this repository.*" >> "$manifest_file"
    else
        cat << EOF >> "$manifest_file"
| Level | Submodule Path | Target Config | Active Commit | Tag / Branch Ref | Latest Commit Message |
| :---: | :--- | :---: | :---: | :--- | :--- |
EOF

        for sub_rel in "${all_subs[@]}"; do
            local sub_full="${target_dir}/${sub_rel}"
            
            # Determine nesting level
            local slash_count
            slash_count=$(tr -cd '/' <<< "$sub_rel" | wc -c)
            local level="L$((slash_count + 1))"
            local display_name="$sub_rel"
            if [ "$slash_count" -gt 0 ]; then
                local indent
                indent=$(printf '%*s' "$((slash_count * 2))" '')
                display_name="${indent}└── $(basename "$sub_rel")"
            fi

            local sub_target="${SUBMODULE_VERSION_OVERRIDES[$sub_rel]:-${SUBMODULE_VERSION_OVERRIDES[$(basename "$sub_rel")]:-PINNED}}"
            
            local sub_sha="N/A"
            local sub_short_sha="N/A"
            local sub_ref="N/A"
            local sub_msg="N/A"

            if [ -d "$sub_full" ]; then
                sub_sha=$(git -C "$sub_full" rev-parse HEAD 2>/dev/null || echo "N/A")
                sub_short_sha="${sub_sha:0:8}"
                local exact_tag
                exact_tag=$(git -C "$sub_full" describe --tags --exact-match 2>/dev/null || echo "")
                local cur_branch
                cur_branch=$(git -C "$sub_full" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

                if [ -n "$exact_tag" ]; then
                    sub_ref="Tag: \`${exact_tag}\`"
                elif [ -n "$cur_branch" ] && [ "$cur_branch" != "HEAD" ]; then
                    sub_ref="Branch: \`${cur_branch}\`"
                else
                    sub_ref="Detached HEAD"
                fi

                sub_msg=$(git -C "$sub_full" log -1 --pretty=format:"%s" 2>/dev/null || echo "N/A")
                sub_msg=$(echo "$sub_msg" | tr '|' '-')
            fi

            echo "| **${level}** | \`${display_name}\` | \`${sub_target}\` | \`${sub_short_sha}\` | ${sub_ref} | ${sub_msg} |" >> "$manifest_file"
        done
    fi

    cat << EOF >> "$manifest_file"

---

## 3. Submodule Tree View

\`\`\`text
${PROJECT_NAME} (${master_branch} @ ${master_short_sha})
EOF

    for sub_rel in "${all_subs[@]}"; do
        local sub_full="${target_dir}/${sub_rel}"
        local sub_sha="N/A"
        local sub_ref=""
        if [ -d "$sub_full" ]; then
            sub_sha=$(git -C "$sub_full" rev-parse --short HEAD 2>/dev/null || echo "N/A")
            local tag
            tag=$(git -C "$sub_full" describe --tags --exact-match 2>/dev/null || git -C "$sub_full" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
            [ -n "$tag" ] && sub_ref="(${tag} @ ${sub_sha})" || sub_ref="(@ ${sub_sha})"
        fi

        local slash_count
        slash_count=$(tr -cd '/' <<< "$sub_rel" | wc -c)
        local indent
        indent=$(printf '%*s' "$((slash_count * 4))" '')
        echo "${indent}└── ${sub_rel} ${sub_ref}" >> "$manifest_file"
    done

    cat << EOF >> "$manifest_file"
\`\`\`

---

## 4. How to Start Working
1. Launch MATLAB using **\`Open MATLAB.bat\`** in the repository root.
2. \`startup.m\` will automatically discover and link all primary and nested submodule directories.
EOF
}

# ==============================================================================
# ACTION: STATUS
# ==============================================================================
do_status() {
    log_header "=================================================================="
    log_header "  Repository & Submodule Hierarchy: ${PROJECT_NAME}"
    log_header "=================================================================="

    if [ ! -d "$TARGET_WORKSPACE_DIR" ]; then
        log_warn "Workspace directory does not exist yet at: $TARGET_WORKSPACE_DIR"
        exit 0
    fi

    local master_branch
    local master_hash
    master_branch=$(git -C "$TARGET_WORKSPACE_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "DETACHED")
    master_hash=$(git -C "$TARGET_WORKSPACE_DIR" rev-parse --short HEAD 2>/dev/null || echo "UNKNOWN")
    local master_tag
    master_tag=$(git -C "$TARGET_WORKSPACE_DIR" describe --tags --exact-match 2>/dev/null || echo "")

    echo -e "Master Repo : \033[1;32m${PROJECT_NAME}\033[0m [Branch: ${master_branch} | Tag: ${master_tag:-None} | SHA: ${master_hash}]"
    echo ""
    log_info "Submodules & Nested Submodules (Discovered recursively):"

    read -r -a all_subs <<< "$(get_recursive_submodules "$TARGET_WORKSPACE_DIR")"
    if [ ${#all_subs[@]} -eq 0 ]; then
        echo "  (No submodules configured)"
    else
        for sub_rel in "${all_subs[@]}"; do
            local sub_full="${TARGET_WORKSPACE_DIR}/${sub_rel}"
            local slash_count
            slash_count=$(tr -cd '/' <<< "$sub_rel" | wc -c)
            local level="L$((slash_count + 1))"
            local prefix="  [${level}] "
            if [ "$slash_count" -gt 0 ]; then
                prefix="    └── [${level}] "
            fi

            local sub_target="${SUBMODULE_VERSION_OVERRIDES[$sub_rel]:-${SUBMODULE_VERSION_OVERRIDES[$(basename "$sub_rel")]:-PINNED}}"
            if [ -d "$sub_full" ]; then
                local sub_hash
                local sub_branch
                local sub_tag
                sub_hash=$(git -C "$sub_full" rev-parse --short HEAD 2>/dev/null || echo "UNKNOWN")
                sub_branch=$(git -C "$sub_full" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "DETACHED")
                sub_tag=$(git -C "$sub_full" describe --tags --exact-match 2>/dev/null || echo "")

                echo -e "${prefix}${sub_rel} : Target: \033[1;36m${sub_target}\033[0m | Active: \033[1;33m${sub_hash}\033[0m (Tag: ${sub_tag:-None}, Ref: ${sub_branch})"
            else
                echo -e "${prefix}${sub_rel} : Target: ${sub_target} | \033[1;31mNOT INITIALIZED\033[0m"
            fi
        done
    fi

    echo ""
    if [ -f "${TARGET_WORKSPACE_DIR}/RELEASE_NOTES.md" ]; then
        log_info "Traceability document available at: ${TARGET_WORKSPACE_DIR}/RELEASE_NOTES.md"
    fi
    log_header "=================================================================="
}

# ==============================================================================
# ACTION: SETUP / UPDATE
# ==============================================================================
do_setup() {
    log_header "=================================================================="
    log_header "  Config-Driven Workspace Setup: ${PROJECT_NAME}"
    log_header "=================================================================="
    log_info "Master Repo    : ${MASTER_REPO_URL}"
    log_info "Master Version : ${MASTER_VERSION}"
    log_info "Workspace Path : ${TARGET_WORKSPACE_DIR}"
    log_header "------------------------------------------------------------------"

    # 1. Clone or sync master repository
    if [ ! -d "$TARGET_WORKSPACE_DIR" ]; then
        log_info "Cloning master repository..."
        git -c protocol.file.allow=always clone "$MASTER_REPO_URL" "$TARGET_WORKSPACE_DIR"
    else
        log_info "Target directory already exists. Fetching updates..."
        if [ ! -d "$TARGET_WORKSPACE_DIR/.git" ]; then
            log_error "Target folder exists but is not a Git repository: $TARGET_WORKSPACE_DIR"
            exit 1
        fi
        git -C "$TARGET_WORKSPACE_DIR" fetch --all --tags --prune || true
    fi

    # 2. Checkout requested Master version
    log_info "Checking out master version: ${MASTER_VERSION}..."
    if git -C "$TARGET_WORKSPACE_DIR" rev-parse --verify "origin/${MASTER_VERSION}" &>/dev/null; then
        git -C "$TARGET_WORKSPACE_DIR" checkout "${MASTER_VERSION}" 2>/dev/null || git -C "$TARGET_WORKSPACE_DIR" checkout -b "${MASTER_VERSION}" "origin/${MASTER_VERSION}"
        git -C "$TARGET_WORKSPACE_DIR" pull origin "${MASTER_VERSION}" 2>/dev/null || true
    else
        git -C "$TARGET_WORKSPACE_DIR" checkout "${MASTER_VERSION}"
    fi

    local current_master_sha
    current_master_sha=$(git -C "$TARGET_WORKSPACE_DIR" rev-parse --short HEAD)
    log_success "Master checked out at commit: ${current_master_sha}"

    # 3. Initialize and update ALL submodules RECURSIVELY (including submodules of submodules)
    log_info "Initializing all submodules and nested submodules recursively..."
    git -C "$TARGET_WORKSPACE_DIR" -c protocol.file.allow=always submodule update --init --recursive

    # 4. Apply version targets to submodules (including nested)
    read -r -a all_subs <<< "$(get_recursive_submodules "$TARGET_WORKSPACE_DIR")"
    for sub_rel in "${all_subs[@]}"; do
        local sub_full_path="${TARGET_WORKSPACE_DIR}/${sub_rel}"
        if [ ! -d "$sub_full_path" ]; then continue; fi

        local target_ver=""
        if [[ -v "SUBMODULE_VERSION_OVERRIDES[$sub_rel]" ]]; then
            target_ver="${SUBMODULE_VERSION_OVERRIDES[$sub_rel]}"
        elif [[ -v "SUBMODULE_VERSION_OVERRIDES[$(basename "$sub_rel")]" ]]; then
            target_ver="${SUBMODULE_VERSION_OVERRIDES[$(basename "$sub_rel")]}"
        fi

        if [ -n "$target_ver" ] && [ "$target_ver" != "PINNED" ]; then
            log_info "Switching submodule '${sub_rel}' to configured target: ${target_ver}..."
            git -C "$sub_full_path" fetch --all --tags --prune || true
            git -C "$sub_full_path" checkout "$target_ver" 2>/dev/null || true
        fi

        local sub_sha
        sub_sha=$(git -C "$sub_full_path" rev-parse --short HEAD 2>/dev/null || echo "N/A")
        log_success "Submodule '${sub_rel}' active at: ${sub_sha}"
    done

    # 5. Ensure development/ workspace exists with standard folders
    local dev_dir="${TARGET_WORKSPACE_DIR}/development"
    mkdir -p "$dev_dir"
    for folder in "Validation" "Tools" "Docu" "CommonFiles"; do
        mkdir -p "${dev_dir}/${folder}"
    done

    # 6. Deploy Generic MATLAB Automation & "Open MATLAB.bat"
    log_info "Deploying MATLAB launchers and path automation..."
    local matlab_files=(
        "setup_project_paths.m"
        "startup.m"
        "clean_project_paths.m"
        "shift_to_release.m"
        "Open MATLAB.bat"
    )

    for item in "${matlab_files[@]}"; do
        if [ -f "${SCRIPT_DIR}/${item}" ]; then
            cp -f "${SCRIPT_DIR}/${item}" "${TARGET_WORKSPACE_DIR}/${item}"
            if [[ "$item" == *.m ]]; then
                cp -f "${SCRIPT_DIR}/${item}" "${dev_dir}/${item}"
            fi
            log_info "  - Deployed: ${item}"
        fi
    done

    # Copy config file into workspace
    if [[ -n "$RESOLVED_CONFIG_PATH" && -f "$RESOLVED_CONFIG_PATH" ]]; then
        cp -f "$RESOLVED_CONFIG_PATH" "${TARGET_WORKSPACE_DIR}/developer_config.json"
        log_info "  - Deployed: developer_config.json"
    fi

    # 7. Generate RELEASE_NOTES.md with full traceability
    generate_release_notes "$TARGET_WORKSPACE_DIR"

    # 8. Display clear console summary
    echo ""
    log_header "=================================================================="
    log_header "  WORKSPACE READY: ${PROJECT_NAME}"
    log_header "=================================================================="
    log_success "Master Repository : ${PROJECT_NAME} (${MASTER_VERSION} @ ${current_master_sha})"
    echo ""
    log_info "Submodule Hierarchy & Checked-Out Versions:"
    for sub_rel in "${all_subs[@]}"; do
        local sub_full="${TARGET_WORKSPACE_DIR}/${sub_rel}"
        local slash_count
        slash_count=$(tr -cd '/' <<< "$sub_rel" | wc -c)
        local level="L$((slash_count + 1))"
        local prefix="  [${level}] "
        [ "$slash_count" -gt 0 ] && prefix="    └── [${level}] "

        local sub_hash
        local sub_ref
        sub_hash=$(git -C "$sub_full" rev-parse --short HEAD 2>/dev/null || echo "N/A")
        sub_ref=$(git -C "$sub_full" describe --tags --exact-match 2>/dev/null || git -C "$sub_full" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
        echo -e "${prefix}${sub_rel} : Commit \033[1;33m${sub_hash}\033[0m [${sub_ref}]"
    done

    echo ""
    log_success "Detailed traceability manifest saved to: RELEASE_NOTES.md"
    log_info "To open MATLAB with all submodules and paths linked:"
    log_info "  - Double-click 'Open MATLAB.bat' in ${TARGET_WORKSPACE_DIR}"
    log_header "=================================================================="
}

# ==============================================================================
# ACTION: SHIFT TO RELEASE
# ==============================================================================
do_shift_release() {
    log_header "=================================================================="
    log_header "  Project: ${PROJECT_NAME} - Shift Artifacts to Release"
    log_header "=================================================================="

    local dev_dir="${TARGET_WORKSPACE_DIR}/development"
    local rel_dir="${TARGET_WORKSPACE_DIR}/release"

    if [ ! -d "$dev_dir" ]; then
        log_error "Development directory not found at: $dev_dir"
        exit 1
    fi

    mkdir -p "$rel_dir"
    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    local backup_dir="${rel_dir}/.backup_${timestamp}"

    local files_to_shift=()
    if [ "$SHIFT_TARGET" == "all" ]; then
        while IFS= read -r file; do
            [ -n "$file" ] && files_to_shift+=("$(basename "$file")")
        done < <(find "$dev_dir" -maxdepth 1 -type f \( -name "*.slx" -o -name "*.mdl" -o -name "MAIN_*.m" \))
    else
        files_to_shift+=("$SHIFT_TARGET")
    fi

    if [ ${#files_to_shift[@]} -eq 0 ]; then
        log_warn "No artifacts matching '${SHIFT_TARGET}' were found in ${dev_dir}."
        exit 0
    fi

    local backed_up=false
    for item in "${files_to_shift[@]}"; do
        if [ -e "${rel_dir}/${item}" ]; then
            if [ "$backed_up" = false ]; then
                mkdir -p "$backup_dir"
                backed_up=true
            fi
            cp -a "${rel_dir}/${item}" "${backup_dir}/"
            log_info "Backed up existing release/${item} -> ${backup_dir}/"
        fi
    done

    local copied_count=0
    for item in "${files_to_shift[@]}"; do
        local src_path="${dev_dir}/${item}"
        local dest_path="${rel_dir}/${item}"
        if [ -e "$src_path" ]; then
            cp -a "$src_path" "$dest_path"
            log_success "Promoted: ${item} -> release/${item}"
            copied_count=$((copied_count + 1))
        fi
    done

    local changelog_file
    changelog_file=$(find "$TARGET_WORKSPACE_DIR" -maxdepth 2 -name "ChangeLog*.md" | head -n 1 || echo "")
    if [ -z "$changelog_file" ]; then
        changelog_file="${TARGET_WORKSPACE_DIR}/ChangeLog_Release.md"
    fi

    local current_date
    current_date=$(date '+%Y-%m-%d %H:%M:%S')
    cat << EOF >> "$changelog_file"

## Promotion to Release (${current_date})
- **Promoted Artifacts:** ${files_to_shift[*]}
- **Status:** Promoted from development/ to release/
- **Backup Created:** ${backup_dir}
EOF
    log_info "Logged promotion in: ${changelog_file}"
    log_success "Shift to release completed successfully (${copied_count} artifact(s) promoted)."
    log_header "=================================================================="
}

# ==============================================================================
# MAIN ROUTER
# ==============================================================================
case "$ACTION" in
    setup|update) do_setup ;;
    status)       do_status ;;
    shift-release)do_shift_release ;;
    *)
        log_error "Unknown action: $ACTION"
        print_help
        exit 1
        ;;
esac
