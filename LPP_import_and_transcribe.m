function LPP_import_and_transcribe(action, subjectDir)
%LPP_IMPORT_AND_TRANSCRIBE Import web data, transcribe locally, and review scores.
% Put this file beside LPP_web.m, then run:
%   LPP_import_and_transcribe
% Choose the participant's UNZIPPED download containing session.json and WAVs.
% The importer creates one lab-format MAT file per section and copies the WAVs.
%
% Keep the supplied transcribe_FREE.py beside this file on Mac or Windows
% Each computer needs its own existing Python environment with faster-whisper
% Run LPP_import_and_transcribe('check') to check that setup without loading a model
% Complete-WAV transcripts go in Info.trials.aiReportTranscript, as in Luca's
% script. Additional clips separate recall, attention, and KSS for scoring;
% the original WAVs and accepted SPACE markers are never modified.
%
% After transcription, listen to the WAVs and edit behavior_review.csv:
% - Correct recall_transcript, attention_state, and kss as necessary.
% - Mark reviewed=1 only after checking the recording; exclude=1 omits a trial.
% Then recompute the reviewed results without running Whisper again:
%   LPP_import_and_transcribe('summarize', '/path/to/participant_timestamp')
% To transcribe an already imported participant folder:
%   LPP_import_and_transcribe('transcribe', '/path/to/participant_timestamp')
% To check the scoring and clip-boundary functions in MATLAB:
%   LPP_import_and_transcribe('test')
%
% Automatic scores are estimates, not verified behavioral observations.
% MW and mind-blanking are separate categories; unclear responses stay unknown.
% Recall is lexical word coverage, not semantic similarity. During review,
% correct ASR spelling/numeral differences before accepting automatic scores.
% No audio is sent to a transcription API by this wrapper.

if nargin < 1, action = 'import'; end
if nargin < 2, subjectDir = ''; end
here = fileparts(mfilename('fullpath'));
if strcmpi(action, 'test'), selfTest(); return; end
if strcmpi(action, 'check')
    [pythonExe, pythonScript, ~] = transcriptionSettings(here);
    if isempty(pythonExe) || isempty(pythonScript), return; end
    checkPython(pythonExe, pythonScript); return;
end
if strcmpi(action, 'summarize')
    if isempty(subjectDir), subjectDir = uigetdir(pwd, 'Select converted participant folder'); end
    if isequal(subjectDir, 0), return; end
    summarizeReview(char(subjectDir)); return;
end
assert(any(strcmpi(action, {'import','transcribe'})), 'Unknown action.');
if strcmpi(action, 'import')
    assert(isfile(fullfile(here, 'LPP_web.m')), 'Save LPP_web.m beside this file.');
    addpath(here);
    [~, ~, subjectDir, ~] = LPP_web('import');
    if isempty(subjectDir), return; end
elseif isempty(subjectDir)
    subjectDir = uigetdir(pwd, 'Select converted participant folder');
    if isequal(subjectDir, 0), return; end
end
subjectDir = char(subjectDir);
assert(isfolder(subjectDir), 'Participant folder not found.');
logs = dir(fullfile(subjectDir, '*_audiobook_logfile_section*.mat'));
assert(~isempty(logs), 'No section MAT files found in %s.', subjectDir);

%% Check the local Python setup before creating a transcription run
[pythonExe, pythonScript, modelName] = transcriptionSettings(here);
if isempty(pythonExe) || isempty(pythonScript), fprintf('Import saved; transcription cancelled.\n'); return; end
pythonEnvironment = checkPython(pythonExe, pythonScript);
[~, suffix] = fileparts(tempname);
runName = ['run_' datestr(now, 'yyyymmdd_HHMMSS') '_' suffix];
analysisDir = fullfile(subjectDir, 'analysis', runName);
mkdir(analysisDir);
rows = repmat(emptyRow(), 0, 1);
started = tic;

for isec = 1:numel(logs)
    logFile = fullfile(logs(isec).folder, logs(isec).name);
    S = load(logFile);
    assert(isfield(S, 'Info'), 'Missing Info in %s.', logFile);
    Info = S.Info;
    section = double(Info.section);
    wavDir = fullfile(subjectDir, sprintf('section%d', section));
    workDir = fullfile(analysisDir, sprintf('section%d', section));
    mkdir(workDir);
    if isempty(Info.trials), continue; end
    fullNames = strings(0, 1); fullTexts = strings(0, 1);
    if ~isempty(dir(fullfile(wavDir, '*_reports.wav')))
        [fullNames, fullTexts, wholeCSV] = runWhisper(pythonExe, pythonScript, ...
            modelName, wavDir, '*_reports.wav', fullfile(workDir, 'whole'));
    else
        wholeCSV = '';
    end
    if ~isfield(Info.trials, 'aiReportTranscript'), [Info.trials.aiReportTranscript] = deal(""); end
    clipDir = fullfile(workDir, 'clips'); mkdir(clipDir);
    firstRow = numel(rows) + 1;
    for t = 1:numel(Info.trials)
        trial = Info.trials(t);
        r = emptyRow(); r.participant_id = string(Info.subjectID);
        r.section = section; r.probeNumber = double(trial.probeNumber);
        r.recall_target = string(trial.recallSegment); r.cue = string(trial.cue);
        [r.expected_continuation, targetOK] = continuation(r.recall_target, r.cue);
        if ~targetOK, r.review_notes = "Cue is not a prefix of the target; scoring requires review."; end
        r.wav_file = string(trial.reportAudioFile);
        webTrial = struct();
        if isfield(S, 'WebSession')
            r.session_id = string(S.WebSession.session_id);
            webTrial = findWebTrial(S.WebSession, section, r.probeNumber);
        end
        wavName = sprintf('probe_%03d_reports.wav', r.probeNumber);
        [text, found] = matchText(fullNames, fullTexts, wavName);
        if found && strlength(strtrim(text)) > 0
            Info.trials(t).aiReportTranscript = text;
        end
        r.whole_transcript = string(Info.trials(t).aiReportTranscript);
        if ~found, r.review_notes = addNote(r.review_notes, "No new complete-WAV transcript."); end
        if strlength(r.wav_file) == 0 || ~isfile(r.wav_file)
            r.split_status = "missing_audio";
        else
            [y, fs] = audioread(r.wav_file);
            [bounds, splitOK] = clipBounds(trial.spaceTimes_sec, fs, size(y, 1), webTrial);
            if splitOK
                labels = {'recall', 'attention', 'kss'};
                for k = 1:3
                    name = sprintf('probe_%03d_%s.wav', r.probeNumber, labels{k});
                    audiowrite(fullfile(clipDir, name), y(bounds(k,1):bounds(k,2), :), fs, 'BitsPerSample', 16);
                end
                r.split_status = "complete_three_reports";
            else
                r.split_status = "partial_or_invalid_markers";
                r.review_notes = addNote(r.review_notes, "Partial/invalid report boundaries; inspect the complete WAV.");
            end
        end
        if isfield(webTrial, 'quality') && isfield(webTrial.quality, 'warnings')
            r.quality_flags = strjoin(string(webTrial.quality.warnings), '|');
        end
        rows(end+1,1) = r;  
    end
    % Keep complete-WAV transcripts even if the optional clip pass fails.
    save(logFile, 'Info', '-append');
    clipNames = strings(0, 1); clipTexts = strings(0, 1);
    if ~isempty(dir(fullfile(clipDir, '*.wav')))
        [clipNames, clipTexts] = runWhisper(pythonExe, pythonScript, modelName, ...
            clipDir, '*.wav', fullfile(workDir, 'separate_reports'));
    end
    for j = firstRow:numel(rows)
        if rows(j).split_status ~= "complete_three_reports", continue; end
        p = rows(j).probeNumber;
        [rows(j).recall_transcript, recallFound] = matchText(clipNames, clipTexts, sprintf('probe_%03d_recall.wav', p));
        [rows(j).attention_transcript, attFound] = matchText(clipNames, clipTexts, sprintf('probe_%03d_attention.wav', p));
        [rows(j).kss_transcript, kssFound] = matchText(clipNames, clipTexts, sprintf('probe_%03d_kss.wav', p));
        rows(j).attention_state = parseAttention(rows(j).attention_transcript);
        rows(j).kss = parseKSS(rows(j).kss_transcript);
        if ~(recallFound && attFound && kssFound)
            rows(j).review_notes = addNote(rows(j).review_notes, "One or more clip transcripts are missing.");
        end
    end
    WebAnalysis = struct('model', modelName, 'runDirectory', analysisDir, ...
        'pythonEnvironment', pythonEnvironment, ...
        'wholeTranscriptCSV', wholeCSV, 'createdAt', datestr(now,30), ...
        'method', 'Whole-WAV transcript plus accepted-marker report clips; manual review required');
    save(logFile, 'Info', 'WebAnalysis', '-append');
    fprintf('Section %d: saved complete-WAV transcripts and review rows.\n', section);
end
assert(~isempty(rows), 'There are no probe rows to analyze.');
reviewFile = fullfile(subjectDir, 'behavior_review.csv');
if isfile(reviewFile)
    % Never overwrite reviewed decisions without retaining their exact CSV.
    copyfile(reviewFile, fullfile(analysisDir, 'previous_behavior_review.csv'));
    previous = readReview(reviewFile);
    rows = preserveReviewed(rows, previous);
end
writetable(struct2table(rows), reviewFile);
summarizeReview(subjectDir);
fprintf('\nFinished in %.1f minutes.\nReview: %s\n', toc(started)/60, reviewFile);
fprintf(['Listen to the recordings, correct the editable CSV, and mark reviewed=1.\n' ...
    'Then run LPP_import_and_transcribe(''summarize'', ''%s'')\n'], strrep(subjectDir, '''', ''''''));
end

function r = emptyRow()
r = struct('participant_id', "", 'session_id', "", 'section', NaN, 'probeNumber', NaN, ...
    'wav_file', "", 'recall_target', "", 'cue', "", 'expected_continuation', "", ...
    'whole_transcript', "", 'recall_transcript', "", 'attention_transcript', "", ...
    'kss_transcript', "", 'attention_state', "unclassified", 'kss', NaN, ...
    'reviewed', 0, 'exclude', 0, 'review_notes', "", 'split_status', "", 'quality_flags', "");
end

function [names, texts, csvFile] = runWhisper(python, script, model, inputDir, pattern, outputDir)
% Python creates this final folder and refuses to overwrite previous results
assert(~isfolder(outputDir) && ~isfile(outputDir), 'Choose a new transcription output folder: %s', outputDir);
args = {python, script, inputDir, '--model', model, '--pattern', pattern, '--output-dir', outputDir};
fprintf('\nTranscribing %s\n', inputDir);
[status, out] = runPython(args);
assert(status == 0, 'Whisper failed. Original data remain saved.\n%s', out);
csvFile = fullfile(outputDir, 'transcripts.csv');
assert(isfile(csvFile), 'Whisper CSV not found: %s', csvFile);
raw = readcell(csvFile, 'FileType', 'text', 'Delimiter', ',', 'TextType', 'string');
C = strings(size(raw));
for k = 1:numel(raw)
    v = raw{k};
    if isempty(v) || (isnumeric(v) && isscalar(v) && isnan(v)), continue; end
    v = string(v);
    if ismissing(v), continue; end
    C(k) = v;
end
assert(~isempty(C), 'Empty Whisper CSV: %s', csvFile);
headers = lower(strtrim(C(1,:)));
fcol = find(headers == "filename", 1);
tcol = find(ismember(headers, ["raw_transcript", "transcript", "text"]), 1);
if isempty(fcol) || isempty(tcol)
    assert(size(C,2) >= 5, 'Unexpected Whisper CSV schema.');
    fcol = 2; tcol = 5; first = 1; % Existing transcribe_FREE.py headerless format.
else
    first = 2;
end
names = strtrim(C(first:end,fcol)); texts = C(first:end,tcol);
texts(ismissing(texts)) = "";
for k = 1:numel(names)
    if ismissing(names(k)), names(k) = ""; continue; end
    [~, stem, ext] = fileparts(strrep(char(names(k)), '\', filesep));
    names(k) = string([stem ext]);
end
assert(numel(unique(lower(names))) == numel(names), 'Duplicate filenames in Whisper CSV.');
end

function [text, found] = matchText(names, texts, name)
i = find(strcmpi(names, name));
assert(numel(i) <= 1, 'Duplicate transcript for %s.', name);
found = ~isempty(i); text = "";
if found, text = texts(i); end
end

function t = findWebTrial(s, section, probe)
t = struct();
ss = asStructs(s.sections);
for i = 1:numel(ss)
    if ss(i).section ~= section, continue; end
    ts = asStructs(ss(i).trials);
    for j = 1:numel(ts)
        if ts(j).probeNumber == probe, t = ts(j); return; end
    end
end
end
function s = asStructs(s)
if iscell(s)
    if isempty(s), s = struct([]); return; end
    names = {};
    for k = 1:numel(s), names = union(names, fieldnames(s{k})', 'stable'); end
    for k = 1:numel(s)
        for j = 1:numel(names)
            if ~isfield(s{k},names{j}), s{k}.(names{j}) = []; end
        end
        s{k} = orderfields(s{k},names);
    end
    s = [s{:}];
end
end

function [bounds, ok] = clipBounds(times, fs, nSamples, webTrial)
% SPACE marks begin 80-ms marker tones. Exclude the tones from speech clips.
% Use exact saved zero-based sample indices when available; otherwise derive
% them from the lab-style seconds. A partial probe is not a complete response.
bounds = zeros(3,2); ok = false;
times = double(times(:)');
if numel(times) ~= 3 || any(~isfinite(times)) || any(diff(times) <= .08), return; end
if isfield(webTrial, 'status') && ~strcmp(webTrial.status, 'complete'), return; end
if isfield(webTrial, 'recordingPartial') && webTrial.recordingPartial, return; end
marks = round(times * fs);
if isfield(webTrial, 'spaceSampleIndices') && numel(webTrial.spaceSampleIndices) == 3
    exact = double(webTrial.spaceSampleIndices(:)');
    if any(~isfinite(exact)) || any(exact ~= round(exact)) || any(abs(exact-marks) > 1), return; end
    marks = exact;
end
if marks(1) < 1 || marks(3) > nSamples, return; end
toneLength = round(.08*fs);
bounds = [1, marks(1); marks(1)+toneLength+1, marks(2); marks(2)+toneLength+1, marks(3)];
ok = all(bounds(:,2) >= bounds(:,1)) && all(bounds(:) >= 1) && all(bounds(:) <= nSamples);
end

function s = normalize(s)
s = lower(strtrim(string(s)));
if ismissing(s), s = ""; end
s = replace(s, ["’", "'"], "");
s = regexprep(s, '[_-]', ' ');
% Source annotations sometimes write contractions as two words.
s = regexprep(s, '\<(i)\s+m\>', '$1m');
s = regexprep(s, '\<(it|he|she|that|there|what|who|here|let)\s+s\>', '$1s');
s = regexprep(s, '\<(i|you|we|they)\s+(ve|re|ll|d)\>', '$1$2');
s = regexprep(s, '\<(can|couldn|didn|doesn|don|hadn|hasn|haven|isn|shouldn|wasn|weren|won|wouldn)\s+t\>', '$1t');
s = regexprep(s, '[^a-z0-9 ]', ' ');
s = strtrim(regexprep(s, '\s+', ' '));
end
function words = tokens(s)
s = normalize(s);
if strlength(s) == 0, words = strings(1,0); else, words = split(s)'; end
end
function [target, ok] = continuation(fullTarget, cue)
a = tokens(fullTarget); b = tokens(cue);
ok = ~isempty(b) && numel(a) > numel(b) && isequal(a(1:numel(b)), b);
if ok, target = strjoin(a(numel(b)+1:end), ' '); else, target = ""; end
end
function s = parseAttention(text)
s = "unclassified"; text = normalize(text);
if ~isempty(regexp(char(text), '\<(not|no|dont|didnt|wasnt|werent|isnt|arent|couldnt|cannot|cant|maybe|unsure|uncertain|either|or)\>', 'once')), return; end
phrases = ["on task", "mind wandering", "mind blanking"];
labels = ["on-task", "mind-wandering", "mind-blanking"];
found = false(1,3);
for k = 1:3, found(k) = ~isempty(regexp(char(text), ['\<' char(phrases(k)) '\>'], 'once')); end
if sum(found) == 1, s = labels(found); end
end
function kss = parseKSS(text)
kss = NaN; text = normalize(text);
text = regexprep(text, '^(my sleepiness rating is|my rating is|i would say|i am|number)\s+', '');
text = regexprep(text, '^a\s+', '');
words = ["one","two","three","four","five","six","seven","eight","nine"];
i = find(words == text, 1);
if ~isempty(i), kss = i; elseif ~isempty(regexp(char(text), '^[1-9]$', 'once')), kss = str2double(text); end
end
function [proportion, exact, last, nTarget] = scoreRecall(target, cue, response)
a = tokens(target); b = tokens(response); c = tokens(cue);
proportion = NaN; exact = NaN; last = NaN; nTarget = numel(a);
if isempty(a) || isempty(b), return; end
% A participant may repeat the cue; do not count those words as recalled.
if numel(b) >= numel(c) && ~isempty(c) && isequal(b(1:numel(c)), c), b = b(numel(c)+1:end); end
if any(normalize(response) == ["i dont remember", "i dont remember anything", "dont remember", "i do not remember", "i cannot remember"]), b = strings(1,0); end
D = zeros(numel(a)+1, numel(b)+1);
for i = 1:numel(a)
    for j = 1:numel(b)
        if a(i) == b(j), D(i+1,j+1) = D(i,j)+1;
        else, D(i+1,j+1) = max(D(i,j+1), D(i+1,j)); end
    end
end
% Ordered word coverage: longest common subsequence / target-word count.
% Intrusions do not reduce coverage; exact_match provides a stricter measure.
proportion = D(end,end)/numel(a); exact = double(isequal(a,b));
last = double(~isempty(b) && b(end) == a(end));
end

function rows = preserveReviewed(rows, previous)
needed = {'section','probeNumber','reviewed','recall_transcript','attention_state','kss','exclude','review_notes'};
if ~all(ismember(needed, previous.Properties.VariableNames)), return; end
for j = 1:numel(rows)
    match = find(asNumber(previous.section) == rows(j).section & asNumber(previous.probeNumber) == rows(j).probeNumber);
    if numel(match) ~= 1 || asNumber(previous.reviewed(match)) ~= 1, continue; end
    if ismember('session_id',previous.Properties.VariableNames) && string(previous.session_id(match)) ~= rows(j).session_id, continue; end
    if ismember('recall_target',previous.Properties.VariableNames) && string(previous.recall_target(match)) ~= rows(j).recall_target, continue; end
    i = match;
    rows(j).recall_transcript = string(previous.recall_transcript(i));
    rows(j).attention_state = string(previous.attention_state(i));
    rows(j).kss = asNumber(previous.kss(i)); rows(j).reviewed = 1;
    rows(j).exclude = asNumber(previous.exclude(i)); rows(j).review_notes = string(previous.review_notes(i));
end
end
function T = readReview(file)
% Keep IDs and editable text as text, including columns that are wholly blank.
opts = detectImportOptions(file, 'FileType', 'text', 'Delimiter', ',', 'VariableNamingRule', 'preserve');
r = emptyRow(); names = fieldnames(r);
textNames = names(cellfun(@(name) isstring(r.(name)), names));
textNames = intersect(textNames, opts.VariableNames, 'stable');
opts = setvartype(opts, textNames, 'string');
T = readtable(file, opts);
for k = 1:numel(textNames)
    name = textNames{k};
    T.(name)(ismissing(T.(name))) = "";
end
end

function summarizeReview(subjectDir)
file = fullfile(subjectDir, 'behavior_review.csv');
assert(isfile(file), 'Review CSV not found: %s', file);
T = readReview(file);
needed = fieldnames(emptyRow());
assert(all(ismember(needed, T.Properties.VariableNames)), 'The review CSV is missing required columns.');
T.section = asNumber(T.section); T.probeNumber = asNumber(T.probeNumber);
assert(all(isfinite(T.section) & T.section>=1 & T.section==round(T.section)) && ...
    all(isfinite(T.probeNumber) & T.probeNumber>=1 & T.probeNumber==round(T.probeNumber)), 'Section and probe numbers must be positive integers.');
assert(numel(unique(T.participant_id))==1 && numel(unique(T.session_id))==1, 'Review one participant session at a time.');
T.reviewed = asNumber(T.reviewed); T.exclude = asNumber(T.exclude); T.kss = asNumber(T.kss);
assert(all(ismember(T.reviewed,[0,1])) && all(ismember(T.exclude,[0,1])), 'reviewed and exclude must contain 0 or 1.');
assert(all(isnan(T.kss) | (T.kss >= 1 & T.kss <= 9 & T.kss == round(T.kss))), 'KSS must be 1-9 or blank.');
T.attention_state = lower(strtrim(string(T.attention_state)));
T.attention_state(ismissing(T.attention_state) | T.attention_state == "") = "unclassified";
assert(all(ismember(T.attention_state,["on-task","mind-wandering","mind-blanking","unclassified"])), ...
    'Use attention_state on-task, mind-wandering, mind-blanking, or unclassified.');
key = string(T.section)+":"+string(T.probeNumber);
assert(numel(unique(key)) == height(T), 'Duplicate section/probe rows in review CSV.');
T.recall_word_coverage = nan(height(T),1); T.recall_exact_match = nan(height(T),1);
T.recall_last_word_correct = nan(height(T),1); T.target_word_count = zeros(height(T),1);
for i = 1:height(T)
    [target, ok] = continuation(T.recall_target(i), T.cue(i));
    T.expected_continuation(i) = target;
    if ok
        [T.recall_word_coverage(i), T.recall_exact_match(i), T.recall_last_word_correct(i), T.target_word_count(i)] = ...
            scoreRecall(target, T.cue(i), T.recall_transcript(i));
    end
end
% Keep the editable source separate from derived scores.
writetable(T, fullfile(subjectDir, 'behavior_trials.csv'));
sections = unique(T.section)'; summary = struct([]);
for scope = [0 sections]
    scopeMask = scope == 0 | T.section == scope;
    for reviewedOnly = [false true]
        eligible = scopeMask & T.exclude == 0 & (~reviewedOnly | T.reviewed == 1);
        valid = eligible & T.attention_state ~= "unclassified";
        on = valid & T.attention_state == "on-task";
        mw = valid & T.attention_state == "mind-wandering";
        blank = valid & T.attention_state == "mind-blanking";
        r = struct('participant_id',T.participant_id(1),'session_id',T.session_id(1), ...
            'section', scope, 'basis', "automatic_unreviewed_and_reviewed", ...
            'n_probes', sum(scopeMask), 'n_eligible', sum(eligible), 'n_attention_classified', sum(valid), ...
            'n_attention_unclassified', sum(eligible & ~valid), 'n_on_task', sum(on), ...
            'n_mind_wandering', sum(mw), 'n_mind_blanking', sum(blank), ...
            'mw_rate_all_classified', fraction(sum(mw),sum(valid)), ...
            'mw_rate_excluding_blanking', fraction(sum(mw),sum(on|mw)), ...
            'blanking_rate_all_classified', fraction(sum(blank),sum(valid)), ...
            'n_recall_on_task', sum(on & isfinite(T.recall_word_coverage)), ...
            'n_recall_mw', sum(mw & isfinite(T.recall_word_coverage)), ...
            'n_recall_blanking', sum(blank & isfinite(T.recall_word_coverage)), ...
            'mean_recall_coverage_on_task', average(T.recall_word_coverage(on)), ...
            'mean_recall_coverage_mw', average(T.recall_word_coverage(mw)), ...
            'mean_recall_coverage_blanking', average(T.recall_word_coverage(blank)), ...
            'exact_match_rate_on_task', average(T.recall_exact_match(on)), ...
            'exact_match_rate_mw', average(T.recall_exact_match(mw)), ...
            'last_word_accuracy_on_task', average(T.recall_last_word_correct(on)), ...
            'last_word_accuracy_mw', average(T.recall_last_word_correct(mw)), ...
            'n_kss', sum(eligible & isfinite(T.kss)), 'mean_kss', average(T.kss(eligible)), ...
            'n_comprehension_answered', 0, 'comprehension_accuracy', NaN);
        if reviewedOnly, r.basis = "reviewed_only"; end
        [nCorrect,nAnswered] = folderComprehension(subjectDir, scope);
        r.n_comprehension_answered = nAnswered; r.comprehension_accuracy = fraction(nCorrect,nAnswered);
        summary = [summary; r];  
    end
end
writetable(struct2table(summary), fullfile(subjectDir, 'behavior_summary.csv'));
WebBehavior = struct('trials',T,'summary',struct2table(summary),'generatedAt',datestr(now,30), ...
    'recallMetric','Ordered normalized target-word coverage, excluding cue; longest common subsequence / target words', ...
    'reviewWarning','Use reviewed_only for verified results; 0 in the section column means all sections.');
save(fullfile(subjectDir, 'behavior_analysis.mat'), 'WebBehavior', '-v7.3');
fprintf('Saved behavior_trials.csv, behavior_summary.csv, and behavior_analysis.mat.\n');
fprintf('%d of %d probe rows are marked reviewed. Section 0 in the summary means all sections.\n', sum(T.reviewed==1), height(T));
end

function [correct, answered] = folderComprehension(folder, scope)
correct = 0; answered = 0;
files = dir(fullfile(folder, '*_audiobook_logfile_section*.mat'));
for k = 1:numel(files)
    S = load(fullfile(files(k).folder,files(k).name),'Info');
    if scope ~= 0 && S.Info.section ~= scope, continue; end
    [c,n] = comprehensionCounts(S.Info); correct = correct+c; answered = answered+n;
end
end
function [correct, answered] = comprehensionCounts(info)
correct = 0; answered = 0;
if ~isfield(info,'comprehension'), return; end
qs = asStructs(info.comprehension);
for k = 1:numel(qs)
    if isfield(qs(k),'response') && isnumeric(qs(k).response) && isscalar(qs(k).response) && ismember(qs(k).response,1:4)
        answered = answered+1;
        if isfield(qs(k),'correctAnswer'), correct = correct+double(qs(k).response==qs(k).correctAnswer); end
    end
end
end
function value = asNumber(value)
if isnumeric(value) || islogical(value), value = double(value); else, value = str2double(string(value)); end
end
function v = average(x)
x = x(isfinite(x)); if isempty(x), v = NaN; else, v = mean(x); end
end
function v = fraction(a,b)
if b == 0, v = NaN; else, v = a/b; end
end
function s = addNote(s,note)
if strlength(s) == 0, s = note; else, s = s+" "+note; end
end
function path = chooseFile(path, filter, prompt)
if isfile(path), return; end
initial = fileparts(path); if ~isfolder(initial), initial = pwd; end
[name, folder] = uigetfile(filter, prompt, initial);
if isequal(name,0), path = ''; else, path = fullfile(folder,name); end
end
function [pythonExe, pythonScript, modelName] = transcriptionSettings(here)
% Set pythonExe to an exact path to override automatic environment selection
pythonExe = '';
pythonScript = fullfile(here, 'transcribe_FREE.py');
modelName = 'small.en';
if isempty(pythonExe)
    if ispc
        userHome = getenv('USERPROFILE');
        roots = {'C:\Experiments\FREE', fullfile(userHome, 'Projects', 'FREE'), 'C:\Experiments\FREE\AUDIOBOOK_DATA'};
        candidates = cellfun(@(root) fullfile(root, 'whisper_env', 'Scripts', 'python.exe'), roots, 'UniformOutput', false);
        candidates{end+1} = fullfile(here, 'whisper_env', 'Scripts', 'python.exe');
    elseif ismac
        userHome = getenv('HOME');
        roots = {fullfile(userHome, 'Projects', 'FREE'), '/Users/EMT/Projects/FREE', here};
        candidates = {};
        for k = 1:numel(roots)
            candidates = [candidates, {fullfile(roots{k}, 'whisper_env_mac', 'bin', 'python'), ...
                fullfile(roots{k}, 'whisper_env', 'bin', 'python')}];  
        end
    else
        candidates = {fullfile(getenv('HOME'), 'Projects', 'FREE', 'whisper_env', 'bin', 'python'), ...
            fullfile(here, 'whisper_env', 'bin', 'python')};
    end
    pythonExe = candidates{1};
    for k = 1:numel(candidates)
        if isfile(candidates{k}), pythonExe = candidates{k}; break; end
    end
end
if ispc, prompt = 'Select Python inside your Whisper environment (Scripts/python.exe)';
else, prompt = 'Select Python inside your Whisper environment (bin/python)'; end
pythonExe = chooseFile(pythonExe, '*', prompt);
if isempty(pythonExe), return; end
pythonScript = chooseFile(pythonScript, '*.py', 'Select the supplied transcribe_FREE.py');
end

function info = checkPython(python, script)
fprintf('\nChecking Python: %s\nScript: %s\n', python, script);
[status, out] = runPython({python, script, '--check'});
assert(status == 0, ['Python setup check failed; no recordings were changed.\n' ...
    'Use the supplied transcribe_FREE.py beside this MATLAB file and read the diagnostic below.\n%s'], out);
info = [];
lines = regexp(out, '\r?\n', 'split');
for k = numel(lines):-1:1
    try
        candidate = jsondecode(strtrim(lines{k}));
        if isstruct(candidate) && isfield(candidate, 'ok'), info = candidate; break; end
    catch
    end
end
assert(isstruct(info) && isfield(info, 'ok') && isequal(info.ok, true) && ...
    all(isfield(info, {'python_executable','platform','compute_type'})), ...
    'The Python file did not return the expected setup check. Use the supplied transcribe_FREE.py.');
fprintf('Python dependencies are ready on %s (CPU %s). The model is loaded when transcription starts.\n', ...
    char(info.platform), char(info.compute_type));
end

function [status, out] = runPython(args)
% Separate arguments avoid shell expansion and work with spaces on Mac and Windows
assert(usejava('jvm'), 'MATLAB Java support is required to launch Python.');
command = javaArray('java.lang.String', numel(args));
for k = 1:numel(args)
    value = char(args{k});
    assert(~any(value == char(0)), 'Invalid NUL character in a Python argument.');
    command(k) = javaObject('java.lang.String', value);
end
builder = javaObject('java.lang.ProcessBuilder', command);
builder.redirectErrorStream(true);
environment = builder.environment();
environment.put(javaObject('java.lang.String', 'PYTHONUNBUFFERED'), javaObject('java.lang.String', '1'));
environment.put(javaObject('java.lang.String', 'PYTHONIOENCODING'), javaObject('java.lang.String', 'utf-8'));
environment.put(javaObject('java.lang.String', 'PYTHONUTF8'), javaObject('java.lang.String', '1'));
% The log stays outside the output folder that Python needs to create
logPath = [tempname '.log'];
cleanupLog = onCleanup(@() removePythonLog(logPath)); %#ok<NASGU>
builder.redirectOutput(javaObject('java.io.File', logPath));
try
    process = builder.start();
catch problem
    error('LPP:PythonLaunch', 'Could not start the selected Python executable: %s\n%s', char(args{1}), problem.message);
end
cleanupProcess = onCleanup(@() stopPython(process)); %#ok<NASGU>
printedBytes = 0;
while process.isAlive()
    printedBytes = echoPythonLog(logPath, printedBytes, false);
    pause(.1);
    drawnow limitrate
end
status = double(process.waitFor());
[~, out] = echoPythonLog(logPath, printedBytes, true);
end

function [printedBytes, text] = echoPythonLog(path, printedBytes, final)
text = '';
fid = fopen(path, 'rb');
if fid < 0, return; end
closeFile = onCleanup(@() fclose(fid)); %#ok<NASGU>
bytes = fread(fid, Inf, '*uint8')';
if final
    last = numel(bytes);
    text = native2unicode(bytes, 'UTF-8');
else
    last = find(bytes == 10, 1, 'last');
    if isempty(last), return; end
end
% Print complete lines so polling cannot split a UTF-8 character
if last > printedBytes
    fprintf('%s', native2unicode(bytes(printedBytes+1:last), 'UTF-8'));
    printedBytes = last;
end
end

function stopPython(process)
if process.isAlive()
    process.destroy();
    if process.isAlive(), process.destroyForcibly(); end
end
end

function removePythonLog(path)
try
    if isfile(path), delete(path); end
catch
end
end
function selfTest()
assert(normalize('i m')=="im" && normalize('don t')=="dont" && normalize('it s')=="its");
assert(parseAttention('On-task.') == "on-task");
assert(parseAttention('mind blanking') == "mind-blanking");
assert(parseAttention('not on task') == "unclassified");
assert(parseAttention('I wasn''t on task') == "unclassified");
assert(parseAttention('on-task or mind-wandering') == "unclassified");
assert(parseAttention('I was mind wandering') == "mind-wandering");
assert(parseKSS('five') == 5 && parseKSS('9') == 9 && isnan(parseKSS('five or six')));
[target,ok] = continuation('boa constrictors swallow their prey whole without chewing','boa constrictors');
assert(ok && target == "swallow their prey whole without chewing");
[p,e,l,n] = scoreRecall(target,'boa constrictors','boa constrictors swallow their prey whole without chewing');
assert(p==1 && e==1 && l==1 && n==6);
[p,e,l] = scoreRecall(target,'boa constrictors','chewing'); assert(p==1/6 && e==0 && l==1);
[p,~,~] = scoreRecall(target,'boa constrictors','I do not remember'); assert(p==0);
[p,~,~] = scoreRecall(target,'boa constrictors',''); assert(isnan(p));
[b,ok] = clipBounds([1 2 3],1000,4000,struct());
assert(ok && isequal(b,[1 1000;1081 2000;2081 3000]));
[~,ok] = clipBounds([1 2 NaN],1000,4000,struct()); assert(~ok);
[~,ok] = clipBounds([1 2 3],1000,4000,struct('status','partial')); assert(~ok);
assert(isnan(fraction(0,0)) && isnan(average([])));
% Exercise CSV typing, missing transcripts, denominators, and reviewed-only results.
folder = tempname; mkdir(folder);
cleanup = onCleanup(@() rmdir(folder,'s')); %#ok<NASGU>
Info = struct('subjectID','001','section',1,'comprehension', ...
    struct('response',2,'correctAnswer',2));
save(fullfile(folder,'001_test_audiobook_logfile_section1.mat'),'Info');
r = repmat(emptyRow(),4,1);
for i = 1:4
    r(i).participant_id = "001"; r(i).session_id = "001_test";
    r(i).section = 1; r(i).probeNumber = i;
    r(i).recall_target = "we walk slowly"; r(i).cue = "we";
end
r(1).attention_state = "on-task"; r(1).recall_transcript = "walk slowly"; r(1).reviewed = 1;
r(2).attention_state = "mind-wandering"; r(2).recall_transcript = "slowly"; r(2).reviewed = 1;
r(3).attention_state = "mind-blanking";
r(4).reviewed = 1; % Verified but unclassifiable: excluded from attention denominator.
f = fullfile(folder,'behavior_review.csv'); writetable(struct2table(r),f);
R = readReview(f); assert(R.participant_id(1) == "001" && R.recall_transcript(4) == "");
summarizeReview(folder);
A = load(fullfile(folder,'behavior_analysis.mat'),'WebBehavior');
U = A.WebBehavior.summary; trials = A.WebBehavior.trials;
a = U(U.section==0 & U.basis=="automatic_unreviewed_and_reviewed",:);
b = U(U.section==0 & U.basis=="reviewed_only",:);
assert(a.n_attention_classified==3 && a.mw_rate_all_classified==1/3);
assert(b.n_attention_classified==2 && b.n_attention_unclassified==1 && b.mw_rate_all_classified==.5);
assert(b.mean_recall_coverage_on_task==1 && b.mean_recall_coverage_mw==.5);
assert(isnan(trials.recall_word_coverage(3)) && isnan(trials.recall_word_coverage(4)));
assert(b.comprehension_accuracy==1);
fprintf('Scoring, CSV, category, missing-data, and marker-boundary tests passed.\n');
end
