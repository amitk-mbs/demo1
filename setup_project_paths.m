function pathList = setup_project_paths(varargin)
% SETUP_PROJECT_PATHS Automatically and generically configures MATLAB/Simulink
% search paths for ANY cloned Git repository and all of its Git submodules.
%
% Usage:
%   setup_project_paths()             % Dynamic addition for current session
%   setup_project_paths('Save', true) % Adds paths and saves them permanently (savepath)
%   setup_project_paths('Quiet', true)% Suppresses verbose console output
%   setup_project_paths('RootDir', 'path/to/repo') % Custom repository root
%
% Key Capabilities:
%   1. 100% Generic: Zero hard-coded project or submodule names. Works for ANY repo.
%   2. Dynamic Root Discovery: Climbs upward from current file to find the Git root.
%   3. Dynamic Submodule Parsing: Reads .gitmodules and scans for nested .git files/folders.
%   4. Deep Asset Discovery: Automatically scans and mounts:
%      - Active working directories (development, dev, src, etc.)
%      - Common utilities & tools (common, tools, scripts, utilities)
%      - Release & test harnesses (release, testruns, tests, validation)
%      - Submodule libraries, models, and parameter folders (IniFiles*, config*, param*)
%   5. Production-Grade Filtering: Safely ignores .git, .github, slprj, resources,
%      temp/work caches, and prevents adding package (+*) or class (@*) directories.
%   6. Toolbox & Model Cache Refresh: Runs 'rehash' to ensure Simulink block libraries
%      and MATLAB functions resolve immediately without manual path re-indexing.

    % 1. Parse Input Arguments
    p = inputParser;
    addParameter(p, 'Save', false, @islogical);
    addParameter(p, 'Quiet', false, @islogical);
    addParameter(p, 'RootDir', '', @ischar);
    parse(p, varargin{:});
    
    saveToPathDef = p.Results.Save;
    isQuiet       = p.Results.Quiet;
    customRoot    = p.Results.RootDir;

    % 2. Detect Repository Root Dynamically
    if ~isempty(customRoot) && isfolder(customRoot)
        projRoot = normalize_path(customRoot);
    else
        projRoot = find_git_root();
    end

    if isempty(projRoot) || ~isfolder(projRoot)
        error('SetupPaths:RootNotFound', ...
            'Could not locate the Git repository root. Please run from within the repository or specify ''RootDir''.');
    end

    [~, projectName] = fileparts(projRoot);

    % Optional: Load project metadata from developer_config.json if available
    configFile = fullfile(projRoot, 'developer_config.json');
    if exist(configFile, 'file')
        try
            cfgData = jsondecode(fileread(configFile));
            if isfield(cfgData, 'project_name') && ~isempty(cfgData.project_name)
                projectName = cfgData.project_name;
            end
        catch
            % Continue if config file cannot be read
        end
    end

    if ~isQuiet
        fprintf('\n=================================================================\n');
        fprintf('  Project Workspace: %s\n', projectName);
        fprintf('  Root Directory   : %s\n', projRoot);
        fprintf('=================================================================\n');
    end

    % 3. Discover Submodules Dynamically
    submoduleList = discover_submodules(projRoot);

    % 4. Build List of Directories to Mount
    pathsToAdd = {};

    % A. Mount Master Repository Directories
    masterDirs = discover_repo_directories(projRoot);
    pathsToAdd = [pathsToAdd, masterDirs];

    % B. Mount All Discovered Submodules & Their Contents
    submoduleStatus = struct();
    for i = 1:length(submoduleList)
        subPath = submoduleList{i};
        [~, subName] = fileparts(subPath);

        if isfolder(subPath)
            subDirs = discover_repo_directories(subPath);
            pathsToAdd = [pathsToAdd, subDirs];

            % Count ini / parameter folders in this submodule
            iniMatches = dir(fullfile(subPath, '*ini*'));
            iniCount = sum([iniMatches.isdir]);
            submoduleStatus.(matlab.lang.makeValidName(subName)) = ...
                sprintf('Mounted (%d folders, %d config/ini dirs)', length(subDirs), iniCount);
        else
            submoduleStatus.(matlab.lang.makeValidName(subName)) = 'NOT INITIALIZED / EMPTY';
        end
    end

    % 5. De-duplicate and Filter Paths
    pathsToAdd = unique(pathsToAdd, 'stable');

    % 6. Apply Paths to MATLAB Search Path
    addedCount = 0;
    for k = 1:length(pathsToAdd)
        curDir = pathsToAdd{k};
        if ~is_on_matlab_path(curDir)
            addpath(curDir, '-begin');
            addedCount = addedCount + 1;
        end
    end

    % 7. Refresh MATLAB and Simulink Caches
    rehash toolboxcache;
    rehash path;

    % 8. Save Path if Requested
    if saveToPathDef
        saveResult = savepath();
        if saveResult == 0
            if ~isQuiet; fprintf('[SUCCESS] Paths saved permanently to pathdef.m\n'); end
        else
            if ~isQuiet; fprintf('[WARN] Unable to save path permanently (insufficient permissions). Active for session.\n'); end
        end
    end

    % 9. Console Status Report
    if ~isQuiet
        if ~isempty(fieldnames(submoduleStatus))
            fprintf('\n[SUBMODULES DETECTED & MOUNTED]:\n');
            subFields = fieldnames(submoduleStatus);
            for i = 1:length(subFields)
                fName = subFields{i};
                fprintf('  - %-32s : %s\n', fName, submoduleStatus.(fName));
            end
        else
            fprintf('\n[INFO] No Git submodules found in this repository.\n');
        end

        fprintf('\n[PATH CONFIGURATION SUMMARY]:\n');
        fprintf('  - Total Project Paths Managed : %d\n', length(pathsToAdd));
        fprintf('  - Newly Mounted This Session  : %d\n', addedCount);
        fprintf('\n[READY] Environment fully configured and linked for simulation!\n');
        fprintf('=================================================================\n\n');
    end

    pathList = pathsToAdd;
end

%% =============================================================================
%% HELPER: Dynamically Discover Git Repository Root
%% =============================================================================
function rootDir = find_git_root()
    startDir = fileparts(mfilename('fullpath'));
    curr = startDir;

    while true
        % Check for .git directory, .git file (worktree/submodule), or .gitmodules
        if exist(fullfile(curr, '.git'), 'file') || exist(fullfile(curr, '.git'), 'dir') ...
           || exist(fullfile(curr, '.gitmodules'), 'file')
            rootDir = curr;
            return;
        end

        parent = fileparts(curr);
        if strcmp(parent, curr)
            % Reached drive root without finding Git markers
            break;
        end
        curr = parent;
    end

    % Fallback to current working directory
    rootDir = pwd;
end

%% =============================================================================
%% HELPER: Recursively Discover Submodules and Nested Submodules
%% =============================================================================
function subList = discover_submodules(projRoot)
    subList = {};
    subList = scan_submodules_recursive(projRoot, projRoot, subList);
    subList = unique(subList, 'stable');
end

function currentSubs = scan_submodules_recursive(baseDir, projRoot, currentSubs)
    % 1. Check for .gitmodules in baseDir
    gitmodulesPath = fullfile(baseDir, '.gitmodules');
    newlyFound = {};
    if exist(gitmodulesPath, 'file')
        try
            fid = fopen(gitmodulesPath, 'r');
            if fid ~= -1
                while ~feof(fid)
                    lineStr = strtrim(fgetl(fid));
                    if ischar(lineStr) && startsWith(lineStr, 'path', 'IgnoreCase', true)
                        tokens = regexp(lineStr, 'path\s*=\s*(.+)', 'tokens');
                        if ~isempty(tokens) && ~isempty(tokens{1})
                            subRel = strtrim(tokens{1}{1});
                            fullSub = normalize_path(fullfile(baseDir, subRel));
                            if ~ismember(fullSub, currentSubs) && isfolder(fullSub)
                                currentSubs{end+1} = fullSub;
                                newlyFound{end+1} = fullSub;
                            end
                        end
                    end
                end
                fclose(fid);
            end
        catch
        end
    end

    % 2. Scan subdirectories in baseDir for .git marker
    items = dir(baseDir);
    for i = 1:length(items)
        if items(i).isdir && ~startsWith(items(i).name, '.')
            cand = fullfile(baseDir, items(i).name);
            gitMarker = fullfile(cand, '.git');
            if exist(gitMarker, 'file') || exist(gitMarker, 'dir')
                normCand = normalize_path(cand);
                if ~ismember(normCand, currentSubs)
                    currentSubs{end+1} = normCand;
                    newlyFound{end+1} = normCand;
                end
            end
        end
    end

    % 3. Recursively scan discovered submodules for nested submodules
    for k = 1:length(newlyFound)
        currentSubs = scan_submodules_recursive(newlyFound{k}, projRoot, currentSubs);
    end
end

%% =============================================================================
%% HELPER: Dynamically Discover Safe Functional Directories in a Repository
%% =============================================================================
function dirList = discover_repo_directories(baseDir)
    dirList = {};
    if ~isfolder(baseDir)
        return;
    end

    % Always include base directory itself
    dirList{end+1} = normalize_path(baseDir);

    % Get all subdirectories recursively
    rawPaths = genpath(baseDir);
    if isempty(rawPaths)
        return;
    end

    pathEntries = strsplit(rawPaths, pathsep);

    for i = 1:length(pathEntries)
        entry = pathEntries{i};
        if isempty(entry)
            continue;
        end

        normEntry = normalize_path(entry);

        % Apply safety filter
        if is_excluded_path(normEntry)
            continue;
        end

        dirList{end+1} = normEntry;
    end

    dirList = unique(dirList, 'stable');
end

%% =============================================================================
%% HELPER: Filter Forbidden Directories (.git, slprj, caches, +pkg, @class)
%% =============================================================================
function excluded = is_excluded_path(folderPath)
    [~, folderName, ~] = fileparts(folderPath);

    % Check folder name directly
    if startsWith(folderName, '.') ...
       || strcmpi(folderName, '.git') ...
       || strcmpi(folderName, '.github') ...
       || strcmpi(folderName, '.vscode') ...
       || strcmpi(folderName, '.idea') ...
       || strcmpi(folderName, 'slprj') ...
       || strcmpi(folderName, 'resources') ...
       || strcmpi(folderName, 'work') ...
       || strcmpi(folderName, 'temp') ...
       || strcmpi(folderName, 'tmp') ...
       || startsWith(folderName, '@') ... % MATLAB class folders (parent must be on path, not class)
       || startsWith(folderName, '+')     % MATLAB package folders (parent must be on path, not package)
        excluded = true;
        return;
    end

    % Check all path components for .git or slprj or resources
    pathParts = strsplit(folderPath, filesep);
    for k = 1:length(pathParts)
        part = pathParts{k};
        if strcmpi(part, '.git') || strcmpi(part, 'slprj') || strcmpi(part, 'resources')
            excluded = true;
            return;
        end
    end

    excluded = false;
end

%% =============================================================================
%% HELPER: Check If Directory is Already on MATLAB Search Path
%% =============================================================================
function onPath = is_on_matlab_path(dirPath)
    matlabPaths = strsplit(path, pathsep);
    normTarget = normalize_path(dirPath);
    for i = 1:length(matlabPaths)
        if strcmpi(normalize_path(matlabPaths{i}), normTarget)
            onPath = true;
            return;
        end
    end
    onPath = false;
end

%% =============================================================================
%% HELPER: Normalize File Path Representation
%% =============================================================================
function p = normalize_path(rawPath)
    p = strrep(rawPath, '/', filesep);
    p = strrep(p, '\', filesep);
    if endsWith(p, filesep) && length(p) > 1
        p = p(1:end-1);
    end
end
