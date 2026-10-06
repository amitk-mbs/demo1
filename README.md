# Generic MATLAB/Simulink Repository Developer Toolchain

An automated, **100% generic** developer toolchain for Git repositories containing MATLAB and Simulink models, tools, and submodules.

---

## 1. Zero Hardcoding: Minimal Config-Driven Architecture

This toolchain follows the **Separation of Configuration from Code** principle:
- **Execution Engine (`developer_user.sh` / `developer_user.ps1` / `setup_project_paths.m`):** 100% generic, reusable across any model, ECU, or repository without modification.
- **Project Configuration (`developer_config.json`):** Pure state file containing **only** the master repo URL and the submodule version targets. No development folder clutter or MATLAB blocks needed.

### Clean & Minimal `developer_config.json`:
```json
{
  "master_repo": {
    "url": "https://github.com/your-org/COE_AKC_FullSystem.git",
    "version": "main"
  },
  "submodules": {
    "COE_AKC_Controls": "v1.2.0",
    "COE_AKC_ELD": "develop",
    "COE_AKC_Mechanics_LowFidelity": "PINNED",
    "COE_AKC_Sensors": "PINNED"
  }
}
```

Whenever submodules, branches, or tags change, you simply edit [`developer_config.json`](file:///d:/Projects/Project11/developer_config.json) without touching a single line of script code!

---

## 2. Recursive Submodules & Automatic `RELEASE_NOTES.md` Traceability

Repositories often contain **nested submodules** (submodules of submodules). 

When you run `developer_user`:
1. It recursively clones and updates all submodules at all nesting levels (`L1`, `L2`, etc.).
2. It generates a comprehensive **`RELEASE_NOTES.md`** traceability report in your workspace:
   - Master repo URL, branch, tag, full commit SHA, author, and commit message.
   - Complete table of every submodule and nested submodule with its nesting level, target version, active commit hash, resolved tag/branch, and parent repository.
   - Visual hierarchy tree representation.
3. It prints a clean status summary to your terminal window upon completion.

---

## 2. One-Click Launch: `Open MATLAB.bat`

After cloning any repository, simply double-click **`Open MATLAB.bat`** in the repository root:

- Automatically detects whether MATLAB is in `PATH` or searches `C:\Program Files\MATLAB\R202*\bin\matlab.exe`.
- Automatically sets the active directory to `development/` (if present) or the repository root.
- Automatically executes `startup.m`, which runs `setup_project_paths()`.
- Dynamically discovers all submodules, configuration files (`IniFiles*`), and tools, mounting them onto the MATLAB search path.

---

## 3. Developer Workspace Setup: `developer_user`

The script `developer_user.sh` (or `developer_user.ps1` for PowerShell) clones any repository, initializes all submodules defined in `.gitmodules`, sets up the `development/` workspace, and deploys the path automation files:

### Running in Git Bash / Linux / macOS:
```bash
# Clone any repository and initialize all submodules dynamically:
./developer_user.sh setup -r "https://github.com/your-org/YourRepo.git"

# Or using the alias wrapper:
./developer_user setup -r "https://github.com/your-org/YourRepo.git"

# Specify a custom branch and submodule version override:
./developer_user.sh setup \
    -r "https://github.com/your-org/YourRepo.git" \
    -m "develop" \
    --submodule "SubmoduleName=v1.2.0" \
    -d "./MyWorkspace"
```

### Running in Windows PowerShell:
```powershell
# Basic setup:
.\developer_user.ps1 -Action setup -MasterRepoUrl "https://github.com/your-org/YourRepo.git"

# Check repository and submodule status dynamically:
.\developer_user.ps1 -Action status
```

---

## 4. Automated MATLAB Path Configuration

### Automated via `startup.m`
Whenever MATLAB opens in the repository or when you `cd` into `development/`, `startup.m` runs automatically and invokes `setup_project_paths()`.

### Manual Invocation from MATLAB Command Window:
```matlab
% Mount all project & submodule paths dynamically for the current session
setup_project_paths()

% Mount paths and save permanently to pathdef.m
setup_project_paths('Save', true)

% Clean/remove project paths when switching repositories
clean_project_paths()
```

---

## 5. Shifting Finalized Work to `release/`

When simulation and validation work in `development/` is finalized, models (`.slx`, `.mdl`) and runner scripts (`MAIN_*.m`) can be promoted to `release/`:

### From MATLAB:
```matlab
% Promotes all models and main runner scripts with backup and changelog logging:
shift_to_release()

% Promote a specific file:
shift_to_release('Target', 'System_Model.slx', 'Note', 'Validated test cases')
```

### From the Command Line:
```bash
./developer_user.sh shift-release --target all
# or in PowerShell:
.\developer_user.ps1 -Action shift-release -Target all
```
