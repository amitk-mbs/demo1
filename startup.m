% STARTUP.m
% Automatically executed when MATLAB opens in this directory or when cd'ed into it.
% Initializes all project paths, submodules, and tools for the current repository.

% Prevent duplicate execution within the same 3 seconds (e.g. from both -sd and -r)
persistent lastStartupRun
if ~isempty(lastStartupRun) && (toc(lastStartupRun) < 3)
    return;
end
lastStartupRun = tic;

thisDir = fileparts(mfilename('fullpath'));
if exist(fullfile(thisDir, 'setup_project_paths.m'), 'file')
    setupFunc = fullfile(thisDir, 'setup_project_paths.m');
    run(setupFunc);
elseif exist('setup_project_paths', 'file')
    setup_project_paths();
else
    % Look in parent directory (e.g. if started from development/)
    parentDir = fileparts(thisDir);
    if exist(fullfile(parentDir, 'setup_project_paths.m'), 'file')
        run(fullfile(parentDir, 'setup_project_paths.m'));
    else
        warning('ProjectEnv:Startup', 'setup_project_paths.m was not found in directory or parent directory.');
    end
end
