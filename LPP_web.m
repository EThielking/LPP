function [result, subjectID, subjectDir, sectionsToProcess] = LPP_web(action, varargin)
%LPP_WEB One file for preparing the website and importing its recordings.
%
% Download LPP_web.m and index.html into the same folder. In MATLAB run:
%   LPP_web
% Choose Prepare website once, or Import recorded session after collection.
% No other MATLAB helper files or toolboxes are required (MATLAB JVM needed).
%
% PREPARE: Select the existing stimuli folder, annotations folder, and HTML.
% Creates a fresh folder containing ONE index.html plus assets/ (audio only).
% It embeds the selected sections' exact timing, cue and question files.
% It never regenerates cues, chooses new probe spots, or resamples audio.
%
% IMPORT: Unzip the complete Google Drive participant folder or website backup,
% then select session.json at its root. Both old and new Drive names work.
% The output is participantID_yyyymmdd_HHMMSS/ with one section MAT and
% sectionN/probe_001_reports.wav files, as in the lab. Web timestamps are UTC.
% Creates the Info MAT files and unchanged WAVs expected by the supplied
% ai_transcribewav_LPP.m. It does not transcribe or score verbal reports.
%
% To use import at the start of ai_transcribewav_LPP.m, AFTER clear/clc/tic:
%   [~, subjectID, subjectDir, sectionsToProcess] = LPP_web('import');
%   if isempty(subjectDir), return; end  % A file/folder dialog was cancelled.
% Remove the old subjectID and subjectDir assignments; change the section
% loop to: for isection = sectionsToProcess
% Change its final save to: save(logFile, 'Info', '-append');
% For stopped sessions, add this after wavDir is assigned, before its check:
%   if isempty(dir(fullfile(wavDir, '*_reports.wav'))), continue; end
% Keep the Python settings appropriate to your computer.
%
% Optional commands (no dialog boxes when all arguments are supplied):
%   LPP_web('prepare', stimuliDir, annotationDir, htmlFile, outputDir, 1:9)
%   [files,id,folder,sections] = LPP_web('import', jsonFile, audioDir, outputDir)
%   LPP_web('test')   % Synthetic import check; no participant data or Whisper.
%
% Default Mac source folders (you can select different folders in the dialogs):
%   /Users/EMT/Projects/LPP/stimuli_lpp
%   /Users/EMT/Projects/LPP/annotations_lpp

% Change this to 1:9 only after the original audio, timings, cues and questions
% for every section are available. An optional fifth prepare argument overrides it.
SECTIONS_TO_PREPARE = 1:2;

result = []; subjectID = ''; subjectDir = ''; sectionsToProcess = [];
if nargin < 1 || isempty(action)
    choice = menu('LPP web experiment', 'Prepare website', 'Import recorded session', 'Check converter with test data');
    if choice == 0, return; end
    actions = {'prepare', 'import', 'test'};
    action = actions{choice};
end
switch lower(char(action))
    case 'prepare'
        stimuli = argument(varargin, 1);
        annotations = argument(varargin, 2);
        htmlFile = argument(varargin, 3);
        destination = argument(varargin, 4);
        if isempty(stimuli)
            stimuli = chooseFolder('/Users/EMT/Projects/LPP/stimuli_lpp', 'Select stimuli_lpp (story WAVs, bell and recall_segments)');
            if isempty(stimuli), return; end
        end
        if isempty(annotations)
            annotations = chooseFolder(fullfile(fileparts(stimuli), 'annotations_lpp'), 'Select annotations_lpp (section timing MAT files and LPP_questions.mat)');
            if isempty(annotations), return; end
        end
        if isempty(htmlFile)
            [name, folder] = uigetfile('*.html', 'Select the downloaded index.html', fullfile(fileparts(mfilename('fullpath')), 'index.html'));
            if isequal(name, 0), return; end
            htmlFile = fullfile(folder, name);
        end
        if isempty(destination)
            parent = chooseFolder(fileparts(htmlFile), 'Choose where to create your LPP_GitHub folder');
            if isempty(parent), return; end
            destination = fullfile(parent, ['LPP_GitHub_' datestr(now, 'yyyymmdd_HHMMSS')]);
        end
        sections = SECTIONS_TO_PREPARE;
        if numel(varargin) >= 5 && ~isempty(varargin{5}), sections = varargin{5}; end
        result = prepareWebsite(stimuli, annotations, htmlFile, destination, sections);
    case 'import'
        jsonFile = argument(varargin, 1);
        recordings = argument(varargin, 2);
        destination = argument(varargin, 3);
        if isempty(jsonFile)
            [name, folder] = uigetfile('*.json', 'Select session.json inside the unzipped participant folder');
            if isequal(name, 0), return; end
            jsonFile = fullfile(folder, name);
        end
        if isempty(recordings), recordings = fileparts(jsonFile); end
        if isempty(destination)
            destination = chooseFolder('/Users/EMT/Projects/LPP/data_lpp', 'Select where to save the converted participant folders');
            if isempty(destination), return; end
        end
        [result, subjectID, subjectDir, sectionsToProcess] = importSession(jsonFile, recordings, destination);
        fprintf('\nIn ai_transcribewav_LPP.m, use the subjectID/subjectDir printed above.\n');
        fprintf('Process sectionsToProcess; save updated Info with -append to preserve web metadata.\n');
    case 'test'
        testImporter();
    otherwise
        error('Use LPP_web, LPP_web(''prepare''), LPP_web(''import''), or LPP_web(''test'').');
end
end

function value = argument(args, index)
value = '';
if numel(args) >= index && ~isempty(args{index}), value = char(args{index}); end
end
function folder = chooseFolder(initial, prompt)
if ~isfolder(initial), initial = pwd; end
folder = uigetdir(initial, prompt);
if isequal(folder, 0), folder = ''; end
end

function manifest = prepareWebsite(stimuliDir, annotationDir, htmlFile, outputDir, sections)
% Validate all original inputs before copying audio or creating a website.
assert(isnumeric(sections) && isvector(sections) && ~isempty(sections), 'Provide section numbers, for example 1:2 or 1:9.');
sections = double(sections(:)');
assert(all(isfinite(sections) & sections == fix(sections) & sections >= 1 & sections <= 9) && all(diff(sections) > 0), ...
    'Sections must be unique ascending integers from 1 through 9.');
requireFile(htmlFile);
html = fileread(htmlFile);
embedStudy(html, struct()); % Check this is the supported one-file HTML template.
assert(~isfile(outputDir), 'Output is a file, not a folder: %s', outputDir);
if isfolder(outputDir)
    contents = dir(outputDir);
    contents = contents(~ismember({contents.name}, {'.', '..'}));
    assert(isempty(contents), 'Choose a NEW or EMPTY output folder to preserve the earlier website: %s', outputDir);
end
probeOffset_sec = 0.200;
questionFile = fullfile(annotationDir, 'LPP_questions.mat');
requireFile(questionFile);
loaded = load(questionFile, 'Q');
assert(isfield(loaded, 'Q') && isstruct(loaded.Q) && numel(loaded.Q) >= max(sections), ...
    'LPP_questions.mat must contain Q entries for all selected sections.');
Q = loaded.Q;

% To use a different interruption sound, change this filename to an existing
% audio file in stimuli_lpp. Its exact bytes and checksum enter the website.
interruptionSoundFile = 'bell-ringing-05.mp3';
bellSource = fullfile(stimuliDir, interruptionSoundFile);
requireFile(bellSource);
checkAudio(bellSource);

% Validate every required input before creating or copying output files.
manifest = struct();
manifest.schemaVersion = 1;
manifest.studyId = ['lpp-sections-' strjoin(cellstr(string(sections)), '-')];
manifest.title = 'LPP audiobook study';
manifest.probeOffset_sec = probeOffset_sec;
manifest.beepToCueDelay = 0.100;
manifest.spaceSoundHz = 1000;
manifest.spaceBeepDuration = 0.080;
manifest.postReportDelay_sec = 1;
manifest.bellFile = ['assets/' interruptionSoundFile];
manifest.sections = cell(1, numel(sections));
manifest.assets = {};
sourceFiles = {bellSource};
relativeFiles = {manifest.bellFile};

for sectionIndex = 1:numel(sections)
    section = sections(sectionIndex);
    timingFile = fullfile(annotationDir, sprintf('segment_times_section%d.mat', section));
    requireFile(timingFile);
    T = load(timingFile, 'probe_sec', 'recallSegments', 'cues');
    required = {'probe_sec', 'recallSegments', 'cues'};
    assert(all(isfield(T, required)), ...
        'Section %d timing file must contain probe_sec, recallSegments, and cues.', section);
    assert(isnumeric(T.probe_sec) && isreal(T.probe_sec) && isvector(T.probe_sec), ...
        'Section %d: probe_sec must be a real numeric vector.', section);
    original = double(T.probe_sec(:));
    assert(~isempty(original) && all(isfinite(original)) && all(original >= 0), ...
        'Section %d: probe times must be nonempty, finite, and nonnegative.', section);
    assert(all(diff(original) > 0), 'Section %d: original probe times must increase.', section);
    effective = original + probeOffset_sec;
    effective(end) = original(end); % EXACT final-probe rule in supplied script.
    assert(all(diff(effective) > 0), 'Section %d: effective probe times must increase.', section);
    recallSegments = string(T.recallSegments(:));
    cues = string(T.cues(:));
    nProbes = numel(original);
    assert(numel(recallSegments) == nProbes && numel(cues) == nProbes, ...
        'Section %d: probe, recallSegment, and cue counts differ.', section);
    assert(all(~ismissing(recallSegments) & strlength(strtrim(recallSegments)) > 0) && ...
           all(~ismissing(cues) & strlength(strtrim(cues)) > 0), ...
        'Section %d: recall segments and cues must be nonempty.', section);

    audioName = sprintf('task-lppEN_section-%d.wav', section);
    audioSource = fullfile(stimuliDir, audioName);
    requireFile(audioSource);
    A = checkAudio(audioSource);
    duration_sec = A.TotalSamples / A.SampleRate;
    assert(all(effective <= duration_sec), ...
        'Section %d: an effective probe is after the end of the original audiobook.', section);
    S = struct('section', section, 'audiobookFile', ['assets/' audioName], ...
        'duration_sec', duration_sec, 'sampleRate', A.SampleRate, ...
        'sourceProbeTimes', {num2cell(original(:)')}, ...
        'probeTimes', {num2cell(effective(:)')}, ...
        'effectiveProbeTimes', {num2cell(effective(:)')}, ...
        'cueAudioFiles', {cell(1, nProbes)}, ...
        'probes', {cell(1, nProbes)}, 'questions', {{}});
    sourceFiles{end+1} = audioSource; %#ok<AGROW>
    relativeFiles{end+1} = S.audiobookFile; %#ok<AGROW>

    for p = 1:nProbes
        cueName = sprintf('section%d_probe_%03d_cue.wav', section, p);
        cueSource = fullfile(stimuliDir, 'recall_segments', ...
            sprintf('section%d', section), cueName);
        requireFile(cueSource);
        C = checkAudio(cueSource);
        cueUrl = ['assets/' cueName];
        S.cueAudioFiles{p} = cueUrl;
        S.probes{p} = struct('probeNumber', p, 'probe_sec', original(p), ...
            'effectiveProbeTime_sec', effective(p), ...
            'recallSegment', char(recallSegments(p)), 'cue', char(cues(p)), ...
            'cueAudioFile', cueUrl, 'cueDuration_sec', C.TotalSamples/C.SampleRate, ...
            'cueSampleRate', C.SampleRate);
        sourceFiles{end+1} = cueSource; %#ok<AGROW>
        relativeFiles{end+1} = cueUrl; %#ok<AGROW>
    end

    assert(all(isfield(Q(section), {'text', 'options', 'answer'})), ...
        'Q(%d) must contain text, options, and answer.', section);
    questionTexts = string(Q(section).text(:));
    nQuestions = numel(questionTexts);
    assert(nQuestions >= 1 && iscell(Q(section).options) && ...
        numel(Q(section).options) == nQuestions && ...
        isnumeric(Q(section).answer) && numel(Q(section).answer) == nQuestions, ...
        'Section %d: question, options, and answer counts differ or are empty.', section);
    correctAnswers = double(Q(section).answer(:));
    assert(all(isfinite(correctAnswers) & correctAnswers == fix(correctAnswers) & ...
        correctAnswers >= 1 & correctAnswers <= 4), ...
        'Section %d: correct answers must be integers 1-4.', section);
    S.questions = cell(1, nQuestions);
    for q = 1:nQuestions
        options = string(Q(section).options{q}(:));
        assert(numel(options) == 4 && all(~ismissing(options) & strlength(strtrim(options)) > 0), ...
            'Section %d question %d must have four nonempty options.', section, q);
        assert(~ismissing(questionTexts(q)) && strlength(strtrim(questionTexts(q))) > 0, ...
            'Section %d question %d is empty.', section, q);
        S.questions{q} = struct('questionNumber', q, 'question', char(questionTexts(q)), ...
            'options', {cellstr(options(:)')}, 'correctAnswer', correctAnswers(q));
    end
    manifest.sections{sectionIndex} = S;
end

assert(numel(unique(relativeFiles)) == numel(relativeFiles), 'Asset filenames must be unique.');
for a = 1:numel(sourceFiles)
    entry = dir(sourceFiles{a});
    manifest.assets{a} = struct('path', relativeFiles{a}, 'bytes', entry.bytes, ...
        'sha256', sha256File(sourceFiles{a}));
end
assetBytes = cellfun(@(asset) asset.bytes, manifest.assets);
browserTooLarge = find(assetBytes > 25*1024^2 & assetBytes <= 100*1024^2);
repositoryTooLarge = find(assetBytes > 100*1024^2);
if ~isempty(browserTooLarge)
    fprintf('\nThese files exceed GitHub''s 25 MiB browser-upload limit. Use Git or GitHub Desktop to upload them:\n');
    for a = browserTooLarge(:)'
        fprintf('  %s (%.1f MiB)\n', relativeFiles{a}, assetBytes(a)/1024^2);
    end
end
if ~isempty(repositoryTooLarge)
    fprintf('\nThese files exceed GitHub''s 100 MiB ordinary-repository limit and will be rejected:\n');
    for a = repositoryTooLarge(:)'
        fprintf('  %s (%.1f MiB)\n', relativeFiles{a}, assetBytes(a)/1024^2);
    end
    fprintf('Use a different asset host for these original files and set their URLs in the embedded study data.\n');
    fprintf('Git LFS cannot serve GitHub Pages assets. This preparation keeps the original audio unchanged.\n');
end
manifest.sourceAnnotations = cell(1, numel(sections) + 1);
for k = 1:numel(sections)
    name = sprintf('segment_times_section%d.mat', sections(k));
    manifest.sourceAnnotations{k} = struct('file', name, 'sha256', sha256File(fullfile(annotationDir, name)));
end
manifest.sourceAnnotations{end} = struct('file', 'LPP_questions.mat', 'sha256', sha256File(questionFile));
manifest.exportedAt = char(datetime('now', 'TimeZone', 'UTC', 'Format', 'yyyy-MM-dd''T''HH:mm:ss.SSS''Z'''));

html = embedStudy(html, manifest);

if ~isfolder(fullfile(outputDir, 'assets')), mkdir(fullfile(outputDir, 'assets')); end
for a = 1:numel(sourceFiles)
    destination = fullfile(outputDir, strrep(relativeFiles{a}, '/', filesep));
    [ok, message] = copyfile(sourceFiles{a}, destination, 'f');
    assert(ok, 'Could not copy %s: %s', sourceFiles{a}, message);
    assert(strcmp(sha256File(destination), manifest.assets{a}.sha256), ...
        'Copied asset failed byte verification: %s', destination);
end
writeUTF8(fullfile(outputDir, 'index.html'), html);
fprintf('\nWebsite prepared in:\n%s\n', outputDir);
if isempty(repositoryTooLarge)
    fprintf('Upload index.html and the assets folder to your GitHub repository.\n');
else
    fprintf('Use the asset-hosting guidance above before publishing index.html on GitHub.\n');
end
for k = 1:numel(sections)
    fprintf('Section %d: %d fixed probes, %d comprehension questions.\n', sections(k), ...
        numel(manifest.sections{k}.probes), numel(manifest.sections{k}.questions));
end
fprintf('All copied audio bytes are unchanged.\n');
fprintf('Set DATA_ENDPOINT near the top of index.html to your new Apps Script URL.\n');
fprintf('No MATLAB files or participant recordings belong in the public GitHub repository.\n');
end

function html = embedStudy(html, manifest)
pattern = 'const EMBEDDED_STUDY = [\s\S]*?; /\* LPP_STUDY_END \*/';
[first, last] = regexp(html, pattern, 'start', 'end');
assert(numel(first) == 1, 'Select the supplied one-file index.html containing the EMBEDDED_STUDY marker.');
encoded = jsonencode(manifest);
% Keep JSON inside its script element even if a question contains </script>.
% Slash escaping also prevents source text from imitating the end marker.
encoded = strrep(encoded, '/', '\/');
encoded = strrep(encoded, '<', '\u003c');
encoded = strrep(encoded, '>', '\u003e');
encoded = strrep(encoded, '&', '\u0026');
encoded = strrep(encoded, char(8232), '\u2028');
encoded = strrep(encoded, char(8233), '\u2029');
replacement = ['const EMBEDDED_STUDY = ' encoded '; /* LPP_STUDY_END */'];
html = [html(1:first-1) replacement html(last+1:end)];
end
function writeUTF8(file, text)
fid = fopen(file, 'w', 'n', 'UTF-8');
assert(fid ~= -1, 'Cannot write %s', file);
cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>
assert(fprintf(fid, '%s\n', text) > 0, 'Could not write %s', file);
end
function requireFile(file)
assert(isfile(file), 'Required file is missing: %s', file);
end
function info = checkAudio(file)
info = audioinfo(file);
assert(isfinite(info.SampleRate) && info.SampleRate > 0 && ...
    info.TotalSamples > 0 && info.NumChannels >= 1, 'Invalid audio file: %s', file);
end

function [files, subjectID, subjectDir, sectionsToProcess] = importSession(jsonFile, recordingsDir, outputDir)
% Import only verified audio. A missing Google upload never becomes an empty WAV.
requireFile(jsonFile);
if nargin < 2 || isempty(recordingsDir), recordingsDir = fileparts(jsonFile); end
if isempty(recordingsDir), recordingsDir = pwd; end
if nargin < 3 || isempty(outputDir), outputDir = fullfile(fileparts(jsonFile), 'matlab'); end
jsonFile = absolutePath(jsonFile);
recordingsDir = absolutePath(recordingsDir);
assert(usejava('jvm'), 'MATLAB JVM is needed for file verification.');
outputPath = java.io.File(char(outputDir));
outputDir = char(outputPath.getCanonicalPath());
WebSession = jsondecode(fileread(jsonFile));
assert(isstruct(WebSession) && isscalar(WebSession) && isfield(WebSession, 'schemaVersion') && ...
    WebSession.schemaVersion == 1 && isfield(WebSession, 'sections'), ...
    'Select session.json from the unzipped participant download.');
assert(all(isfield(WebSession, {'session_id','participant_id','mode','startISO'})), ...
    'Session ID, participant ID, mode, or start timestamp is missing.');
assert(ismember(string(WebSession.mode), ["study", "local-test"]), ...
    'Only study or local-test sessions can be imported.');
if strcmp(WebSession.mode, 'local-test')
    warning('LPP:LocalRehearsal', 'LOCAL REHEARSAL: WebSession.mode identifies this session; exclude it from participant analyses.');
end
sections = WebSession.sections;
assert(~isempty(sections), 'This session contains no begun study sections.');
subjectID = participantPrefix(WebSession); % Folder/logfile code; Info.subjectID remains the participant ID.
subjectDir = fullfile(outputDir, subjectID);
sourceHash = sha256File(jsonFile);
files = cell(1, numel(sections));
sectionsToProcess = zeros(1, numel(sections));
validated = cell(1, numel(sections));
reuse = false(1, numel(sections));
copyPlan = struct('source', {}, 'destination', {}, 'sha256', {}, 'section', {}, 'probeNumber', {});
sectionAudit = struct('section', {}, 'status', {}, 'plannedProbes', {}, 'capturedProbes', {}, 'completeReports', {});

% Build Info with exactly the initial field names and shapes in the lab files.
% Full browser metadata, corrections, quality checks and sample indices remain
% in WebSession; WebImport records this conversion and the verified audio.
for s = 1:numel(sections)
    if iscell(sections), web = sections{s}; else, web = sections(s); end
    required = {'subjectID','section','startTime','endTime','audiobookFile', ...
        'probeTimes','effectiveProbeTimes','cueAudioFiles','trials','comprehension'};
    assert(all(isfield(web, required)), 'Section %d is missing expected fields.', s);
    assert(isnumeric(web.section) && isscalar(web.section) && ismember(web.section, 1:9), 'Invalid section ID (expected 1-9).');
    assert(~ismember(web.section, sectionsToProcess(1:s-1)), 'Duplicate section ID.');
    assert(strcmp(char(web.subjectID), char(WebSession.participant_id)), 'Section participant ID disagrees with the session.');
    sectionsToProcess(s) = web.section;
    files{s} = fullfile(subjectDir, sprintf('%s_audiobook_logfile_section%d.mat', subjectID, web.section));
    times = double(web.probeTimes(:));
    effective = double(web.effectiveProbeTimes(:));
    cueFiles = cellstr(string(web.cueAudioFiles(:)));
    assert(~isempty(times) && numel(times) == numel(effective) && numel(cueFiles) == numel(times) && ...
        all(isfinite(times)) && all(isfinite(effective)) && all(diff(times) > 0) && all(diff(effective) > 0), ...
        'Section %d has invalid probe/cue metadata.', web.section);
    Info = struct('subjectID', char(WebSession.participant_id), 'section', double(web.section), ...
        'startTime', labDate(web.startTime), 'endTime', labDate(web.endTime), ...
        'audiobookFile', localStimulus(web.audiobookFile, web.section, false), ...
        'probeTimes', times, 'effectiveProbeTimes', effective, 'cueAudioFiles', {cueFiles}, ...
        'trials', emptyTrials(), 'comprehension', emptyQuestions());
    for p = 1:numel(cueFiles)
        Info.cueAudioFiles{p} = localStimulus(cueFiles{p}, web.section, true);
    end
    trials = web.trials;
    if iscell(trials), trials = unionStructs(trials); end
    seenProbes = [];
    nCaptured = 0; nComplete = 0;
    for t = 1:numel(trials)
        sourceTrial = trials(t);
        required = {'probeNumber','recallSegment','cue','reportAudioFile','spaceTimes_sec','probeTriggerTime_sec'};
        assert(all(isfield(sourceTrial, required)), 'Section %d trial %d is missing fields.', web.section, t);
        pn = double(sourceTrial.probeNumber);
        assert(isscalar(pn) && isfinite(pn) && pn >= 1 && pn <= numel(times) && pn == fix(pn) && ~ismember(pn, seenProbes), ...
            'Invalid or duplicated probe number in section %d.', web.section);
        seenProbes(end+1) = pn; %#ok<AGROW>
        assert(isscalar(sourceTrial.probeTriggerTime_sec) && isfinite(sourceTrial.probeTriggerTime_sec) && sourceTrial.probeTriggerTime_sec >= 0, ...
            'Invalid trigger time in section %d probe %d.', web.section, pn);
        labTrial = struct('probeNumber', pn, 'recallSegment', string(sourceTrial.recallSegment), ...
            'cue', string(sourceTrial.cue), 'reportAudioFile', '', ...
            'spaceTimes_sec', nan(1,3), 'probeTriggerTime_sec', double(sourceTrial.probeTriggerTime_sec));
        assert(isscalar(labTrial.recallSegment) && isscalar(labTrial.cue), 'Recall text and cue must be scalar text.');
        noCapture = isfield(sourceTrial, 'status') && strcmp(sourceTrial.status, 'interrupted_before_recording');
        if noCapture
            assert(isempty(sourceTrial.spaceTimes_sec) && isempty(sourceTrial.reportAudioFile), ...
                'A probe interrupted before recording cannot have audio or SPACE markers.');
            Info.trials(end+1) = labTrial; %#ok<AGROW>
            continue;
        end
        relative = validRelative(sourceTrial.reportAudioFile);
        source = findReport(recordingsDir, relative, web.section, sourceTrial, subjectID);
        A = audioinfo(source);
        assert(A.NumChannels == 1 && A.TotalSamples > 0 && A.BitsPerSample == 16, ...
            'Expected a nonempty mono PCM16 report WAV: %s', source);
        if isfield(sourceTrial, 'audioSampleRate') && ~isempty(sourceTrial.audioSampleRate)
            assert(A.SampleRate == sourceTrial.audioSampleRate, 'WAV rate disagrees with JSON: %s', source);
        end
        if isfield(sourceTrial, 'audioDuration_sec') && ~isempty(sourceTrial.audioDuration_sec)
            assert(abs(A.TotalSamples / A.SampleRate - sourceTrial.audioDuration_sec) <= 1 / A.SampleRate, ...
                'WAV duration disagrees with JSON: %s', source);
        end
        marks = numericMarkers(sourceTrial.spaceTimes_sec);
        finite = marks(isfinite(marks));
        assert(numel(marks) <= 3 && all(isfinite(marks) | isnan(marks)) && ...
            all(diff(finite) > 0) && all(finite >= 0) && all(finite <= A.TotalSamples / A.SampleRate) && ...
            ~any(diff(isfinite(marks)) > 0), ...
            'Invalid SPACE times in section %d probe %d.', web.section, pn);
        if isfield(sourceTrial, 'spaceSampleIndices') && ~isempty(sourceTrial.spaceSampleIndices)
            indices = double(sourceTrial.spaceSampleIndices(:)');
            assert(numel(indices) == numel(finite) && all(isfinite(indices)) && ...
                all(indices == fix(indices)) && all(abs(indices / A.SampleRate - finite) <= 1 / A.SampleRate), ...
                'SPACE sample indices disagree with timestamps: section %d probe %d.', web.section, pn);
        end
        complete = isfield(sourceTrial, 'status') && strcmp(sourceTrial.status, 'complete');
        if complete
            assert(numel(finite) == 3, 'A complete probe must contain all three SPACE markers: section %d probe %d.', web.section, pn);
        end
        marks(end+1:3) = NaN;
        labTrial.spaceTimes_sec = marks;
        destination = fullfile(subjectDir, sprintf('section%d', web.section), sprintf('probe_%03d_reports.wav', pn));
        hash = sha256File(source);
        if isfield(sourceTrial, 'sha256') && ~isempty(sourceTrial.sha256)
            assert(strcmpi(hash, char(sourceTrial.sha256)), 'Downloaded audio failed its saved checksum: %s', source);
        end
        if isfile(destination)
            assert(strcmp(sha256File(destination), hash), 'Existing WAV differs; choose a fresh output folder: %s', destination);
        end
        copyPlan(end+1) = struct('source', source, 'destination', destination, ...
            'sha256', hash, 'section', web.section, 'probeNumber', pn); %#ok<AGROW>
        labTrial.reportAudioFile = destination;
        Info.trials(end+1) = labTrial; %#ok<AGROW>
        nCaptured = nCaptured + 1; nComplete = nComplete + double(complete);
    end
    if ~isempty(Info.trials), [~, order] = sort([Info.trials.probeNumber]); Info.trials = Info.trials(order); end
    questions = web.comprehension;
    if iscell(questions), questions = unionStructs(questions); end
    seenQuestions = [];
    for q = 1:numel(questions)
        item = questions(q);
        assert(all(isfield(item, fieldnames(emptyQuestionTemplate()))), 'A comprehension answer is missing fields.');
        assert(isscalar(item.questionNumber) && isfinite(item.questionNumber) && item.questionNumber >= 1 && ...
            item.questionNumber == fix(item.questionNumber) && ~ismember(item.questionNumber, seenQuestions), 'Invalid question number.');
        seenQuestions(end+1) = item.questionNumber; %#ok<AGROW>
        options = cellstr(string(item.options(:)'));
        assert(numel(options) == 4 && ismember(item.correctAnswer, 1:4) && ismember(item.response, 1:4), 'Invalid comprehension options or response.');
        assert(isscalar(item.correct) && ismember(item.correct, [0 1]) && logical(item.correct) == (item.response == item.correctAnswer), 'Question correctness disagrees with the response.');
        confidence = scalarOrNaN(item.confidence); confidenceRT = scalarOrNaN(item.confidenceRT);
        assert(isnan(confidence) || ismember(confidence, 1:4), 'Confidence must be 1-4 or missing.');
        Info.comprehension(end+1) = struct('questionNumber', double(item.questionNumber), ...
            'question', char(item.question), 'options', {options}, 'correctAnswer', double(item.correctAnswer), ...
            'response', double(item.response), 'correct', logical(item.correct), 'RT', double(item.RT), ...
            'confidence', confidence, 'confidenceRT', confidenceRT); %#ok<AGROW>
    end
    sectionStatus = 'unknown';
    if isfield(web, 'status'), sectionStatus = char(web.status); end
    if strcmp(sectionStatus, 'complete')
        assert(isequal(sort(seenProbes), 1:numel(times)) && nComplete == numel(times), ...
            'Section %d is labelled complete but its trial records are incomplete.', web.section);
        if isfield(web, 'expectedQuestionCount')
            assert(numel(Info.comprehension) == web.expectedQuestionCount && ...
                isequal(sort(seenQuestions), 1:web.expectedQuestionCount) && ...
                all(isfinite([Info.comprehension.confidence])), ...
                'Section %d is labelled complete but comprehension answers are incomplete.', web.section);
        end
    else
        warning('LPP:PartialSection', 'Section %d status is %s. Partial data are retained; review WebSession before analysis.', web.section, sectionStatus);
    end
    sectionAudit(end+1) = struct('section', web.section, 'status', sectionStatus, ...
        'plannedProbes', numel(times), 'capturedProbes', nCaptured, 'completeReports', nComplete); %#ok<AGROW>
    validated{s} = Info;
    if isfile(files{s})
        existing = load(files{s}, 'Info', 'WebImport');
        assert(isfield(existing, 'Info') && isfield(existing, 'WebImport') && ...
            all(isfield(existing.WebImport, {'sourceJsonSHA256','subjectDir','audioFiles'})) && ...
            strcmp(existing.WebImport.sourceJsonSHA256, sourceHash) && strcmp(existing.WebImport.subjectDir, subjectDir), ...
            'Existing logfile is a different/older import. Choose a fresh output folder to preserve it: %s', files{s});
        oldAudio = existing.WebImport.audioFiles;
        assert(isstruct(oldAudio) && (isempty(oldAudio) || all(isfield(oldAudio, {'section','probeNumber','sha256'}))), ...
            'Existing import lacks a valid audio verification ledger.');
        currentAudio = copyPlan([copyPlan.section] == web.section);
        oldSection = oldAudio;
        if ~isempty(oldAudio), oldSection = oldAudio([oldAudio.section] == web.section); end
        assert(numel(oldSection) == numel(currentAudio), 'Existing import has a different audio inventory.');
        for k = 1:numel(currentAudio)
            hit = find([oldSection.probeNumber] == currentAudio(k).probeNumber);
            assert(numel(hit) == 1 && strcmp(oldSection(hit).sha256, currentAudio(k).sha256), ...
                'Source WAV differs from prior import; existing analysis is preserved. Section %d probe %d.', web.section, currentAudio(k).probeNumber);
        end
        reuse(s) = true; % Keep transcripts and later analysis already added to Info.
    end
end

if ~isfolder(subjectDir), mkdir(subjectDir); end
for s = 1:numel(sectionsToProcess)
    d = fullfile(subjectDir, sprintf('section%d', sectionsToProcess(s)));
    if ~isfolder(d), mkdir(d); end
end
for k = 1:numel(copyPlan)
    p = copyPlan(k);
    if ~isfile(p.destination)
        [ok, msg] = copyfile(p.source, p.destination);
        assert(ok, 'Could not copy report: %s', msg);
    end
    assert(strcmp(sha256File(p.destination), p.sha256), 'Copied WAV failed verification: %s', p.destination);
end
WebImport = struct('version', 3, 'sourceJsonFile', jsonFile, 'sourceJsonSHA256', sourceHash, ...
    'subjectDir', subjectDir, 'importedAt', datestr(now, 30), 'audioFiles', copyPlan, ...
    'sections', sectionAudit, 'timeZone', 'UTC for web timestamps; original timestamps retained in WebSession', ...
    'timingNote', 'Browser SPACE markers refer to exact WAV samples; hardware latency is not calibrated.');
for s = 1:numel(validated)
    if reuse(s)
        fprintf('Reused existing import (later transcripts preserved): %s\n', files{s});
    else
        Info = validated{s}; %#ok<NASGU>
        save(files{s}, 'Info', 'WebSession', 'WebImport', '-v7.3');
        fprintf('Saved %s\n', files{s});
    end
end
fprintf('\nVerified and copied %d WAV files across %d sections.\n', numel(copyPlan), numel(sections));
fprintf('Ready for transcription:\nsubjectID = ''%s'';\nsubjectDir = ''%s'';\nsectionsToProcess = %s;\n', ...
    subjectID, strrep(subjectDir, '''', ''''''), mat2str(sectionsToProcess));
end

function source = findReport(root, relative, section, trial, prefix)
% Exact filenames only; never guess from the probe number across sections.
names = {relative, sprintf('section%d/probe_%03d_reports.wav', section, trial.probeNumber)};
if isfield(trial, 'driveAudioFile') && ~isempty(trial.driveAudioFile)
    names{end+1} = validRelative(trial.driveAudioFile);
end
prefixed = sprintf('%s_section%d_probe_%03d_reports.wav', prefix, section, trial.probeNumber);
names{end+1} = sprintf('section%d/%s', section, prefixed);
names{end+1} = prefixed;
if isfield(trial, 'recording_id') && ~isempty(trial.recording_id)
    id = char(trial.recording_id);
    assert(~isempty(regexp(id, '^[A-Za-z0-9_.-]{1,128}$', 'once')), 'Invalid recording ID.');
    names{end+1} = sprintf('section%d_probe_%03d_%s_reports.wav', section, trial.probeNumber, id);
end
candidates = {};
for k = 1:numel(names)
    candidate = fullfile(root, strrep(names{k}, '/', filesep));
    if isfile(candidate), candidates{end+1} = absolutePath(candidate); end %#ok<AGROW>
end
candidates = unique(candidates, 'stable');
assert(~isempty(candidates), ...
    'Missing WAV for section %d probe %d. Download the complete participant folder, or use the complete website backup. No files were created.', ...
    section, trial.probeNumber);
if numel(candidates) > 1
    hashes = cellfun(@sha256File, candidates, 'UniformOutput', false);
    assert(numel(unique(hashes)) == 1, 'Conflicting WAV copies for section %d probe %d. Select one complete download.', section, trial.probeNumber);
end
source = candidates{1};
end
function path = validRelative(value)
path = strrep(char(value), '\', '/');
assert(~isempty(path) && path(1) ~= '/' && isempty(regexp(path, '(^|/)\.\.(/|$)|^[A-Za-z]:', 'once')), ...
    'Report references must be relative paths within the download.');
end
function prefix = participantPrefix(web)
pid = safeID(web.participant_id);
prefix = '';
if isfield(web, 'file_prefix') && ~isempty(web.file_prefix), prefix = char(web.file_prefix); end
if ~isempty(prefix)
    assert(~isempty(regexp(prefix, ['^' regexptranslate('escape', pid) '_[0-9]{8}_[0-9]{6}$'], 'once')), ...
        'file_prefix must be participantID_yyyymmdd_HHMMSS.');
else
    parts = regexp(char(web.startISO), '^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})', 'tokens', 'once');
    assert(numel(parts) == 6, 'Missing/invalid session startISO; cannot derive a reliable participant timestamp.');
    prefix = [pid '_' parts{1} parts{2} parts{3} '_' parts{4} parts{5} parts{6}];
end
end
function text = labDate(value)
text = char(value);
if isempty(text), return; end
parts = regexp(text, '^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})', 'tokens', 'once');
if numel(parts) == 6
    numbers = cellfun(@str2double, parts);
    text = datestr(datenum(numbers), 'dd-mmm-yyyy HH:MM:SS'); %#ok<DATNM,DATST>
end
end
function path = localStimulus(value, section, cue)
% Use an existing local stimulus if available; otherwise keep its web reference.
path = char(value);
[~, name, extension] = fileparts(path);
root = '/Users/EMT/Projects/LPP/stimuli_lpp';
if cue, candidate = fullfile(root, 'recall_segments', sprintf('section%d', section), [name extension]);
else, candidate = fullfile(root, [name extension]); end
if isfile(candidate), path = candidate; end
end
function trial = emptyTrials()
trial = struct('probeNumber', {}, 'recallSegment', {}, 'cue', {}, ...
    'reportAudioFile', {}, 'spaceTimes_sec', {}, 'probeTriggerTime_sec', {});
end
function question = emptyQuestionTemplate()
question = struct('questionNumber', [], 'question', '', 'options', {{}}, ...
    'correctAnswer', [], 'response', [], 'correct', false, 'RT', [], 'confidence', [], 'confidenceRT', []);
end
function questions = emptyQuestions()
questions = repmat(emptyQuestionTemplate(), 1, 0);
end
function value = scalarOrNaN(value)
if isempty(value), value = NaN; else, value = double(value); end
assert(isscalar(value), 'Expected a scalar value.');
end

function value = numericMarkers(value)
if iscell(value)
    converted = nan(1, numel(value));
    for k = 1:numel(value)
        if ~isempty(value{k}), converted(k) = double(value{k}); end
    end
    value = converted;
end
value = double(value(:)');
end
function id = safeID(value)
id = regexprep(char(value), '[^A-Za-z0-9_-]', '_');
assert(~isempty(id), 'Participant/session ID must not be empty.');
end
function path = absolutePath(path)
[ok, a] = fileattrib(char(path));
assert(ok, 'File or folder not found: %s', path);
path = a.Name;
end
function hex = sha256File(file)
assert(usejava('jvm'), 'MATLAB JVM is needed for unchanged-WAV verification.');
digest = java.security.MessageDigest.getInstance('SHA-256');
fid = fopen(file, 'rb');
assert(fid ~= -1, 'Cannot read %s', file);
cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>
while true
    bytes = fread(fid, 1024*1024, '*uint8');
    if isempty(bytes), break; end
    digest.update(typecast(bytes(:), 'int8'));
end
hex = lower(reshape(dec2hex(typecast(digest.digest(), 'uint8'), 2).', 1, []));
end
function output = unionStructs(input)
fields = {};
for i = 1:numel(input)
    assert(isstruct(input{i}) && isscalar(input{i}), 'Expected struct entries.');
    fields = union(fields, fieldnames(input{i}), 'stable');
end
fields = fields(:);
template = cell2struct(cell(numel(fields), 1), fields, 1);
output = repmat(template, 1, numel(input));
for i = 1:numel(input)
    keys = fieldnames(input{i});
    for k = 1:numel(keys), output(i).(keys{k}) = input{i}.(keys{k}); end
end
end


function testImporter
% Synthetic, local-only import check. No Whisper needed.
% Creates only a temporary folder and removes it when the test ends.
% Run in MATLAB: LPP_web('test')
testRoot = tempname;
mkdir(testRoot);
cleanup = onCleanup(@() rmdir(testRoot, 's')); %#ok<NASGU>
backup = fullfile(testRoot, 'backup');
mkdir(backup); mkdir(fullfile(backup, 'section1'));
fs = 44100;
y = zeros(fs, 1);
markerTimes = [0.10 0.30 0.60];
for t = markerTimes
    k = round(t*fs)+1;
    y(k:k+99) = 0.25*sin(2*pi*1000*(0:99)'/fs);
end
wav = fullfile(backup, 'section1', 'probe_001_reports.wav');
audiowrite(wav, y, fs, 'BitsPerSample', 16);
trial = struct('probeNumber', 1, 'recallSegment', 'a synthetic test phrase', ...
    'cue', 'a synthetic', 'reportAudioFile', 'section1/probe_001_reports.wav', ...
    'spaceTimes_sec', markerTimes, 'probeTriggerTime_sec', 12.2, ...
    'recording_id', 'section1_probe001', 'audioSampleRate', fs, 'status', 'complete');
noCapture = trial;
noCapture.probeNumber = 2;
noCapture.reportAudioFile = '';
noCapture.recording_id = '';
noCapture.spaceTimes_sec = [];
noCapture.status = 'interrupted_before_recording';
partial = trial;
partial.probeNumber = 3;
partial.reportAudioFile = 'section1/probe_003_reports.wav';
partial.recording_id = 'section1_probe003';
partial.spaceTimes_sec = markerTimes(1:2);
partial.status = 'partial';
copyfile(wav, fullfile(backup, 'section1', 'probe_003_reports.wav'));
Info = struct('subjectID', 'TEST', 'section', 1, 'startTime', 'test_start', ...
    'endTime', 'test_end', 'audiobookFile', 'assets/task-lppEN_section-1.wav', ...
    'probeTimes', [12.2 24.2 36], 'effectiveProbeTimes', [12.2 24.2 36], ...
    'cueAudioFiles', {{'cue1.wav','cue2.wav','cue3.wav'}}, ...
    'trials', [trial noCapture partial], 'comprehension', [], 'status', 'aborted');
web = struct('schemaVersion', 1, 'session_id', 'SESSION_0001', ...
    'participant_id', 'TEST', 'startISO', '2026-11-06T12:00:00.000Z', ...
    'mode', 'study', 'sections', {{Info}});
jsonFile = fullfile(backup, 'session.json');
writeJSON(jsonFile, web);

% Canonical website backup: imported folders match the old transcription code.
[files, subjectID, subjectDir, sections] = importSession(jsonFile, backup, fullfile(testRoot, 'canonical'));
assert(strcmp(subjectID, 'TEST_20261106_120000') && isequal(sections, 1));
assert(strcmp(files{1}, fullfile(subjectDir, [subjectID '_audiobook_logfile_section1.mat'])));
S = load(files{1});
assert(isfield(S, 'WebSession') && isfield(S, 'WebImport'));
assert(strcmp(S.Info.subjectID, 'TEST'));
assert(isequal(S.Info.trials(1).spaceTimes_sec, markerTimes));
assert(isequal(readBytes(wav), readBytes(S.Info.trials(1).reportAudioFile)));
assert(isempty(S.Info.trials(2).reportAudioFile) && all(isnan(S.Info.trials(2).spaceTimes_sec)));
assert(isnan(S.Info.trials(3).spaceTimes_sec(3)));
assert(strcmp(S.WebSession.sections.trials(3).status, 'partial'));
assert(isequal(fieldnames(S.Info), {'subjectID';'section';'startTime';'endTime';'audiobookFile';'probeTimes';'effectiveProbeTimes';'cueAudioFiles';'trials';'comprehension'}));
assert(isequal(fieldnames(S.Info.trials), fieldnames(emptyTrials())));
assert(isstring(S.Info.trials(1).recallSegment) && isstring(S.Info.trials(1).cue));
assert(isequal(size(S.Info.probeTimes), [3 1]) && isequal(size(S.Info.trials), [1 3]));

% Reimport cannot wipe analysis/transcript fields already added to the MAT.
Info = S.Info;
Info.trials(1).aiReportTranscript = 'Preserve this transcript.';
save(files{1}, 'Info', '-append');
importSession(jsonFile, backup, fullfile(testRoot, 'canonical'));
S = load(files{1});
assert(strcmp(S.Info.trials(1).aiReportTranscript, 'Preserve this transcript.'));
assert(isfield(S, 'WebSession') && isfield(S, 'WebImport'));

% Google Drive download uses a different flat filename, same original bytes.
drive = fullfile(testRoot, 'drive'); mkdir(drive);
copyfile(jsonFile, fullfile(drive, 'session.json'));
copyfile(wav, fullfile(drive, 'section1_probe_001_section1_probe001_reports.wav'));
copyfile(wav, fullfile(drive, 'section1_probe_003_section1_probe003_reports.wav'));
[driveFiles, ~, driveSubject] = importSession(fullfile(drive, 'session.json'), drive, fullfile(testRoot, 'drive_import'));
D = load(driveFiles{1}, 'Info');
assert(strcmp(D.Info.trials(1).reportAudioFile, fullfile(driveSubject, 'section1', 'probe_001_reports.wav')));
assert(isequal(readBytes(wav), readBytes(D.Info.trials(1).reportAudioFile)));

% Current Google folder: readable names, section subfolders, original bytes.
newDrive = fullfile(testRoot, 'new_drive'); mkdir(newDrive); mkdir(fullfile(newDrive, 'section1'));
web.file_prefix = 'TEST_20261106_120000';
for p = [1 3]
    copyfile(wav, fullfile(newDrive, 'section1', sprintf('%s_section1_probe_%03d_reports.wav', web.file_prefix, p)));
end
writeJSON(fullfile(newDrive, 'session.json'), web);
[newFiles, ~, ~] = importSession(fullfile(newDrive, 'session.json'), newDrive, fullfile(testRoot, 'new_drive_import'));
N = load(newFiles{1});
assert(isequal(readBytes(wav), readBytes(N.Info.trials(1).reportAudioFile)));

% Section IDs 3-9 are supported; annotations are never invented by import.
nine = web.sections{1}; nine.section = 9;
for p = [1 3]
    nine.trials(p).recording_id = sprintf('section9_probe%03d', p);
    nine.trials(p).reportAudioFile = sprintf('section9/probe_%03d_reports.wav', p);
end
mkdir(fullfile(backup, 'section9'));
for p = [1 3], copyfile(wav, fullfile(backup, 'section9', sprintf('probe_%03d_reports.wav', p))); end
webNine = web; webNine.sections = {web.sections{1}, nine};
writeJSON(fullfile(backup, 'nine.json'), webNine);
[nineFiles, ~, ~, sectionNumbers] = importSession(fullfile(backup, 'nine.json'), backup, fullfile(testRoot, 'nine_import'));
assert(isequal(sectionNumbers, [1 9]) && numel(nineFiles) == 2);

% An identical JSON cannot restore changed audio into a previous import.
canonicalWav = fullfile(subjectDir, 'section1', 'probe_001_reports.wav');
delete(canonicalWav);
audiowrite(wav, y*0.5, fs, 'BitsPerSample', 16);
failed = false;
try
    importSession(jsonFile, backup, fullfile(testRoot, 'canonical'));
catch
    failed = true;
end
assert(failed && ~isfile(canonicalWav), 'Changed source bytes must not replace audio in an existing import.');

% Missing expected captured audio is an error, not a fabricated empty trial.
delete(fullfile(drive, 'section1_probe_003_section1_probe003_reports.wav'));
failed = false;
try
    importSession(fullfile(drive, 'session.json'), drive, fullfile(testRoot, 'missing_import'));
catch
    failed = true;
end
assert(failed, 'Missing captured audio should stop the import.');
assert(~isfolder(fullfile(testRoot, 'missing_import')), 'Validation should fail before creating output.');
fprintf('\nPASS: lab Info schema, old/new Drive names, section 9, unchanged WAVs and markers, partial/no-capture handling, transcript preservation, and missing-audio detection.\n');
end
function writeJSON(path, value)
fid = fopen(path, 'w'); assert(fid ~= -1);
cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>
fwrite(fid, jsonencode(value), 'char');
end
function bytes = readBytes(path)
fid = fopen(path, 'rb'); assert(fid ~= -1);
cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>
bytes = fread(fid, Inf, '*uint8');
end
