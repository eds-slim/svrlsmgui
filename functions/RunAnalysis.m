function [success,handles] = RunAnalysis(hObject,eventdata,handles)

global MAGICNUMBER



if isempty(gcbo) || isa(gcbo,'matlab.ui.container.Menu')
    handles.parameters.runfromgui = 0;
else
    handles.parameters.runfromgui = 1;
end

%try

handles.parameters = ValidateSVRLSMParameters(handles.parameters);  % fill in any missing parms
%% Validate parameters - in future move to other function
handles.parameters.time = [];
handles.parameters.time.starttime = datestr(now);

handles.parameters.datetime_run = date; % when the analysis was run.
handles.parameters.PermNumClusterwise = handles.parameters.PermNumVoxelwise; % override the user so that these two values are the same.

tic; % this is what we'll use to time the execution of the analysis...

handles.parameters.baseoutputdir = fullfile(handles.parameters.analysis_out_path,handles.parameters.analysis_name,handles.parameters.datetime_run);

if OutputDirectoryAlreadyExists(handles)
    prompt={'An output directory with this name already exists. To avoid overwriting that output, change the name of your analysis. Or continue to overwrite.'};
    name = 'Rename analysis';
    defaultans = {handles.parameters.analysis_name};
    answer = inputdlg(prompt,name,[1 40],defaultans);
    if isempty(answer)
        success= 1;
        return
    end
    handles.parameters.analysis_name = answer{1};
    if handles.parameters.runfromgui
        handles = PopulateGUIFromParameters(handles);
    end
    handles.parameters.baseoutputdir = fullfile(handles.parameters.analysis_out_path,handles.parameters.analysis_name,handles.parameters.datetime_run); % so we write to this directory in this analysis.
end

handles = UpdateProgress(handles,'Beginning analysis...',0);

% Expose the Cancel button...
if handles.parameters.runfromgui
    set(handles.runanalysisbutton,'Enable','off')
    set(handles.interrupt_button,'Enable','on')
    set(gcf,'userdata',[]); % in case it was set to 'cancel' previously we don't want to re-trigger
    
    % disable analysis controls while running.
    set(get(handles.permutationtestingpanel,'children'),'enable','off')
    set(get(handles.analysispreferencespanel,'children'),'enable','off')
    set(get(handles.covariatespanel,'children'),'enable','off')
end

%%

parameters = handles.parameters; % Make a local copy of parameters struct for convenience.



if handles.parameters.runfromgui
    parameters.waitbar = [handles.progressaxes_rectangle handles.progressaxes_text];
else
    parameters.waitbar = [];
end

% Tell which SVM will be used...
handles = UpdateProgress(handles,sprintf('Analyses will be computed with %s.',myif(parameters.useLibSVM,'libSVM','MATLAB''s SVM')),1);

% Tell what optimization...
handles = UpdateProgress(handles,sprintf('Hyperparameters will %s.',myif(parameters.optimization.do_optimize,['be optimized via ' CurrentOptimString(handles.parameters)],'not be optimized.')),1);

%% Read behavior score and/or make sure all the requested behavioral scores are present for the patients in the file.
handles = UpdateProgress(handles,'Reading behavioral scores...',1);
variables = read_behavior_score(parameters);

%% Set up our output directory names
% I attempted to shorten these on 3/16/18 because I think MRIcron has a limit to how long a path can be when you try to read in a file... ?
variables.output_folder.analysis = fullfile(handles.parameters.analysis_out_path,handles.parameters.analysis_name);
folderstring = [parameters.score_name ', ' lower(parameters.tails)];
variables.output_folder.base = fullfile(variables.output_folder.analysis,handles.parameters.datetime_run,folderstring);
variables.output_folder.covariates = fullfile(variables.output_folder.base,'Covariates');
variables.output_folder.hyperparameterinfo = fullfile(variables.output_folder.base,'hyperparameters');
variables.output_folder.cache = fullfile(variables.output_folder.base,'cache');
variables.output_folder.ica = fullfile(variables.output_folder.base,'ica');

folderstring = sprintf('Voxwise p%s (%d perms)',strrep(num2str(parameters.voxelwise_p),'0.',''),parameters.PermNumVoxelwise);
variables.output_folder.voxelwise = fullfile(variables.output_folder.base,folderstring);
folderstring = sprintf('Clustwise p%s (%d perms)',strrep(num2str(parameters.clusterwise_p),'0.',''),parameters.PermNumClusterwise);
variables.output_folder.clusterwise = fullfile(variables.output_folder.voxelwise,folderstring);

if parameters.do_CFWER
    folderstring = sprintf('CFWER p%s at v%d (%d perms)',strrep(num2str(parameters.cfwer_p_value),'0.',''),parameters.cfwer_v_value,parameters.PermNumClusterwise);
    variables.output_folder.cfwer = fullfile(variables.output_folder.base,folderstring);
    
    % Overwrite voxelwise and clusterwise directory names used for regular non-cfwer output
    variables.output_folder.voxelwise = variables.output_folder.cfwer;
    variables.output_folder.clusterwise = variables.output_folder.cfwer;
end

success = CreateDirectory(variables.output_folder.base); %#ok<NASGU> % this is the date subdirectory.

handles.parameters.parmsfile = fullfile(variables.output_folder.base,'Analysis Parameters');

handles.parameters.output_folders = variables.output_folder;

%% Read lesion images...
handles = UpdateProgress(handles,'Reading lesion images...',1);

% Remove people with non-existent lesion data
has_no_lesion = cellfun(@(x) exist(fullfile(parameters.lesion_img_folder,[x '.nii']),'file'),variables.SubjectID) == 0;
n_without_lesions=sum(has_no_lesion);
variables.excluded.no_lesion = variables.SubjectID(has_no_lesion); % for summary.
if n_without_lesions > 0
    handles = UpdateProgress(handles,[num2str(n_without_lesions) ' lesion file(s) not found, so subject(s) removed from analysis.'],1);
    variables.SubNum = variables.SubNum - n_without_lesions;
    variables.scorefiledata(has_no_lesion,:) = []; % remove rows
    variables.one_score(has_no_lesion) = []; % remove rows
    variables.SubjectID(has_no_lesion) = []; % remove rows
    if isempty(variables.SubjectID), error('No subjects are included in this analysis.'); end
else
    handles = UpdateProgress(handles,'All lesion files found.',1);
end

variables = read_lesion_imgs(parameters, variables);

% Notify user if/which subject(s) was/were removed because they had no voxels in the min lesion overlap mask
if numel(variables.excluded.novoxels) == 0
    msg = sprintf('All subject lesions fall within minimum lesion cutoff mask.');
else
    msg = sprintf('Subjects excluded because all voxels outside lesion cutoff mask: %s',strjoin(variables.excluded.novoxels,', '));
end
handles = UpdateProgress(handles,msg,1);

handles = UpdateProgress(handles,'Successfully read behavioral scores and lesion images...',1);
handles = UpdateProgress(handles,sprintf('Running analysis for ''%s''...', parameters.score_name),1);

%% Save the pre-analysis parameters files. Will be replaced after analysis concludes.
%% Record subjects in the analysis, and those who were excluded due to missing data...
handles.parameters.excluded_subjects = variables.excluded; % for summary.
handles.parameters.nsubjects = variables.SubNum;
tosave = handles.parameters;
save(tosave.parmsfile,'tosave') % write the parameters file before the analysis begins.

%% Before going further, check if we think we'll have enough space to do this analysis...
results = nbytes_required_for_svrlsm_analysis(parameters,variables);
msg = sprintf('Analysis will require ~%sMB scratch space on disk.',num2str(round(results.nbytes_required/1e6))); % divide by a million... not 2^20 apparently.
handles = UpdateProgress(handles,msg,1);
if ~results.enough_space
    handles = UpdateProgress(handles,'There does not appear to be enough free disk space, aborting...',1);
    success = 2;
    return
else
    handles = UpdateProgress(handles,'Disk space should be adequate for estimated storage necessary.',1);
end

% < In future, check here if we have enough RAM to hold the svr models in memory.

%% Decide what we have to covary out of the behavioral data (one score) and the lesion data
switch handles.parameters.lesionvolcorrection
    case 'Regress on Behavior'
        include_lesionvol_in_behavioral_nuisance_model = 1;
        include_lesionvol_in_brain_nuisance_model = 0;
    case 'Regress on Both'
        include_lesionvol_in_behavioral_nuisance_model = 1;
        include_lesionvol_in_brain_nuisance_model = 1;
    case 'Regress on Lesion'
        include_lesionvol_in_behavioral_nuisance_model = 0;
        include_lesionvol_in_brain_nuisance_model = 1;
    case 'None'
        include_lesionvol_in_behavioral_nuisance_model = 0;
        include_lesionvol_in_brain_nuisance_model = 0;
    case 'DTLVC'
        include_lesionvol_in_behavioral_nuisance_model = 0;
        include_lesionvol_in_brain_nuisance_model = 0;
        handles = UpdateProgress(handles,sprintf('Applying dTLVC transformation to lesion data voxel values.'),1);
        variables.lesion_dat = variables.lesion_dat ./ repmat(sqrt(variables.lesion_vol),1,size(variables.lesion_dat,2));
    otherwise
        error('Unknown lesion volume correction string.')
end

%% Store values so later we can determine if one_score is correlated with lesion volume prior to any correction
handles.parameters.one_score = variables.one_score;
handles.parameters.lesion_vol = variables.lesion_vol;

%% Construct and run behavioral nuisance model
handles.parameters.behavioralmodeldata = []; % empty unless we have behavioral model to run - for summary diagnostics

if isempty(parameters.control_variable_names) % then make sure we won't try to apply any covariates...
    handles.parameters.apply_covariates_to_behavior = 0;
    handles.parameters.apply_covariates_to_lesion = 0;
end

behavioral_nuisance_model_options = [handles.parameters.apply_covariates_to_behavior include_lesionvol_in_behavioral_nuisance_model];
if any(behavioral_nuisance_model_options)
    modelspec = 'one_score ~';
    tmp = [];
    tmp.one_score = variables.one_score;
    
    switch num2str(behavioral_nuisance_model_options)
        case '1  0'
            handles = UpdateProgress(handles,sprintf('Behavior nuisance model will include behavioral covariate(s) but not lesion size.'),1);
            for c = 1 : numel(handles.parameters.control_variable_names)
                curcovariate = handles.parameters.control_variable_names{c};
                modelspec = [modelspec '+' curcovariate]; %#ok<AGROW>
                tmp.(curcovariate) = variables.scorefiledata.(curcovariate);
            end
        case '0  1'
            handles = UpdateProgress(handles,sprintf('Behavior nuisance model will include lesion size but not behavioral covariate(s).'),1);
            modelspec = [modelspec ' LesionVol']; % LesionVolInternal
            tmp.LesionVol = variables.lesion_vol; % LesionVolInternal
        case '1  1'
            handles = UpdateProgress(handles,sprintf('Behavior nuisance model will include both behavioral covariate(s) and lesion size.'),1);
            for c = 1 : numel(handles.parameters.control_variable_names)
                curcovariate = handles.parameters.control_variable_names{c};
                modelspec = [modelspec '+' curcovariate]; %#ok<AGROW>
                tmp.(curcovariate) = variables.scorefiledata.(curcovariate);
            end
            modelspec = [modelspec '+ LesionVol']; % LesionVolInternal
            tmp.LesionVol = variables.lesion_vol; % LesionVolInternal
    end
    
    % Clean up and actually run the model. Save the results back to one_score field.
    modelspec = strrep(modelspec,'~+','~'); % remove leading plus sign of there is one
    t = struct2table(tmp);
    handles = UpdateProgress(handles,sprintf(['Behavioral nuisance model spec: ' modelspec]),1);
    if strcmp(modelspec,'one_score ~')
        handles = UpdateProgress(handles,sprintf('Skipping running an empty behavioral nuisance model.'),1);
    else
        mdl = fitlm(t,modelspec,'intercept',true);
        variables.one_score = mdl.Residuals.Raw(:); % save raw residuals (residualized behavioral data) for analysis.
        variables.one_score = variables.one_score + repmat(mdl.Coefficients.Estimate(1),size(variables.one_score)); % 8/7/17 -- add estimated intercept back in.
        handles = UpdateProgress(handles,sprintf('Behavior nuisance model complete.'),1);
        
        % Now collect behavioral nuisance model data for diagnostics in summary - 9/25/17
        data = mdl.Variables;
        data.Properties.VariableNames{1} = parameters.score_name;
        tmp = table(variables.one_score,'VariableNames',{[parameters.score_name '_corrected']});
        handles.parameters.behavioralmodeldata = [data tmp]; % save so we can do model diagnostics in summary
    end
else
    handles = UpdateProgress(handles,sprintf('No behavior nuisance model will be constructed.'),1);
end

% Make sure we have enough info in our behavioral model data table so we can do diagnostics, no matter the lesion vol control used
% if ~isfield(handles.parameters.behavioralmodeldata,'LesionVolInternal')
%     LesionVolInternal = variables.lesion_vol(:);
%     handles.parameters.behavioralmodeldata = [handles.parameters.behavioralmodeldata table(LesionVolInternal)]; % add lesion vol...
% end

check_for_interrupt(parameters)

%% Construct and run voxelwise lesion data nuisance model
%% ES: HOOK pre-perm testing
if MAGICNUMBER == -1
    brain_nuisance_model_options = [handles.parameters.apply_covariates_to_lesion include_lesionvol_in_brain_nuisance_model];
    if any(brain_nuisance_model_options)
        tmp = [];
        switch num2str(brain_nuisance_model_options)
            case '1  0'
                handles = UpdateProgress(handles,sprintf('Lesion data nuisance model will include behavioral covariates but not lesion size.'),1);
                for c = 1 : numel(handles.parameters.control_variable_names)
                    curcovariate = handles.parameters.control_variable_names{c};
                    tmp.(curcovariate) = variables.scorefiledata.(curcovariate);
                end
            case '0  1'
                handles = UpdateProgress(handles,sprintf('Lesion data nuisance model will include lesion size but not behavioral covariates.'),1);
                tmp.LesionVol = variables.lesion_vol(:); % LesionVolInternal
            case '1  1'
                handles = UpdateProgress(handles,sprintf('Lesion data nuisance model will include both behavioral covariate(s) and lesion size.'),1);
                for c = 1 : numel(handles.parameters.control_variable_names)
                    curcovariate = handles.parameters.control_variable_names{c};
                    tmp.(curcovariate) = variables.scorefiledata.(curcovariate);
                end
                tmp.LesionVol = variables.lesion_vol(:); % LesionVolInternal
        end
        
        % Run the model and save the results back to the lesion_dat matrix
        
        % Convert fields (covariate names) in tmp variable to an array
        % - this supports categorical variables now using dummyvar(grp2idx(x))
        variables.lesion_nuisance_model = [];
        fields = fieldnames(tmp);
        for f = 1 : numel(fields)
            curfieldname = fields{f};
            curdata = tmp.(curfieldname);
            switch class(curdata)
                case 'cell' % meaning it's categorical...
                    dummyvarcoded = dummyvar(grp2idx(curdata));
                    variables.lesion_nuisance_model(:,end+1:end+size(dummyvarcoded,2)) = dummyvarcoded; % append
                otherwise % treat it as numbers...
                    variables.lesion_nuisance_model(:,end+1) = curdata; % append
            end
        end
        
        % original code:
        %variables.lesion_nuisance_model = struct2array(tmp); % make into regular ol' data columns...
        
        handles = UpdateProgress(handles,sprintf('Beginning lesion nuisance model with covariates: %s',strjoin(fieldnames(tmp)')),1);
        variables = continuize_lesions(variables,parameters); % will automatically use the field .lesion_nuisance_model
        variables.lesion_dat = variables.lesion_dat2;
        handles = UpdateProgress(handles,sprintf('Lesion nuisance model complete.'),1);
    else
        handles = UpdateProgress(handles,sprintf('No lesion data nuisance model will be employed.'),1);
    end
    
    if ~isfield(handles,'options')
        handles.options.lesionvolumecorrection = {'Regress on Behavior','Regress on Lesion','Regress on Both','DTLVC','None'};
        handles.options.hypodirection = {'High scores are bad', 'High scores are good'}; %{'One-tailed (positive)','One-tailed (negative)'}; % ,'Two-tailed'}; % this is ok even though it's old labeling
    end
    
    check_for_interrupt(parameters)
    
    % Standardize the behavior to be predicted (Y) - this is different from
    % 'Standardize' yes/no for the SVR, which affects the the *predictor* data
    do_this_part = true;
    if do_this_part
        handles = UpdateProgress(handles,'Standardizing behavioral to be predicted to 0-100 range.',1);
        if isa(variables.one_score,'cell')
            error('Currently the primary outcome of SVRLSMGUI cannot be categorical.')
        end
        minoffset = min(variables.one_score(:)); % Accommodate negative numbers...
        variables.one_score = minoffset + variables.one_score; % bring all vals >=0
        maxscaleval = 100;
        maxmultiplier = maxscaleval/max(abs(variables.one_score));
        variables.one_score = variables.one_score*maxmultiplier;
    else
        minoffset = 0;
        maxmultiplier = 1;
    end
    
    % We'll use these in summary output function WritePredictBehaviorReport()
    parameters.original_behavior_transformation.minoffset = minoffset;
    parameters.original_behavior_transformation.maxmultiplier = maxmultiplier;
    
    save([parameters.analysis_out_path filesep 'prepermparams.mat'], 'variables','handles','parameters') %% '-regexp','^(?!MAGICNUMBER$).'
    return
    
end %% end ES HOOK pre-perm testing

prepermparams = load([parameters.analysis_out_path filesep 'prepermparams.mat']);
prepermparams.variables.output_folder = variables.output_folder;

variables = prepermparams.variables;
handles.options = prepermparams.handles.options;
parameters.original_behavior_transformation.minoffset = prepermparams.parameters.original_behavior_transformation.minoffset;
parameters.original_behavior_transformation.maxmultiplier = prepermparams.parameters.original_behavior_transformation.maxmultiplier;

%% Standardize behavior and lesion data if requested... the standardization only applies to both or neither at the moment.
% if 1 == 2
%     %The software centers and scales each column of the predictor data (X) by the weighted column mean and standard deviation,
%     % respectively (for details on weighted standardizing, see Algorithms).
%
%     if parameters.standardize % I believe this is the right thing to do here...
%         handles = UpdateProgress(handles,'Standardizing behavioral and lesion data to 0-100 range.',1);
%         % standardize the behavioral data if requested.
%         minoffset = min(variables.one_score(:)); % accommodate negative numbers...
%         variables.one_score = minoffset + variables.one_score; % bring all vals >=0
%         variables.one_score = variables.one_score*100/max(abs(variables.one_score));
%         %variables.one_score = variables.one_score*100/max(abs(variables.one_score)); % < this is the default behavior for the original SVRLSM (Zhang et al., 2014)
%
%         % standardize the lesion data -- could have values that are < 0 and > 1 depending on what transform was applied ...
%     %     minoffset = min(variables.lesion_dat(:));
%     %     variables.lesion_dat = variables.lesion_dat + minoffset; % bring all vals >=0
%     %     variables.lesion_dat = variables.lesion_dat.*100./max(abs(variables.lesion_dat));
%     else
%         handles = UpdateProgress(handles,'Not standardizing behavioral and lesion data.',1);
%     end
% else
%     disp('** Regular normalize step disabled for testing..')
% end

% %% ICA Decompose Lesion data if requested - pre-alpha...
% if parameters.beta.do_ica_on_lesiondata
%     error('Not supported at the moment.')
%     handles = UpdateProgress(handles,'ICA decomposing lesion data... this is pre-alpha, do not use it.',1);
%     [parameters,variables] = svrlsm_prepare_ica(parameters,variables);
% end

%% Optimize hyperparameters if requested
parameters.optimization.best.sigma = nan; % placeholders regardless of whether we are optimizing.
parameters.optimization.best.cost = nan; % not .box (although it's equivalent)
parameters.optimization.best.standardize = nan;
parameters.optimization.best.epsilon = nan;

if parameters.method.mass_univariate
    handles = UpdateProgress(handles,'Mass-univarate mode enabled, so hyperparameter optimization does not apply.',1);
else
    if parameters.optimization.do_optimize
        handles = UpdateProgress(handles,'Beginning hyperparameter optimization...',1);
        parameters = svrlsm_optimizehyperparameters(parameters,variables);
        handles = UpdateProgress(handles,'Hyperparameter optimization complete...',1);
    else
        handles = UpdateProgress(handles,'No hyperparameter optimization requested, so skipping.',1);
    end
    % Tell what hyperparameters used will be
    hyperparms = hyperparmstruct(parameters);
    msg = sprintf('Hyperparameters: C = %.2f, %s = %.2f, ε = %.2f, standardize = %s', hyperparms.cost, myif(parameters.useLibSVM,'γ','σ'),myif(parameters.useLibSVM,hyperparms.gamma,hyperparms.sigma),hyperparms.epsilon,myif(hyperparms.standardize,'true','false'));
    handles = UpdateProgress(handles,msg,1);
    
    % If we finish hyperparameter optimization (or it was skipped) and standardize is true then let's apply that procedure here *ONCE* for libSVM. MATLAB will apply it at each fitrsvm call.
    if parameters.useLibSVM % this accounts for either optimization choosing true or manually choosing true...
        do_standardize = myif(parameters.optimization.do_optimize & parameters.optimization.params_to_optimize.standardize, parameters.optimization.best.standardize, parameters.standardize);
        if do_standardize
            handles = UpdateProgress(handles,'Manually standardizing predictor (lesion) columns for libSVM (MATLAB does this auto).',1);
            % In a MATLAB model with 'Standardize' set to true, the mean and std of each col is contained in .Mu and .Sigma output
            % Do what MATLAB does when 'Standardize' == true: The software centers and scales each column of the predictor data (X) by
            % the weighted column mean and standard deviation, respectively (for details on weighted standardizing, see Algorithms).
            warning('In MATLAB these scaling values are only calculated based on rows used as support vectors... I don''t think we can easily do this for libSVM, can we?')
            tmp = variables.lesion_dat;
            tmp2 = tmp - nanmean(tmp); % subtract the mean of each column.
            tmp3 = tmp2 ./ nanstd(tmp2); % divide each column by its standard deviation
            variables.lesion_dat = tmp3;
        end
    end
    
    % Compute a parameter report in terms of its optimality.... based on Zhang et al 2014.
    %     if ~parameters.useLibSVM
    handles = UpdateProgress(handles,'Measuring quality of hyperparameters...',1);
    %          warning('disabled')
    if MAGICNUMBER==0
        variables = optimalParameterReport(parameters,variables);
    end
    %     else % we can't do it...
    %         handles = UpdateProgress(handles,'Skipping hyperparameter quality measurement (no libSVM)...',1);
    %     end
end

%svrinteract(variables); % interactive hyperparm tuning...

%% Compute the real, single beta map of the observed data.
handles = UpdateProgress(handles,'Computing beta map...',1);
[beta_map, variables] = get_beta_map(parameters, variables); % either mu or svr

check_for_interrupt(parameters)





%% Permutation test
if parameters.DoPerformPermutationTesting
    handles = UpdateProgress(handles,'Creating output directories for permutation testing results...',1);
    success = CreateDirectory(variables.output_folder.voxelwise); %#ok<NASGU>
    success = CreateDirectory(variables.output_folder.clusterwise); %#ok<NASGU>
    
    [variables, success] = run_beta_permutations(parameters, variables, beta_map,handles);
    if(success == -1)
        return
    end
    
    if parameters.do_CFWER
        %variables = evaluate_clustering_results(handles,variables,parameters);
    else
        % Evaluate clustering results
        variables = evaluate_clustering_results(handles,variables,parameters);
        handles = UpdateProgress(handles,sprintf('Results of analysis:'),1);
        handles = UpdateProgress(handles,sprintf('%d voxels survive voxelwise threshold (P < %g, %d perms).',variables.clusterresults.survivingbetavals,parameters.voxelwise_p,parameters.PermNumVoxelwise),1);
        handles = UpdateProgress(handles,sprintf('%d of %d clusters survive clusterwise threshold (P < %g, k > %d voxels, %d perms).',variables.clusterresults.survivingclusters,variables.clusterresults.totalclusters,parameters.clusterwise_p,variables.clusterresults.clusterthresh,parameters.PermNumClusterwise),1);
    end
end
handles.parameters.original_behavior_transformation = parameters.original_behavior_transformation;
handles.parameters.optimization = parameters.optimization;
handles.parameters.files_created = variables.files_created;
handles.parameters.time.endtime = datestr(now);
handles.parameters.time.runduration = toc;
handles.parameters.analysis_is_completed = 1;
tosave = handles.parameters;

%% Finish the analysis...
try delete(parmsfile); end %#ok<TRYNC>
save(tosave.parmsfile,'tosave'); % write the file again so we know the analysis completed
success = 1;

check_for_interrupt(parameters)

handles = UpdateProgress(handles,sprintf('Starting summary file...'),1);
htmlout = SummarizeAnalysis(tosave.parmsfile); % if desired...
handles = UpdateProgress(handles,myif(isempty(htmlout),'Done, no summary file requested.','Done writing summary file...'),1);

%catch ME % If the analysis encounters an error of some sort...
%      success = 0; % failure.
%      svrlsm_waitbar(parameters.waitbar,0,''); % clear this.
%      if strcmp(get(gcf,'userdata'),'cancel') % if the running was canceled, then let's make sure to clean up what happened...
%          set(gcf,'userdata',[]); % in case it was set to 'cancel' previously we don't want to re-trigger
%          success = 2; % cancelled...
%          % don't rethrow here -- stop gracefully.
%      else
%        handles.error = ME;
%        % don't rethrow here -- stop gracefully.
%      end
%end