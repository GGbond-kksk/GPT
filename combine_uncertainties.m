%% combine_uncertainties.m
% Script to calculate combined standard and expanded uncertainties
% from a list of individual standard uncertainty components and
% visualise their relative contributions.
%
% The script interactively requests:
%   * The number of uncertainty components
%   * The name and value (standard uncertainty) of each component
%   * An optional coverage factor (defaults to k = 2)
%
% Outputs include:
%   * A printed summary table
%   * A figure showing the magnitude of each standard uncertainty and
%     their percentage contribution to the combined uncertainty
%
% This script is compatible with MATLAB and GNU Octave.

clear; clc;

disp('=== Combined Uncertainty Calculator ===');

% Read number of components
numComponents = input('Enter the number of uncertainty components: ');
while ~(isscalar(numComponents) && numComponents >= 0 && floor(numComponents) == numComponents)
    fprintf('Please enter a non-negative integer value.\n');
    numComponents = input('Enter the number of uncertainty components: ');
end

if numComponents == 0
    fprintf('\nNo components provided. Combined uncertainty is zero.\n');
    return;
end

componentNames = cell(numComponents, 1);
standardUncertainties = zeros(numComponents, 1);

for i = 1:numComponents
    promptName = sprintf('Enter name for component %d: ', i);
    name = strtrim(input(promptName, 's'));
    if isempty(name)
        name = sprintf('Component %d', i);
    end
    componentNames{i} = name;

    promptValue = sprintf('Enter standard uncertainty for "%s": ', name);
    value = input(promptValue);
    while ~(isscalar(value) && isnumeric(value) && value >= 0)
        fprintf('  -> Please enter a non-negative numeric value.\n');
        value = input(promptValue);
    end
    standardUncertainties(i) = value;
end

coverageFactor = input('Enter coverage factor k (press Enter to use k = 2): ');
if isempty(coverageFactor)
    coverageFactor = 2;
end
while ~(isscalar(coverageFactor) && isnumeric(coverageFactor) && coverageFactor >= 0)
    fprintf('Please enter a non-negative numeric value for k.\n');
    coverageFactor = input('Enter coverage factor k (press Enter to use k = 2): ');
    if isempty(coverageFactor)
        coverageFactor = 2;
    end
end

combinedStdUncertainty = sqrt(sum(standardUncertainties .^ 2));
expandedUncertainty = coverageFactor * combinedStdUncertainty;

% Avoid division by zero when combined uncertainty is zero
if combinedStdUncertainty > 0
    contributionPercent = (standardUncertainties .^ 2) / combinedStdUncertainty^2 * 100;
else
    contributionPercent = zeros(numComponents, 1);
end

% Display results
fprintf('\n=== Results ===\n');
fprintf('Combined standard uncertainty (uc): %.6g\n', combinedStdUncertainty);
fprintf('Expanded uncertainty (U = k * uc) with k = %.4g: %.6g\n', coverageFactor, expandedUncertainty);

summaryTable = table(componentNames, standardUncertainties, contributionPercent, ...
    'VariableNames', {'Component', 'StandardUncertainty', 'ContributionPercent'});
disp(summaryTable);

% Visualisation
figure('Name', 'Uncertainty Contribution');
subplot(2, 1, 1);
bar(standardUncertainties, 'FaceColor', [0.2 0.45 0.7]);
grid on;
ylabel('Standard uncertainty');
title('Standard uncertainties for each component');
set(gca, 'XTick', 1:numComponents, 'XTickLabel', componentNames);
xlabel('Components');

subplot(2, 1, 2);
bar(contributionPercent, 'FaceColor', [0.85 0.33 0.1]);
grid on;
ylabel('Contribution (%)');
title('Percentage contribution to combined uncertainty');
set(gca, 'XTick', 1:numComponents, 'XTickLabel', componentNames);
xlabel('Components');

fprintf('\nPlots generated. Close the figure window to finish.\n');
