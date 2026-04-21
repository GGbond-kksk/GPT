function rad_out = full_calib_and_dn2radiance_uncertainty_ENVI_BIL()
%% 一键跑完（完整可运行版）：
% 第一部分（XXX）：辐射定标不确定度评估（用于获得 a,b 及其不确定度）
% 第二部分（XXX）：复原辐亮度 L 不确定度评估（融合 a,b 不确定度与 DN/角度传播）
%
% ===== 重要约束（按你要求）=====
% 1) specCal ONLY 进入拟合阶段：只用于估计 a/b/cov(a,b) 的不确定度（sigma_a, sigma_b, cov_ab）
%    绝不作为直接作用于 L 的乘性项叠加；贡献图也不会出现 specCal 单独项
% 2) 可视化拆成两套：
%    (A) DN端：Noise + SZA/SAA/VZA/VAA 对 DN 的贡献
%    (B) L端：DN传播 + a-fit + b-fit + |cov(a,b)| + sourceInstab 对 L 的贡献
%
% 说明：sourceInstab 作为“直接作用在 L 上”的相对不确定度 (k=1) 叠加到 sigma_L 中

clc; clear; close all;

%% ================== 0) 配置：你只改这里 ==================
cfg = struct();

% ========== A) 定标文件所在目录（Excel + CSV）==========
cfg.calib_dir   = 'E:\北航\长光所光谱仪\20250326光谱仪二次定标'; % TODO
cfg.excel_file  = fullfile(cfg.calib_dir, '3000-12000积分球rad.xlsx'); % TODO
cfg.csv_files = {
    fullfile(cfg.calib_dir, 'jifenqiu3000_avg_spectra.csv')
    fullfile(cfg.calib_dir, 'jifenqiu4000_avg_spectra.csv')
    fullfile(cfg.calib_dir, 'jifenqiu5000_avg_spectra.csv')
    fullfile(cfg.calib_dir, 'jifenqiu6000_avg_spectra.csv')
    fullfile(cfg.calib_dir, 'jifenqiu7000_avg_spectra.csv')
    fullfile(cfg.calib_dir, 'jifenqiu8000_avg_spectra.csv')
    fullfile(cfg.calib_dir, 'jifenqiu9000_avg_spectra.csv')
    fullfile(cfg.calib_dir, 'jifenqiu10000_avg_spectra.csv')
    fullfile(cfg.calib_dir, 'jifenqiu11000_avg_spectra.csv')
    fullfile(cfg.calib_dir, 'jifenqiu12000_avg_spectra.csv')
    };

cfg.num_pixels    = 480;   % 标定像元数（samples）
cfg.L_sigma_ratio = 0.02;  % 积分球辐亮度相对标准不确定度（k=1）——基础项（拟合阶段用）
cfg.L_fit_instr_noise_ratio = 0.005; % 拟合阶段仪器噪声相对标准不确定度（k=1）
cfg.use_parfor    = false; % 并行池会触发 fopen 限制，建议 false

% ========== B) DN/不确定度立方体所在目录（默认：本 .m 文件目录）==========
thisFile = mfilename('fullpath');
thisDir  = fileparts(thisFile);
cfg.cube_dir = thisDir;

% ---------- 白板/场景 DN：ENVI BIL ----------
cfg.white_dn_bil = fullfile(cfg.cube_dir, 'sun30+7_diff_VZA0_VAA177_1-1_registered_registered.bil'); % TODO
cfg.white_dn_hdr = ''; % 留空则自动推断同名 .hdr
cfg.scene_dn_bil = fullfile(cfg.cube_dir, 'sun30+7_shapan_VZA0_VAA177_1-1_registered_registered_sceneNormToWhite_t500.bil'); % TODO
cfg.scene_dn_hdr = '';

% ---------- DN噪声相对不确定度(k=1) ----------
cfg.urel_DN_noise = 0.01; % 标量或cube（如有bil也支持：cfg.urel_DN_noise_bil / cfg.urel_DN_noise_hdr）

% ---------- 角度不确定度（对DN的相对标准不确定度k=1，来自你的RRMSE cube） ----------
cfg.white_sza_bil = fullfile(cfg.cube_dir, 'DIFF_SAAx_RRMSE_mean_cube_registered.bil'); % 注意：你原文件名可能对调，这里保持你给的
cfg.white_sza_hdr = '';
cfg.white_saa_bil = fullfile(cfg.cube_dir, 'DIFF_SZAx_RRMSE_mean_cube_registered.bil');
cfg.white_saa_hdr = '';

cfg.scene_sza_bil = fullfile(cfg.cube_dir, 'SP_SZAx_RRMSE_mean_cube_registered.bil');
cfg.scene_sza_hdr = '';
cfg.scene_saa_bil = fullfile(cfg.cube_dir, 'SP_SAAx_RRMSE_mean_cube_registered.bil');
cfg.scene_saa_hdr = '';
cfg.scene_vza_bil = fullfile(cfg.cube_dir, 'SP_VZAx_RRMSE_mean_cube_registered.bil');
cfg.scene_vza_hdr = '';
cfg.scene_vaa_bil = fullfile(cfg.cube_dir, 'SP_VAAx_RRMSE_mean_cube_registered.bil');
cfg.scene_vaa_hdr = '';

% ---------- 光谱定标 specCal & 积分球源不稳定性 sourceInstab ----------
% specCal：只用于拟合阶段（影响 a/b/cov 的不确定度），不会直接作用于 L
cfg.urel_L_spectralCal_txt = fullfile(cfg.cube_dir, 'uSpec_relative.txt');          % 用于拟合阶段 (k=1, rel)
% sourceInstab：直接作用在 L 上（k=1, rel），会叠加到最终 sigma_L
cfg.urel_L_sourceInstab_txt= fullfile(cfg.cube_dir, 'urel_L_sourceInstab_rel.txt');% (k=1, rel)

% ========== 输出 ==========
cfg.out_dir         = fullfile(cfg.cube_dir, 'shapan_RadianceCubes_withUncertainty_Output');
cfg.save_mat         = true;
cfg.block_rows       = 0;      % 大数据可设 200~800（主计算）
cfg.use_single       = false;
cfg.export_envi_bil  = true;
cfg.export_dtype     = 'single';
if ~exist(cfg.out_dir,'dir'); mkdir(cfg.out_dir); end

% ========== 绘图 ==========
cfg.do_plot      = true;
cfg.plot_mode    = 'roi'; % 'full' | 'roi' | 'point'
cfg.plot_roi     = [];     % [r0 r1 c0 c1] or [r r c c]，空则交互选
cfg.roi_select_interactive = true;
cfg.roi_allow_point = true;
cfg.preview_band_nm = 550;
cfg.preview_what    = 'L_scene'; % 'L_scene' 或 'L_white'
cfg.plot_band_nm = 550;
cfg.plot_unc_k   = 2;
cfg.save_png_dpi = 300;
cfg.close_figs   = false;
cfg.unc_k        = cfg.plot_unc_k;

% ========== 保存fig ==========
cfg.save_fig = true;
cfg.save_png = true;

% ========== ROI/点选输出 ==========
cfg.roi = struct();
cfg.roi.enable    = false;
cfg.roi.row       = [];
cfg.roi.col       = [];
cfg.roi.half_size = 0;

% ========== 贡献图：按你要求拆成两套 ==========
cfg.contrib_block_rows = max(cfg.block_rows, 200);

cfg.do_dn_contrib_plot = true;         % DN端：Noise+SZA+SAA+VZA+VAA
cfg.do_L_contrib_plot  = true;         % L端：DN-prop + a/b/cov + sourceInstab
cfg.dn_contrib_plot_k  = cfg.unc_k;    % 显示用 k
cfg.L_contrib_plot_k   = cfg.unc_k;    % 显示用 k

% ===== 关键：specCal 只进拟合阶段（锁死 false）=====
cfg.L_include_specCal_direct = false;  %#ok<STRNU>  % 仅占位，不允许改为 true

%% ================== 第一部分（XXX）：辐射定标部分 ==================
% 目标：获得 a,b 及其不确定度（包含：积分球 + 光谱定标 + 仪器噪声）

%% 1) 读取积分球辐亮度（Excel）
[lambda, radiances] = load_radiances_excel(cfg.excel_file);
[bands, num_conditions] = size(radiances);

%% 1.5) 读取 specCal（相对,k=1）并合成到拟合阶段L
urel_L_specCal_forFit_k1 = load_urel_spectrum_txt(cfg.urel_L_spectralCal_txt, lambda, 'spectralCal_forFit', 'rel'); % [B x 1]
urel_L_sphere_k1 = cfg.L_sigma_ratio * ones(bands,1);
urel_L_instr_k1  = cfg.L_fit_instr_noise_ratio * ones(bands,1);
urel_L_fit_total_k1 = sqrt( urel_L_sphere_k1.^2 + urel_L_specCal_forFit_k1.^2 + urel_L_instr_k1.^2 ); % [B x 1]

%% 2) 读取标定 DN（多个CSV）
DN_calib = load_dn_cube_from_csv(cfg.csv_files, cfg.num_pixels, bands, num_conditions); % [W x B x cond]

%% 3) 标定：逐像元逐波段 OLS 拟合 + σa/σb/covab
fprintf('▶ 开始标定：W=%d, B=%d, 条件数=%d ...\n', cfg.num_pixels, bands, num_conditions);
[a_matrix, b_matrix, r2_matrix, sa_matrix, sb_matrix, cab_matrix] = ...
    calculate_coefficients_ols_unc(DN_calib, radiances, urel_L_fit_total_k1, cfg.use_parfor);
fprintf('✅ 标定完成。\n');

%% ================== 第二部分（XXX）：复原辐亮度 L 不确定度 ==================
% 目标：融合 a,b 不确定度 + 白板SZA/SAA->DN + 场景SZA/SAA/VZA/VAA->DN，得到 L 的不确定度

%% 4) 读取 DN 白板/场景（ENVI BIL）
DN_white = read_envi_cube_to_HWB(cfg.white_dn_bil, cfg.white_dn_hdr);
DN_scene = read_envi_cube_to_HWB(cfg.scene_dn_bil, cfg.scene_dn_hdr);

assert(size(DN_white,2) == cfg.num_pixels, 'DN_white samples(W)=%d 与 num_pixels=%d 不一致', size(DN_white,2), cfg.num_pixels);
assert(size(DN_scene,2) == cfg.num_pixels, 'DN_scene samples(W)=%d 与 num_pixels=%d 不一致', size(DN_scene,2), cfg.num_pixels);
assert(size(DN_white,3) == bands, 'DN_white bands=%d 与标定 bands=%d 不一致', size(DN_white,3), bands);
assert(size(DN_scene,3) == bands, 'DN_scene bands=%d 与标定 bands=%d 不一致', size(DN_scene,3), bands);

%% 5) 读取 DN 噪声 u_rel（标量/ENVI BIL）
if isfield(cfg,'urel_DN_noise_bil') && ~isempty(cfg.urel_DN_noise_bil)
    urel_DN_noise_raw = read_envi_cube_to_HWB(cfg.urel_DN_noise_bil, cfg.urel_DN_noise_hdr);
else
    urel_DN_noise_raw = cfg.urel_DN_noise;
end

%% 6) 读取角度不确定度（对DN的 u_rel，ENVI BIL）
uSZA_w = read_envi_cube_to_HWB(cfg.white_sza_bil, cfg.white_sza_hdr);
uSAA_w = read_envi_cube_to_HWB(cfg.white_saa_bil, cfg.white_saa_hdr);

uSZA_s = read_envi_cube_to_HWB(cfg.scene_sza_bil, cfg.scene_sza_hdr);
uSAA_s = read_envi_cube_to_HWB(cfg.scene_saa_bil, cfg.scene_saa_hdr);
uVZA_s = read_envi_cube_to_HWB(cfg.scene_vza_bil, cfg.scene_vza_hdr);
uVAA_s = read_envi_cube_to_HWB(cfg.scene_vaa_bil, cfg.scene_vaa_hdr);

assert(isequal(size(uSZA_w), size(DN_white)), 'u_rel_SZA_white 尺寸与 DN_white 不一致');
assert(isequal(size(uSAA_w), size(DN_white)), 'u_rel_SAA_white 尺寸与 DN_white 不一致');
assert(isequal(size(uSZA_s), size(DN_scene)), 'u_rel_SZA_scene 尺寸与 DN_scene 不一致');
assert(isequal(size(uSAA_s), size(DN_scene)), 'u_rel_SAA_scene 尺寸与 DN_scene 不一致');
assert(isequal(size(uVZA_s), size(DN_scene)), 'u_rel_VZA_scene 尺寸与 DN_scene 不一致');
assert(isequal(size(uVAA_s), size(DN_scene)), 'u_rel_VAA_scene 尺寸与 DN_scene 不一致');

%% 7) DN端：把每项 u_rel * |DN| 变成 σ(DN)，再合成
% 白板：SZA / SAA
absDN_white   = abs(DN_white);
sigmaDN_SZA_w = uSZA_w .* absDN_white;
sigmaDN_SAA_w = uSAA_w .* absDN_white;
sigmaDN_ang_w = sqrt(sigmaDN_SZA_w.^2 + sigmaDN_SAA_w.^2);

% 场景：SZA / SAA / VZA / VAA
absDN_scene   = abs(DN_scene);
sigmaDN_SZA_s = uSZA_s .* absDN_scene;
sigmaDN_SAA_s = uSAA_s .* absDN_scene;
sigmaDN_VZA_s = uVZA_s .* absDN_scene;
sigmaDN_VAA_s = uVAA_s .* absDN_scene;
sigmaDN_ang_s = sqrt(sigmaDN_SZA_s.^2 + sigmaDN_SAA_s.^2 + sigmaDN_VZA_s.^2 + sigmaDN_VAA_s.^2);

% 打包：用于 DN 贡献图（注意：这里存的是 “sigmaDN 分量”，不是 u_rel）
dnSigW = struct('sza', sigmaDN_SZA_w, 'saa', sigmaDN_SAA_w, 'vza', [],            'vaa', []);
dnSigS = struct('sza', sigmaDN_SZA_s, 'saa', sigmaDN_SAA_s, 'vza', sigmaDN_VZA_s, 'vaa', sigmaDN_VAA_s);

%% 8) 白板：DN -> L + sigma_L 3D（此时只含 a/b/协方差 + DN传播）
fprintf('▶ 白板：DN -> L + sigma_L ...\n');
[L_white, sigma_L_white_k1, u_rel_L_white_k1] = dn_cube_to_radiance_cube( ...
    DN_white, urel_DN_noise_raw, sigmaDN_ang_w, ...
    a_matrix, b_matrix, sa_matrix, sb_matrix, cab_matrix, cfg.block_rows);

%% 9) 场景：DN -> L + sigma_L 3D（此时只含 a/b/协方差 + DN传播）
fprintf('▶ 场景：DN -> L + sigma_L ...\n');
[L_scene, sigma_L_scene_k1, u_rel_L_scene_k1] = dn_cube_to_radiance_cube( ...
    DN_scene, urel_DN_noise_raw, sigmaDN_ang_s, ...
    a_matrix, b_matrix, sa_matrix, sb_matrix, cab_matrix, cfg.block_rows);

%% 9.x) 仅叠加“直接作用在L上”的源不稳定性 sourceInstab（rel,k=1）
urel_L_source_k1  = load_urel_spectrum_txt(cfg.urel_L_sourceInstab_txt,  lambda, 'sourceInstab','rel'); % [B x 1]
B = bands;

urel3_source_w = repmat(reshape(urel_L_source_k1,  [1 1 B]), [size(L_white,1) size(L_white,2) 1]);
urel3_source_s = repmat(reshape(urel_L_source_k1,  [1 1 B]), [size(L_scene,1) size(L_scene,2) 1]);

sigma_add_source_white = urel3_source_w .* abs(L_white);
sigma_add_source_scene = urel3_source_s .* abs(L_scene);

sigma_L_white_k1 = sqrt( sigma_L_white_k1.^2 + sigma_add_source_white.^2 );
u_rel_L_white_k1 = sigma_L_white_k1 ./ max(abs(L_white), 1e-12);

sigma_L_scene_k1 = sqrt( sigma_L_scene_k1.^2 + sigma_add_source_scene.^2 );
u_rel_L_scene_k1 = sigma_L_scene_k1 ./ max(abs(L_scene), 1e-12);

tmp_urel_L_source_k1  = urel_L_source_k1(:);
tmp_urel_L_specCal_k1 = urel_L_specCal_forFit_k1(:); % 仅记录：不会直接进 L

%% 9) 绘图（两部分可视化都在这里输出）
if cfg.do_plot
    figDir = fullfile(cfg.out_dir, 'Figures');
    if ~exist(figDir,'dir'); mkdir(figDir); end
    unitL = 'W·m^{-2}·sr^{-1}·nm^{-1}';
    assert(numel(lambda)==B, 'lambda 长度应等于 bands');

    cfg = configure_roi_for_plot(cfg, L_white, L_scene, lambda);
    if strcmpi(cfg.plot_mode, 'roi')
        fprintf('✅ ROI = %s\n', format_roi_bounds(cfg));
    end

    % ========== 第一部分（XXX）专用可视化 ==========
    fig = figure('Color','w'); hold on;
    plot(lambda, 100*cfg.unc_k*urel_L_sphere_k1(:),  'LineWidth', 1.8);
    plot(lambda, 100*cfg.unc_k*urel_L_specCal_forFit_k1(:), 'LineWidth', 1.8);
    plot(lambda, 100*cfg.unc_k*urel_L_instr_k1(:), 'LineWidth', 1.8);
    plot(lambda, 100*cfg.unc_k*urel_L_fit_total_k1(:), 'k--', 'LineWidth', 1.8);
    xlabel('Wavelength (nm)'); ylabel(sprintf('U_{rel,fit-in}(k=%d, %%)', cfg.unc_k));
    grid on; title('第一部分（XXX）：拟合输入不确定度组成（积分球+光谱定标+仪器噪声）');
    legend({'Sphere','SpecCal','InstrNoise','Total'}, 'Location','best');
    export_fig_png_and_fig(fig, fullfile(figDir,'Part1_Fig_fitInputUnc_breakdown_k2'), cfg.save_png_dpi, cfg.save_png, cfg.save_fig, cfg.close_figs);

    fig = figure('Color','w'); hold on;
    plot(lambda, mean(sa_matrix,1,'omitnan'), 'LineWidth', 1.8);
    plot(lambda, mean(sb_matrix,1,'omitnan'), 'LineWidth', 1.8);
    plot(lambda, mean(abs(cab_matrix),1,'omitnan'), 'LineWidth', 1.8);
    xlabel('Wavelength (nm)'); ylabel('k=1');
    grid on; title('第一部分（XXX）：拟合输出参数不确定度（空间均值）');
    legend({'\sigma_a','\sigma_b','|cov(a,b)|'}, 'Location','best');
    export_fig_png_and_fig(fig, fullfile(figDir,'Part1_Fig_fitOutputUnc_mean_k1'), cfg.save_png_dpi, cfg.save_png, cfg.save_fig, cfg.close_figs);

    fig = figure('Color','w');
    plot(lambda, mean(r2_matrix,1,'omitnan'), 'LineWidth', 1.8);
    xlabel('Wavelength (nm)'); ylabel('R^2');
    grid on; title('第一部分（XXX）：标定拟合质量（R^2 空间均值）');
    export_fig_png_and_fig(fig, fullfile(figDir,'Part1_Fig_fitQuality_R2_mean'), cfg.save_png_dpi, cfg.save_png, cfg.save_fig, cfg.close_figs);

    % ========== 第二部分（XXX）专用可视化 ==========
    % 1) 画 sourceInstab 谱（k=2显示）
    fig = figure('Color','w');
    plot(lambda, 100*cfg.unc_k*urel_L_source_k1(:), 'LineWidth', 1.8);
    xlabel('Wavelength (nm)'); ylabel(sprintf('U_{rel,source} (k=%d, %%)', cfg.unc_k));
    grid on; title(sprintf('第二部分（XXX）：sourceInstab uncertainty on radiance (relative, k=%d)', cfg.unc_k));
    export_fig_png_and_fig(fig, fullfile(figDir,'Part2_Fig_uRel_sourceInstab_k2'), cfg.save_png_dpi, cfg.save_png, cfg.save_fig, cfg.close_figs);

    % 2) 立方体相对不确定度：空间均值/中位数（白板 vs 场景）
    uW_rel = reshape(u_rel_L_white_k1, [], B);
    uS_rel = reshape(u_rel_L_scene_k1, [], B);
    UrelW_mean = cfg.unc_k * mean(uW_rel, 1, 'omitnan');
    UrelS_mean = cfg.unc_k * mean(uS_rel, 1, 'omitnan');
    UrelW_med  = cfg.unc_k * median(uW_rel, 1, 'omitnan');
    UrelS_med  = cfg.unc_k * median(uS_rel, 1, 'omitnan');

    fig = figure('Color','w'); hold on;
    plot(lambda, 100*UrelW_mean, 'LineWidth', 1.8);
    plot(lambda, 100*UrelS_mean, 'LineWidth', 1.8);
    plot(lambda, 100*UrelW_med,  '--', 'LineWidth', 1.4);
    plot(lambda, 100*UrelS_med,  '--', 'LineWidth', 1.4);
    xlabel('Wavelength (nm)');
    ylabel(sprintf('U_{rel}(k=%d, %%) (spatial summary)', cfg.unc_k));
    legend({'White mean','Scene mean','White median','Scene median'}, 'Location','best');
    grid on; title(sprintf('第二部分（XXX）：final radiance relative uncertainty (k=%d)', cfg.unc_k));
    export_fig_png_and_fig(fig, fullfile(figDir,'Part2_Fig_Urel_cube_summary_k2'), cfg.save_png_dpi, cfg.save_png, cfg.save_fig, cfg.close_figs);

    % 3) 立方体绝对不确定度：空间均值/中位数
    sW_abs = reshape(sigma_L_white_k1, [], B);
    sS_abs = reshape(sigma_L_scene_k1, [], B);
    UabsW_mean = cfg.unc_k * mean(sW_abs, 1, 'omitnan');
    UabsS_mean = cfg.unc_k * mean(sS_abs, 1, 'omitnan');
    UabsW_med  = cfg.unc_k * median(sW_abs, 1, 'omitnan');
    UabsS_med  = cfg.unc_k * median(sS_abs, 1, 'omitnan');

    fig = figure('Color','w'); hold on;
    plot(lambda, UabsW_mean, 'LineWidth', 1.8);
    plot(lambda, UabsS_mean, 'LineWidth', 1.8);
    plot(lambda, UabsW_med,  '--', 'LineWidth', 1.4);
    plot(lambda, UabsS_med,  '--', 'LineWidth', 1.4);
    xlabel('Wavelength (nm)');
    ylabel(sprintf('U_{abs}(k=%d) [%s] (spatial summary)', cfg.unc_k, unitL));
    legend({'White mean','Scene mean','White median','Scene median'}, 'Location','best');
    grid on; title(sprintf('第二部分（XXX）：final radiance absolute uncertainty (k=%d)', cfg.unc_k));
    export_fig_png_and_fig(fig, fullfile(figDir,'Part2_Fig_Uabs_cube_summary_k2'), cfg.save_png_dpi, cfg.save_png, cfg.save_fig, cfg.close_figs);

    % 4) 单波段空间图 + 直方图（用 Uabs(k=2)）
    [~, ib] = min(abs(lambda - cfg.plot_band_nm));
    band_nm = lambda(ib);
    Uw_map = cfg.unc_k * sigma_L_white_k1(:,:,ib);
    Us_map = cfg.unc_k * sigma_L_scene_k1(:,:,ib);

    fig = figure('Color','w'); imagesc(Uw_map); axis image; colorbar;
    title(sprintf('White: U_{abs}(k=%d) @ %.1f nm', cfg.unc_k, band_nm));
    xlabel('Samples'); ylabel('Lines');
    export_fig_png_and_fig(fig, fullfile(figDir, sprintf('Part2_Fig_map_Uabs_white_k2_%dnm', round(band_nm))), ...
        cfg.save_png_dpi, cfg.save_png, cfg.save_fig, cfg.close_figs);

    fig = figure('Color','w'); imagesc(Us_map); axis image; colorbar;
    title(sprintf('Scene: U_{abs}(k=%d) @ %.1f nm', cfg.unc_k, band_nm));
    xlabel('Samples'); ylabel('Lines');
    export_fig_png_and_fig(fig, fullfile(figDir, sprintf('Part2_Fig_map_Uabs_scene_k2_%dnm', round(band_nm))), ...
        cfg.save_png_dpi, cfg.save_png, cfg.save_fig, cfg.close_figs);

    fig = figure('Color','w'); hold on;
    histogram(Uw_map(:), 60, 'Normalization','pdf');
    histogram(Us_map(:), 60, 'Normalization','pdf');
    xlabel(sprintf('U_{abs}(k=%d) @ %.1f nm [%s]', cfg.unc_k, band_nm, unitL));
    ylabel('PDF'); legend({'White','Scene'}, 'Location','best');
    grid on; title('Distribution of radiance absolute uncertainty');
    export_fig_png_and_fig(fig, fullfile(figDir, sprintf('Part2_Fig_hist_Uabs_k2_%dnm', round(band_nm))), ...
        cfg.save_png_dpi, cfg.save_png, cfg.save_fig, cfg.close_figs);

    % 5) 点选像元：辐亮度谱 + ±2σ 不确定度带（默认中心像元/ROI中心）
    [rw, cw, roi_note_w] = resolve_roi_pixel(cfg.roi, size(L_white,1), size(L_white,2));
    [rs, cs, roi_note_s] = resolve_roi_pixel(cfg.roi, size(L_scene,1), size(L_scene,2));
    Lw0 = squeeze(L_white(rw,cw,:));
    Sw0 = squeeze(sigma_L_white_k1(rw,cw,:));
    Ls0 = squeeze(L_scene(rs,cs,:));
    Ss0 = squeeze(sigma_L_scene_k1(rs,cs,:));

    fig = figure('Color','w'); hold on;
    fill([lambda; flipud(lambda)], [Lw0-cfg.unc_k*Sw0; flipud(Lw0+cfg.unc_k*Sw0)], ...
        [0.7 0.7 0.7], 'EdgeColor','none', 'FaceAlpha',0.5);
    plot(lambda, Lw0, 'LineWidth', 1.8);
    xlabel('Wavelength (nm)'); ylabel(['Radiance [' unitL ']']);
    title(sprintf('White pixel radiance with ±%dσ band (row=%d, col=%d) %s', cfg.unc_k, rw, cw, roi_note_w));
    grid on;
    export_fig_png_and_fig(fig, fullfile(figDir,'Part2_Fig_white_centerSpectrum_pm2Sigma'), cfg.save_png_dpi, cfg.save_png, cfg.save_fig, cfg.close_figs);

    fig = figure('Color','w'); hold on;
    fill([lambda; flipud(lambda)], [Ls0-cfg.unc_k*Ss0; flipud(Ls0+cfg.unc_k*Ss0)], ...
        [0.7 0.7 0.7], 'EdgeColor','none', 'FaceAlpha',0.5);
    plot(lambda, Ls0, 'LineWidth', 1.8);
    xlabel('Wavelength (nm)'); ylabel(['Radiance [' unitL ']']);
    title(sprintf('Scene pixel radiance with ±%dσ band (row=%d, col=%d) %s', cfg.unc_k, rs, cs, roi_note_s));
    grid on;
    export_fig_png_and_fig(fig, fullfile(figDir,'Part2_Fig_scene_centerSpectrum_pm2Sigma'), cfg.save_png_dpi, cfg.save_png, cfg.save_fig, cfg.close_figs);

    % =========================
    % 两套贡献图
    % =========================
    if cfg.do_dn_contrib_plot
        plot_dn_uncertainty_contributions(cfg, figDir, lambda, DN_white, dnSigW, urel_DN_noise_raw, 'White');
        plot_dn_uncertainty_contributions(cfg, figDir, lambda, DN_scene, dnSigS, urel_DN_noise_raw, 'Scene');
    end
    if cfg.do_L_contrib_plot
        % specCal 不作为直接项：仅通过 sa/sb/cov 体现（符合你要求）
        plot_L_uncertainty_contributions(cfg, figDir, lambda, ...
            DN_white, dnSigW, L_white, ...
            a_matrix, sa_matrix, sb_matrix, cab_matrix, ...
            urel_DN_noise_raw, urel_L_source_k1, ...
            false); % white 无 VZA/VAA

        plot_L_uncertainty_contributions(cfg, figDir, lambda, ...
            DN_scene, dnSigS, L_scene, ...
            a_matrix, sa_matrix, sb_matrix, cab_matrix, ...
            urel_DN_noise_raw, urel_L_source_k1, ...
            true);  % scene 有 VZA/VAA（DN端已包含，L端不再细分角度，只作为DN-prop整体）
    end

    fprintf('✅ 绘图完成：已保存到：%s\n', figDir);
end

%% 10) 可选：转 single 省内存
if cfg.use_single
    L_white = single(L_white);
    sigma_L_white_k1 = single(sigma_L_white_k1);
    u_rel_L_white_k1 = single(u_rel_L_white_k1);
    L_scene = single(L_scene);
    sigma_L_scene_k1 = single(sigma_L_scene_k1);
    u_rel_L_scene_k1 = single(u_rel_L_scene_k1);
end

%% 11) 输出结构体
rad_out = struct();
rad_out.lambda = lambda(:);

[roi_rw, roi_cw] = resolve_roi_pixel(cfg.roi, size(L_white,1), size(L_white,2));
[roi_rs, roi_cs] = resolve_roi_pixel(cfg.roi, size(L_scene,1), size(L_scene,2));
rad_out.roi = struct( ...
    'enable', cfg.roi.enable, ...
    'row', cfg.roi.row, ...
    'col', cfg.roi.col, ...
    'half_size', cfg.roi.half_size, ...
    'bounds', get_roi_bounds(cfg.roi), ...
    'white_pixel', [roi_rw roi_cw], ...
    'scene_pixel', [roi_rs roi_cs]);

rad_out.a_matrix = a_matrix;
rad_out.b_matrix = b_matrix;
rad_out.sigma_a_k1 = sa_matrix;
rad_out.sigma_b_k1 = sb_matrix;
rad_out.cov_ab = cab_matrix;
rad_out.r2_matrix = r2_matrix;

rad_out.L_sigma_ratio = cfg.L_sigma_ratio;
rad_out.L_fit_instr_noise_ratio = cfg.L_fit_instr_noise_ratio;
rad_out.urel_L_sphere_k1 = urel_L_sphere_k1(:);
rad_out.urel_L_specCal_forFit_k1 = urel_L_specCal_forFit_k1(:);
rad_out.urel_L_fit_total_k1 = urel_L_fit_total_k1(:);

rad_out.L_white = L_white;
rad_out.sigma_L_white_k1 = sigma_L_white_k1;
rad_out.u_rel_L_white_k1 = u_rel_L_white_k1;

rad_out.L_scene = L_scene;
rad_out.sigma_L_scene_k1 = sigma_L_scene_k1;
rad_out.u_rel_L_scene_k1 = u_rel_L_scene_k1;

rad_out.urel_L_source_k1  = tmp_urel_L_source_k1;
rad_out.urel_L_specCal_k1  = tmp_urel_L_specCal_k1; % 仅记录：不会直接进 L

rad_out.note = ['第一部分（XXX）=辐射定标不确定度(积分球+光谱定标+仪器噪声=>a,b,sa,sb,cov_ab); ' ...
    '第二部分（XXX）=辐亮度L复原不确定度(a,b参数传播 + DN噪声 + 白板SZA/SAA + 场景SZA/SAA/VZA/VAA + sourceInstab). ' ...
    'specCal is applied ONLY in calibration FIT stage and does NOT appear as a separate direct term on L.'];

%% 12) 保存 MAT
if cfg.save_mat
    outFile = fullfile(cfg.out_dir, 'shapan_RadianceCubes_withUncertainty.mat');
    save(outFile, '-struct', 'rad_out', '-v7.3');
    fprintf('✅ 已保存 MAT：%s\n', outFile);
end

%% 13) 导出 ENVI BIL（辐亮度 & sigma_L）
if cfg.export_envi_bil
    Lw = cast(L_white, cfg.export_dtype);
    Sw = cast(sigma_L_white_k1, cfg.export_dtype);
    Ls = cast(L_scene, cfg.export_dtype);
    Ss = cast(sigma_L_scene_k1, cfg.export_dtype);

    write_envi_bil(Lw, fullfile(cfg.out_dir,'L_white.bil'), lambda);
    write_envi_bil(Sw, fullfile(cfg.out_dir,'sigmaL_white_k1.bil'), lambda);

    write_envi_bil(Ls, fullfile(cfg.out_dir,'shapan_L_scene.bil'), lambda);
    write_envi_bil(Ss, fullfile(cfg.out_dir,'shapan_sigmaL_scene_k1.bil'), lambda);

    fprintf('✅ 已导出 ENVI BIL：L_* 与 sigmaL_* 到 %s\n', cfg.out_dir);
end

fprintf('✅ 全流程完成。\n');
end

%% ======================================================================
% A) 标定相关函数
% ======================================================================
function [lambda, radiances] = load_radiances_excel(excel_file)
if ~isfile(excel_file)
    error('找不到Excel文件：%s', excel_file);
end
M = readmatrix(excel_file);
if size(M,2) < 2
    error('Excel格式不对：至少需要 [lambda, L1, L2, ...]');
end
lambda = M(:,1);
radiances = M(:,2:end); % [bands x cond]
end

function DN_cube = load_dn_cube_from_csv(csv_files, num_pixels, bands, num_conditions)
if numel(csv_files) ~= num_conditions
    error('CSV数量(%d)与Excel亮度条件数(%d)不一致', numel(csv_files), num_conditions);
end
DN_cube = zeros(num_pixels, bands, num_conditions); % [W x B x cond]
for k = 1:num_conditions
    if ~isfile(csv_files{k})
        error('找不到CSV：%s', csv_files{k});
    end
    dn = readmatrix(csv_files{k});
    if ~isequal(size(dn), [num_pixels, bands])
        error('CSV尺寸不匹配：%s，实际=%s，期望=[%d x %d]', csv_files{k}, mat2str(size(dn)), num_pixels, bands);
    end
    DN_cube(:,:,k) = dn;
end
end

function [a_matrix, b_matrix, r2_matrix, sa_matrix, sb_matrix, cab_matrix] = ...
    calculate_coefficients_ols_unc(DN_cube, radiances, urel_L_fit_total_k1, use_parfor)

[W, B, cond] = size(DN_cube);
if size(radiances,1) ~= B || size(radiances,2) ~= cond
    error('radiances尺寸应为 [B x cond]，实际=%s', mat2str(size(radiances)));
end
if numel(urel_L_fit_total_k1) ~= B
    error('urel_L_fit_total_k1 长度=%d，必须等于 bands=%d', numel(urel_L_fit_total_k1), B);
end
urel_L_fit_total_k1 = urel_L_fit_total_k1(:);

a_matrix = zeros(W,B);
b_matrix = zeros(W,B);
r2_matrix = zeros(W,B);
sa_matrix = zeros(W,B);
sb_matrix = zeros(W,B);
cab_matrix= zeros(W,B);

if use_parfor
    parfor band = 1:B %#ok<PFBNS>
        L = radiances(band,:).';
        sigma_L = abs(L) * urel_L_fit_total_k1(band);
        for pix = 1:W
            dn = squeeze(DN_cube(pix, band, :));
            [a,b,R2,sa,sb,cab] = fit_with_uncertainty_ols_cov(dn, L, sigma_L);
            a_matrix(pix,band) = a;
            b_matrix(pix,band) = b;
            r2_matrix(pix,band) = R2;
            sa_matrix(pix,band) = sa;
            sb_matrix(pix,band) = sb;
            cab_matrix(pix,band)= cab;
        end
    end
else
    for band = 1:B
        L = radiances(band,:).';
        sigma_L = abs(L) * urel_L_fit_total_k1(band);
        for pix = 1:W
            dn = squeeze(DN_cube(pix, band, :));
            [a,b,R2,sa,sb,cab] = fit_with_uncertainty_ols_cov(dn, L, sigma_L);
            a_matrix(pix,band) = a;
            b_matrix(pix,band) = b;
            r2_matrix(pix,band) = R2;
            sa_matrix(pix,band) = sa;
            sb_matrix(pix,band) = sb;
            cab_matrix(pix,band)= cab;
        end
    end
end
end

function [a, b, R2, sigma_a, sigma_b, cov_ab] = fit_with_uncertainty_ols_cov(dn, L, sigma_L)
dn = dn(:);
L = L(:);
sigma_L = sigma_L(:);
N = numel(dn);
if numel(L) ~= N || numel(sigma_L) ~= N
    error('fit输入长度不一致');
end
X = [dn, ones(N,1)];
beta = X \ L;
a = beta(1);
b = beta(2);

L_fit = X * beta;
ss_res = sum((L - L_fit).^2);
ss_tot = sum((L - mean(L)).^2);
if ss_tot < 1e-30
    R2 = NaN;
else
    R2 = 1 - ss_res/ss_tot;
end

% 线性传播：Cov_beta = F * diag(sigma_L.^2) * F'
XtX = X' * X;
invXtX = pinv(XtX);
F = invXtX * X';             % 2 x N
F_scaled = F .* (sigma_L.'); % 每列乘 sigma_L(i)
Cov_beta = F_scaled * F_scaled.'; % 2x2
Cov_beta = (Cov_beta + Cov_beta')/2;

sigma_a = sqrt(max(Cov_beta(1,1),0));
sigma_b = sqrt(max(Cov_beta(2,2),0));
cov_ab  = Cov_beta(1,2);
end

%% ======================================================================
% B) DN立方体 -> 辐亮度立方体（含标定参数相关项）
% ======================================================================
function [L_cube, sigmaL_cube, urelL_cube] = dn_cube_to_radiance_cube( ...
    DN, urel_DN_noise_raw, sigmaDN_ang, ...
    a_matrix, b_matrix, sa_matrix, sb_matrix, cab_matrix, block_rows)

[H, W, B] = size(DN);
a3   = reshape(a_matrix,  [1 W B]);
b3   = reshape(b_matrix,  [1 W B]);
sa3  = reshape(sa_matrix, [1 W B]);
sb3  = reshape(sb_matrix, [1 W B]);
cab3 = reshape(cab_matrix,[1 W B]);

urel_DN_noise = expand_to_cube(urel_DN_noise_raw, H, W, B, 'urel_DN_noise');

if ~isequal(size(sigmaDN_ang), [H W B])
    error('sigmaDN_ang尺寸必须为 [H x W x B]，实际=%s', mat2str(size(sigmaDN_ang)));
end

L_cube      = zeros(H,W,B,'like',DN);
sigmaL_cube = zeros(H,W,B,'like',DN);
urelL_cube  = zeros(H,W,B,'like',DN);

if block_rows <= 0
    [L_cube, sigmaL_cube, urelL_cube] = core_compute(DN, urel_DN_noise, sigmaDN_ang, a3, b3, sa3, sb3, cab3);
else
    for r0 = 1:block_rows:H
        r1 = min(H, r0 + block_rows - 1);
        DN_blk   = DN(r0:r1,:,:);
        uN_blk   = urel_DN_noise(r0:r1,:,:);
        sAng_blk = sigmaDN_ang(r0:r1,:,:);
        [L_blk, sL_blk, uL_blk] = core_compute(DN_blk, uN_blk, sAng_blk, a3, b3, sa3, sb3, cab3);
        L_cube(r0:r1,:,:)      = L_blk;
        sigmaL_cube(r0:r1,:,:) = sL_blk;
        urelL_cube(r0:r1,:,:)  = uL_blk;
        fprintf(' - 行块 %d-%d / %d\n', r0, r1, H);
    end
end
end

function [L, sigmaL, urelL] = core_compute(DN, urel_DN_noise, sigmaDN_ang, a3, b3, sa3, sb3, cab3)
L = DN .* a3 + b3;

sigmaDN_noise = urel_DN_noise .* abs(DN);
sigmaDN_tot   = sqrt( sigmaDN_noise.^2 + sigmaDN_ang.^2 );

% 参数项方差： (DN^2)*sa^2 + sb^2 + 2*DN*cov(a,b)
var_param = (DN.^2) .* (sa3.^2) + (sb3.^2) + 2 .* DN .* cab3;

% DN传播项方差： (a^2)*sigmaDN_tot^2
var_DN    = (a3.^2) .* (sigmaDN_tot.^2);

sigmaL2 = max(var_param + var_DN, 0);
sigmaL  = sqrt(sigmaL2);
urelL   = sigmaL ./ max(abs(L), 1e-12);
end

function X3 = expand_to_cube(X, H, W, B, name)
if isscalar(X)
    X3 = repmat(X, [H W B]); return;
end
if isvector(X)
    X = X(:);
    if numel(X)==1
        X3 = repmat(X(1), [H W B]); return;
    end
    if numel(X)==B
        X3 = repmat(reshape(X,[1 1 B]), [H W 1]); return;
    end
end
if ndims(X) == 2
    sz = size(X);
    if isequal(sz, [H W])
        X3 = repmat(X, [1 1 B]); return;
    end
    if isequal(sz, [W 1]) || isequal(sz, [1 W])
        Xv = reshape(X, [1 W 1]);
        X3 = repmat(Xv, [H 1 B]); return;
    end
    if isequal(sz, [W B])
        X3 = repmat(reshape(X, [1 W B]), [H 1 1]); return;
    end
    error('%s 的2D尺寸不支持：%s', name, mat2str(sz));
end
if ndims(X) == 3
    if isequal(size(X), [H W B])
        X3 = X; return;
    end
    if isequal(size(X), [W B H])
        X3 = permute(X, [3 1 2]); return;
    end
    error('%s 的3D尺寸不支持：%s', name, mat2str(size(X)));
end
error('%s 维度不支持（需标量/向量/2D/3D）', name);
end

%% ======================================================================
% 读取谱不确定度 txt，并插值到目标波长（支持 rel/abs）
% ======================================================================
function u_out = load_urel_spectrum_txt(txt_file, lambda_target, tagName, mode)
if nargin < 4 || isempty(mode), mode = 'rel'; end
mode = lower(string(mode));
B = numel(lambda_target);
lambda_target = lambda_target(:);

if isempty(txt_file) || ~isfile(txt_file)
    error('找不到 %s txt：%s', tagName, string(txt_file));
end
M = readmatrix(txt_file);
if isempty(M), error('%s txt 为空：%s', tagName, txt_file); end
M = M(~all(isnan(M),2), :);

if isvector(M)
    v = M(:); v = v(~isnan(v));
    if isempty(v), error('%s txt 全是 NaN：%s', tagName, txt_file); end
    if numel(v) == 1
        u_out = repmat(abs(v(1)), [B 1]);
    elseif numel(v) == B
        u_out = abs(v(:));
    else
        error('%s txt 为向量，但长度=%d，不等于 bands=%d，也不是标量。', tagName, numel(v), B);
    end
else
    if size(M,2) == 1
        v = M(:,1); v = v(~isnan(v));
        if numel(v) == 1
            u_out = repmat(abs(v(1)), [B 1]);
        elseif numel(v) == B
            u_out = abs(v(:));
        else
            error('%s txt 只有1列，但长度=%d，不等于 bands=%d，也不是标量。', tagName, numel(v), B);
        end
    else
        lam = M(:,1); u = M(:,2);
        ok = isfinite(lam) & isfinite(u);
        lam = lam(ok); u = u(ok);
        [lam, idx] = sort(lam(:)); u = u(idx);
        u_out = interp1(lam, u, lambda_target, 'pchip', 'extrap');
        u_out = abs(u_out(:));
    end
end

if mode ~= "rel" && mode ~= "abs"
    error('%s：mode 只能是 rel 或 abs。你给的是 %s', tagName, mode);
end
end

%% ======================================================================
% C) ENVI BIL 读取/写入
% ======================================================================
function cube = read_envi_cube_to_HWB(bil_file, hdr_file)
if ~isfile(bil_file), error('找不到数据文件：%s', bil_file); end
if nargin < 2 || isempty(hdr_file)
    [p,n,~] = fileparts(bil_file);
    hdr_guess = fullfile(p, [n '.hdr']);
    if isfile(hdr_guess), hdr_file = hdr_guess;
    else, error('未提供HDR，且未找到同名HDR：%s', hdr_guess);
    end
end
if ~isfile(hdr_file), error('找不到HDR文件：%s', hdr_file); end

hdr = read_envi_hdr(hdr_file);
samples = hdr.samples;
lines   = hdr.lines;
bands   = hdr.bands;
offset  = hdr.header_offset;
interleave = lower(string(hdr.interleave));

[precision, ~] = envi_dtype_to_matlab(hdr.data_type);
machinefmt = ternary(hdr.byte_order==0, 'ieee-le', 'ieee-be');

fid = fopen(bil_file, 'r', machinefmt);
if fid < 0, error('无法打开：%s', bil_file); end
cleaner = onCleanup(@() fclose(fid)); %#ok<NASGU>

if offset > 0, fseek(fid, offset, 'bof'); end

nElem = double(samples) * double(lines) * double(bands);
raw = fread(fid, nElem, ['*' precision]);
if numel(raw) ~= nElem
    error('读取元素数不够：读到 %d，期望 %d（检查HDR参数/文件是否完整）', numel(raw), nElem);
end

switch interleave
    case "bil"
        raw3 = reshape(raw, [samples, bands, lines]);
        cube = permute(raw3, [3 1 2]); % [lines, samples, bands]
    case "bsq"
        raw3 = reshape(raw, [samples, lines, bands]);
        cube = permute(raw3, [2 1 3]);
    case "bip"
        raw3 = reshape(raw, [bands, samples, lines]);
        cube = permute(raw3, [3 2 1]);
    otherwise
        error('不支持 interleave=%s（仅支持 bil/bsq/bip）', interleave);
end

cube = double(cube);
if isfield(hdr,'data_ignore_value') && ~isempty(hdr.data_ignore_value)
    div = hdr.data_ignore_value;
    cube(cube == div) = NaN;
end
end

function hdr = read_envi_hdr(hdr_file)
txt = fileread(hdr_file);
txt = regexprep(txt, ';\s*.*', '');
lines = regexp(txt, '\r\n|\n|\r', 'split');

hdr = struct();
hdr.header_offset = 0;
hdr.byte_order = 0;

i = 1;
while i <= numel(lines)
    line = strtrim(lines{i}); i = i + 1;
    if isempty(line), continue; end
    if startsWith(lower(line),'envi'), continue; end

    m = regexp(line, '^\s*([^=]+?)\s*=\s*(.*)\s*$', 'tokens', 'once');
    if isempty(m), continue; end
    key = lower(strtrim(m{1}));
    val = strtrim(m{2});

    if startsWith(val, '{') && ~contains(val, '}')
        while i <= numel(lines) && ~contains(lines{i}, '}')
            val = [val ' ' strtrim(lines{i})]; %#ok<AGROW>
            i = i + 1;
        end
        if i <= numel(lines)
            val = [val ' ' strtrim(lines{i})]; %#ok<AGROW>
            i = i + 1;
        end
    end

    if startsWith(val,'{') && endsWith(val,'}')
        inner = strtrim(val(2:end-1));
        hdr.(safe_field(key)) = inner;
        continue;
    end

    val = regexprep(val, '^"(.*)"$', '$1');
    num = str2double(val);
    if ~isnan(num) && isfinite(num)
        hdr.(safe_field(key)) = num;
    else
        hdr.(safe_field(key)) = val;
    end
end

req = {'samples','lines','bands','data_type','interleave'};
for k=1:numel(req)
    if ~isfield(hdr, req{k})
        error('HDR 缺少字段：%s', req{k});
    end
end
if ~isfield(hdr,'header_offset'); hdr.header_offset = 0; end
if ~isfield(hdr,'byte_order'); hdr.byte_order = 0; end
end

function [precision, cls] = envi_dtype_to_matlab(envi_dt)
switch double(envi_dt)
    case 1,  precision='uint8';  cls='uint8';
    case 2,  precision='int16';  cls='int16';
    case 3,  precision='int32';  cls='int32';
    case 4,  precision='single'; cls='single';
    case 5,  precision='double'; cls='double';
    case 12, precision='uint16'; cls='uint16';
    case 13, precision='uint32'; cls='uint32';
    case 14, precision='int64';  cls='int64';
    case 15, precision='uint64'; cls='uint64';
    otherwise, error('不支持 ENVI data type=%d', envi_dt);
end
end

function write_envi_bil(cube_HWB, bil_path, lambda)
[lines, samples, bands] = size(cube_HWB);

if isa(cube_HWB,'single')
    envi_dt = 4; precision = 'single';
elseif isa(cube_HWB,'double')
    envi_dt = 5; precision = 'double';
elseif isa(cube_HWB,'uint16')
    envi_dt = 12; precision = 'uint16';
else
    cube_HWB = single(cube_HWB);
    envi_dt = 4; precision = 'single';
end

raw3 = permute(cube_HWB, [2 3 1]); % [samples, bands, lines]

fid = fopen(bil_path, 'w', 'ieee-le');
if fid < 0, error('无法写入：%s', bil_path); end
cleaner = onCleanup(@() fclose(fid)); %#ok<NASGU>
fwrite(fid, raw3(:), precision);

[p,n,~] = fileparts(bil_path);
hdr_path = fullfile(p, [n '.hdr']);
fid2 = fopen(hdr_path, 'w');
if fid2 < 0, error('无法写HDR：%s', hdr_path); end
cleaner2 = onCleanup(@() fclose(fid2)); %#ok<NASGU>

fprintf(fid2, 'ENVI\n');
fprintf(fid2, 'samples = %d\n', samples);
fprintf(fid2, 'lines = %d\n', lines);
fprintf(fid2, 'bands = %d\n', bands);
fprintf(fid2, 'header offset = 0\n');
fprintf(fid2, 'file type = ENVI Standard\n');
fprintf(fid2, 'data type = %d\n', envi_dt);
fprintf(fid2, 'interleave = bil\n');
fprintf(fid2, 'byte order = 0\n');

if nargin >= 3 && ~isempty(lambda) && numel(lambda) == bands
    fprintf(fid2, 'wavelength = {');
    for k=1:bands
        if k < bands, fprintf(fid2, '%.8g, ', lambda(k));
        else, fprintf(fid2, '%.8g', lambda(k));
        end
    end
    fprintf(fid2, '}\n');
end
end

function f = safe_field(key)
f = regexprep(key, '[^a-zA-Z0-9_]', '_');
end

function out = ternary(cond, a, b)
if cond, out = a; else, out = b; end
end

%% ======================================================================
% 图导出：同时保存 .png + .fig
% ======================================================================
function export_fig_png_and_fig(fig, out_base, dpi, save_png, save_fig, close_figs)
if nargin < 4, save_png = true; end
if nargin < 5, save_fig = true; end
if nargin < 3 || isempty(dpi), dpi = 300; end
if nargin < 6, close_figs = false; end

if save_png
    print(fig, [out_base '.png'], '-dpng', ['-r' num2str(dpi)]);
end
if save_fig
    try
        savefig(fig, [out_base '.fig']);
    catch
        saveas(fig, [out_base '.fig']);
    end
end
if close_figs
    close(fig);
end
end

%% ======================================================================
% DN端贡献图：Noise + SZA/SAA/VZA/VAA
% ======================================================================
function plot_dn_uncertainty_contributions(cfg, figDir, lambda, DN, dnSig, urel_DN_noise_raw, tag)
lambda = lambda(:);
B = numel(lambda);
[H,W,~] = size(DN);
has_v_angles = ~(isempty(dnSig.vza) && isempty(dnSig.vaa));

% 空间均值统计（方差均值）
stats_mean = summarize_dn_var_terms_spatial(DN, dnSig, urel_DN_noise_raw, cfg.contrib_block_rows);

% 单像元（ROI中心/中心像元）
[r0,c0,roi_note] = resolve_roi_pixel(cfg.roi, H, W);
stats_pix = dn_var_terms_single_pixel( ...
    squeeze(DN(r0,c0,:)), ...
    get_dnSig_pixel(dnSig, r0, c0, B), ...
    get_noise_for_pixel(urel_DN_noise_raw, r0, c0, B));

% 1) 方差贡献（空间均值）
outBase = fullfile(figDir, ['Fig_DN_ContribFraction_VarMean_' safe_name(tag)]);
make_stack_fraction_plot_dn(cfg, lambda, stats_mean, cfg.dn_contrib_plot_k, cfg.save_png_dpi, outBase, ...
    sprintf('%s DN variance contribution (spatial mean)', tag), has_v_angles);

% 2) 分量等效 U_abs(DN)（空间均值）
outBase = fullfile(figDir, ['Fig_DN_ContribComponents_UabsMean_' safe_name(tag)]);
make_components_line_plot_dn(cfg, lambda, stats_mean, cfg.dn_contrib_plot_k, cfg.save_png_dpi, outBase, ...
    sprintf('%s DN component-equivalent U_{abs} (k=%d, spatial mean)', tag, cfg.dn_contrib_plot_k), has_v_angles);

% 3) 方差贡献（单像元）
outBase = fullfile(figDir, ['Fig_DN_ContribFraction_VarPoint_' safe_name(tag)]);
make_stack_fraction_plot_dn(cfg, lambda, stats_pix, cfg.dn_contrib_plot_k, cfg.save_png_dpi, outBase, ...
    sprintf('%s DN variance contribution (pixel r=%d,c=%d) %s', tag, r0, c0, roi_note), has_v_angles);

% 4) 分量等效 U_abs(DN)（单像元）
outBase = fullfile(figDir, ['Fig_DN_ContribComponents_UabsPoint_' safe_name(tag)]);
make_components_line_plot_dn(cfg, lambda, stats_pix, cfg.dn_contrib_plot_k, cfg.save_png_dpi, outBase, ...
    sprintf('%s DN component-equivalent U_{abs} (k=%d) %s', tag, cfg.dn_contrib_plot_k, roi_note), has_v_angles);
end

function stats = summarize_dn_var_terms_spatial(DN, dnSig, urel_DN_noise_raw, block_rows)
[H,W,B] = size(DN);
if block_rows <= 0, block_rows = 200; end

sum_vnoise = zeros(B,1);
sum_vsza   = zeros(B,1);
sum_vsaa   = zeros(B,1);
sum_vvza   = zeros(B,1);
sum_vvaa   = zeros(B,1);
cnt        = zeros(B,1);

for rr0 = 1:block_rows:H
    rr1 = min(H, rr0+block_rows-1);
    DNblk = DN(rr0:rr1,:,:);
    nR = size(DNblk,1);

    uNblk = get_noise_block(urel_DN_noise_raw, rr0, rr1, 1, W, B, size(DNblk));
    sigma_noise = uNblk .* abs(DNblk);
    v_noise = sigma_noise.^2;

    sza = get_dnSig_block(dnSig.sza, rr0, rr1, 1, W, B, nR);
    saa = get_dnSig_block(dnSig.saa, rr0, rr1, 1, W, B, nR);
    vza = get_dnSig_block(dnSig.vza, rr0, rr1, 1, W, B, nR);
    vaa = get_dnSig_block(dnSig.vaa, rr0, rr1, 1, W, B, nR);

    v_sza = sza.^2; v_saa = saa.^2; v_vza = vza.^2; v_vaa = vaa.^2;

    [sum_vnoise, cnt] = acc_band_sum(v_noise, sum_vnoise, cnt);
    [sum_vsza,   ~]   = acc_band_sum(v_sza,   sum_vsza,   cnt);
    [sum_vsaa,  ~]    = acc_band_sum(v_saa,  sum_vsaa,  cnt);
    [sum_vvza,  ~]    = acc_band_sum(v_vza,  sum_vvza,  cnt);
    [sum_vvaa,  ~]    = acc_band_sum(v_vaa,  sum_vvaa,  cnt);
end

stats.v_noise = sum_vnoise ./ max(cnt,1);
stats.v_sza   = sum_vsza   ./ max(cnt,1);
stats.v_saa   = sum_vsaa   ./ max(cnt,1);
stats.v_vza   = sum_vvza   ./ max(cnt,1);
stats.v_vaa   = sum_vvaa   ./ max(cnt,1);

stats.v_sum_for_fraction = stats.v_noise + stats.v_sza + stats.v_saa + stats.v_vza + stats.v_vaa;
stats.v_sum_for_fraction(stats.v_sum_for_fraction<=0) = NaN;

absDN = abs(DN);
stats.ref_abs = reshape(mean(reshape(absDN, [], B), 1, 'omitnan'), [B,1]); % 空间均值 |DN|
stats.ref_abs(stats.ref_abs<=0) = NaN;
end

function stats = dn_var_terms_single_pixel(DNvec, dnSigPix, urel_noise_vec)
DNvec = DNvec(:);
sigma_noise = urel_noise_vec(:) .* abs(DNvec);
stats.v_noise = sigma_noise.^2;
stats.v_sza   = dnSigPix.sza(:).^2;
stats.v_saa   = dnSigPix.saa(:).^2;
stats.v_vza   = dnSigPix.vza(:).^2;
stats.v_vaa   = dnSigPix.vaa(:).^2;
stats.v_sum_for_fraction = stats.v_noise + stats.v_sza + stats.v_saa + stats.v_vza + stats.v_vaa;
stats.v_sum_for_fraction(stats.v_sum_for_fraction<=0) = NaN;
stats.ref_abs = abs(DNvec);
stats.ref_abs(stats.ref_abs<=0) = NaN;
end

function make_stack_fraction_plot_dn(cfg, lambda, stats, k, dpi, outBase, ttl, has_v_angles) %#ok<INUSD>
if has_v_angles
    frac = [ ...
        stats.v_noise ./ stats.v_sum_for_fraction, ...
        stats.v_sza   ./ stats.v_sum_for_fraction, ...
        stats.v_saa   ./ stats.v_sum_for_fraction, ...
        stats.v_vza   ./ stats.v_sum_for_fraction, ...
        stats.v_vaa   ./ stats.v_sum_for_fraction ...
        ];
    lgd = {'Noise','SZA','SAA','VZA','VAA'};
else
    frac = [ ...
        stats.v_noise ./ stats.v_sum_for_fraction, ...
        stats.v_sza   ./ stats.v_sum_for_fraction, ...
        stats.v_saa   ./ stats.v_sum_for_fraction ...
        ];
    lgd = {'Noise','SZA','SAA'};
end
frac = 100*frac;

fig = figure('Color','w');
area(lambda, frac, 'LineStyle','none'); grid on;
xlabel('Wavelength (nm)');
ylabel('Variance contribution on DN (%)');
title(ttl);
legend(lgd, 'Location','best');
export_fig_png_and_fig(fig, outBase, dpi, cfg.save_png, cfg.save_fig, cfg.close_figs);
end

function make_components_line_plot_dn(cfg, lambda, stats, k, dpi, outBase, ttl, has_v_angles)
U_noise = k*sqrt(max(stats.v_noise,0));
U_sza   = k*sqrt(max(stats.v_sza,0));
U_saa   = k*sqrt(max(stats.v_saa,0));
U_vza   = k*sqrt(max(stats.v_vza,0));
U_vaa   = k*sqrt(max(stats.v_vaa,0));
U_tot   = k*sqrt(max(stats.v_sum_for_fraction,0));

fig = figure('Color','w'); hold on;
plot(lambda, U_noise, 'LineWidth', 1.6);
plot(lambda, U_sza,   'LineWidth', 1.6);
plot(lambda, U_saa,   'LineWidth', 1.6);
if has_v_angles
    plot(lambda, U_vza,   'LineWidth', 1.6);
    plot(lambda, U_vaa,   'LineWidth', 1.6);
end
plot(lambda, U_tot,   'k--', 'LineWidth', 1.4);
grid on;
xlabel('Wavelength (nm)');
ylabel(sprintf('U_{abs} on DN (k=%d)', k));
title(ttl);
if has_v_angles
    legend({'Noise','SZA','SAA','VZA','VAA','Total'}, 'Location','best');
else
    legend({'Noise','SZA','SAA','Total'}, 'Location','best');
end
export_fig_png_and_fig(fig, outBase, dpi, cfg.save_png, cfg.save_fig, cfg.close_figs);

% 额外输出：相对不确定度分量等效曲线（相对于 |DN|）
ref = stats.ref_abs(:);
U_noise_rel = 100 * U_noise ./ ref;
U_sza_rel   = 100 * U_sza   ./ ref;
U_saa_rel   = 100 * U_saa   ./ ref;
U_vza_rel   = 100 * U_vza   ./ ref;
U_vaa_rel   = 100 * U_vaa   ./ ref;
U_tot_rel   = 100 * U_tot   ./ ref;

fig = figure('Color','w'); hold on;
plot(lambda, U_noise_rel, 'LineWidth', 1.6);
plot(lambda, U_sza_rel,   'LineWidth', 1.6);
plot(lambda, U_saa_rel,   'LineWidth', 1.6);
if has_v_angles
    plot(lambda, U_vza_rel,   'LineWidth', 1.6);
    plot(lambda, U_vaa_rel,   'LineWidth', 1.6);
end
plot(lambda, U_tot_rel,   'k--', 'LineWidth', 1.4);
grid on;
xlabel('Wavelength (nm)');
ylabel(sprintf('U_{rel} on DN (k=%d, %%)', k));
ylim([0 100]);
title([ttl ' [Relative]']);
if has_v_angles
    legend({'Noise','SZA','SAA','VZA','VAA','Total'}, 'Location','best');
else
    legend({'Noise','SZA','SAA','Total'}, 'Location','best');
end
export_fig_png_and_fig(fig, [outBase '_rel'], dpi, cfg.save_png, cfg.save_fig, cfg.close_figs);
end

function dnSigPix = get_dnSig_pixel(dnSig, r, c, B)
dnSigPix.sza = get_dnSig_vec(dnSig.sza, r, c, B);
dnSigPix.saa = get_dnSig_vec(dnSig.saa, r, c, B);
dnSigPix.vza = get_dnSig_vec(dnSig.vza, r, c, B);
dnSigPix.vaa = get_dnSig_vec(dnSig.vaa, r, c, B);
end

function v = get_dnSig_vec(src, r, c, B)
if isempty(src), v = zeros(B,1); return; end
if ndims(src)==3, v = squeeze(src(r,c,:)); return; end
if ndims(src)==2, v = repmat(src(r,c), [B 1]); return; end
v = zeros(B,1);
end

function cube = get_dnSig_block(src, rr0, rr1, c0, c1, B, nR)
nC = c1-c0+1;
if isempty(src), cube = zeros(nR, nC, B); return; end
if ndims(src)==3, cube = src(rr0:rr1, c0:c1, :); return; end
if ndims(src)==2, cube = repmat(src(rr0:rr1, c0:c1), [1 1 B]); return; end
cube = zeros(nR, nC, B);
end

%% ======================================================================
% L端贡献图：DN-prop + a-fit + b-fit + |cov(a,b)| + sourceInstab
% （specCal 不作为直接项，符合你要求）
% ======================================================================
function plot_L_uncertainty_contributions(cfg, figDir, lambda, ...
    DN, dnSig, L, ...
    a_matrix, sa_matrix, sb_matrix, cab_matrix, ...
    urel_DN_noise_raw, urel_source_k1, include_v_angles)

lambda = lambda(:);
B = numel(lambda);
[H,W,~] = size(DN);

stats_mean = summarize_L_var_terms_spatial( ...
    DN, dnSig, L, ...
    a_matrix, sa_matrix, sb_matrix, cab_matrix, ...
    urel_DN_noise_raw, urel_source_k1, cfg.contrib_block_rows);

[r0,c0,roi_note] = resolve_roi_pixel(cfg.roi, H, W);

pix = L_var_terms_single_pixel( ...
    squeeze(DN(r0,c0,:)), get_dnSig_pixel(dnSig, r0, c0, B), squeeze(L(r0,c0,:)), ...
    squeeze(a_matrix(c0,:)).', squeeze(sa_matrix(c0,:)).', squeeze(sb_matrix(c0,:)).', squeeze(cab_matrix(c0,:)).', ...
    get_noise_for_pixel(urel_DN_noise_raw, r0, c0, B), ...
    urel_source_k1(:));

tag = ternary(include_v_angles, 'Scene', 'White');

outBase = fullfile(figDir, ['Fig_L_ContribFraction_VarMean_' tag]);
make_stack_fraction_plot_L(cfg, lambda, stats_mean, cfg.L_contrib_plot_k, cfg.save_png_dpi, outBase, ...
    sprintf('%s L variance contribution (spatial mean)', tag));

outBase = fullfile(figDir, ['Fig_L_ContribComponents_UabsMean_' tag]);
make_components_line_plot_L(cfg, lambda, stats_mean, cfg.L_contrib_plot_k, cfg.save_png_dpi, outBase, ...
    sprintf('%s L component-equivalent U_{abs} (k=%d, spatial mean)', tag, cfg.L_contrib_plot_k));

outBase = fullfile(figDir, ['Fig_L_ContribFraction_VarPoint_' tag]);
make_stack_fraction_plot_L(cfg, lambda, pix, cfg.L_contrib_plot_k, cfg.save_png_dpi, outBase, ...
    sprintf('%s L variance contribution (pixel r=%d,c=%d) %s', tag, r0, c0, roi_note));

outBase = fullfile(figDir, ['Fig_L_ContribComponents_UabsPoint_' tag]);
make_components_line_plot_L(cfg, lambda, pix, cfg.L_contrib_plot_k, cfg.save_png_dpi, outBase, ...
    sprintf('%s L component-equivalent U_{abs} (k=%d) %s', tag, cfg.L_contrib_plot_k, roi_note));
end

function stats = summarize_L_var_terms_spatial( ...
    DN, dnSig, L, ...
    a_matrix, sa_matrix, sb_matrix, cab_matrix, ...
    urel_DN_noise_raw, urel_source_k1, block_rows)

[H,W,B] = size(DN);
if block_rows <= 0, block_rows = 200; end

a3   = reshape(a_matrix,  [1 W B]);
sa3  = reshape(sa_matrix, [1 W B]);
sb3  = reshape(sb_matrix, [1 W B]);
cab3 = reshape(cab_matrix,[1 W B]);

urel_source_k1 = urel_source_k1(:);

sum_va=zeros(B,1); sum_vb=zeros(B,1); sum_vcov=zeros(B,1);
sum_vDN=zeros(B,1); sum_vsrc=zeros(B,1);
cnt=zeros(B,1);

for rr0 = 1:block_rows:H
    rr1 = min(H, rr0+block_rows-1);
    DNblk = DN(rr0:rr1,:,:);
    Lblk  = L(rr0:rr1,:,:);
    nR = size(DNblk,1);

    % DN总sigma
    uNblk = get_noise_block(urel_DN_noise_raw, rr0, rr1, 1, W, B, size(DNblk));
    sigma_noise = uNblk .* abs(DNblk);

    sza = get_dnSig_block(dnSig.sza, rr0, rr1, 1, W, B, nR);
    saa = get_dnSig_block(dnSig.saa, rr0, rr1, 1, W, B, nR);
    vza = get_dnSig_block(dnSig.vza, rr0, rr1, 1, W, B, nR);
    vaa = get_dnSig_block(dnSig.vaa, rr0, rr1, 1, W, B, nR);

    sigmaDN_tot = sqrt( sigma_noise.^2 + sza.^2 + saa.^2 + vza.^2 + vaa.^2 );

    aR   = repmat(a3,   [nR 1 1]);
    saR  = repmat(sa3,  [nR 1 1]);
    sbR  = repmat(sb3,  [nR 1 1]);
    cabR = repmat(cab3, [nR 1 1]);

    v_a   = (DNblk.^2) .* (saR.^2);
    v_b   = (sbR.^2);
    v_cov = 2 .* DNblk .* cabR;
    v_DN  = (aR.^2) .* (sigmaDN_tot.^2);

    uSrc = repmat(reshape(urel_source_k1,[1 1 B]), [nR W 1]);
    v_src = (uSrc .* abs(Lblk)).^2;

    [sum_va,cnt] = acc_band_sum(v_a,   sum_va,   cnt);
    [sum_vb,~]   = acc_band_sum(v_b,   sum_vb,   cnt);
    [sum_vcov,~] = acc_band_sum(v_cov, sum_vcov, cnt);
    [sum_vDN,~]  = acc_band_sum(v_DN,  sum_vDN,  cnt);
    [sum_vsrc,~] = acc_band_sum(v_src, sum_vsrc, cnt);
end

stats.v_a = sum_va ./ max(cnt,1);
stats.v_b = sum_vb ./ max(cnt,1);
stats.v_cov_signed = sum_vcov ./ max(cnt,1);
stats.v_cov_mag    = abs(stats.v_cov_signed);
stats.v_DN = sum_vDN ./ max(cnt,1);
stats.v_source = sum_vsrc ./ max(cnt,1);

stats.v_sum_for_fraction = stats.v_DN + stats.v_a + stats.v_b + stats.v_source + stats.v_cov_mag;
stats.v_sum_for_fraction(stats.v_sum_for_fraction<=0) = NaN;

stats.ref_abs = reshape(mean(reshape(abs(L), [], B), 1, 'omitnan'), [B,1]); % 空间均值 |L|
stats.ref_abs(stats.ref_abs<=0) = NaN;
end

function stats = L_var_terms_single_pixel( ...
    DNvec, dnSigPix, Lvec, a, sa, sb, cab, urel_noise, urel_source)

DNvec = DNvec(:); Lvec = Lvec(:);
a=a(:); sa=sa(:); sb=sb(:); cab=cab(:);

sigma_noise = urel_noise(:) .* abs(DNvec);
sigmaDN_tot = sqrt( sigma_noise.^2 + dnSigPix.sza(:).^2 + dnSigPix.saa(:).^2 + dnSigPix.vza(:).^2 + dnSigPix.vaa(:).^2 );

stats.v_a = (DNvec.^2) .* (sa.^2);
stats.v_b = (sb.^2);
stats.v_cov_signed = 2 .* DNvec .* cab;
stats.v_cov_mag    = abs(stats.v_cov_signed);
stats.v_DN = (a.^2) .* (sigmaDN_tot.^2);

stats.v_source = (urel_source(:) .* abs(Lvec)).^2;

stats.v_sum_for_fraction = stats.v_DN + stats.v_a + stats.v_b + stats.v_source + stats.v_cov_mag;
stats.v_sum_for_fraction(stats.v_sum_for_fraction<=0) = NaN;
stats.ref_abs = abs(Lvec);
stats.ref_abs(stats.ref_abs<=0) = NaN;
end

function make_stack_fraction_plot_L(cfg, lambda, stats, k, dpi, outBase, ttl)
frac = [ ...
    stats.v_DN ./ stats.v_sum_for_fraction, ...
    stats.v_a  ./ stats.v_sum_for_fraction, ...
    stats.v_b  ./ stats.v_sum_for_fraction, ...
    stats.v_source ./ stats.v_sum_for_fraction, ...
    stats.v_cov_mag ./ stats.v_sum_for_fraction ...
    ];
frac = 100*frac;

fig = figure('Color','w');
area(lambda, frac, 'LineStyle','none'); grid on;
xlabel('Wavelength (nm)');
ylabel('Variance contribution on L (%)');
title({ttl; 'Stack uses |cov(a,b)|; signed cov fraction is overlaid as a line.'});
hold on;
plot(lambda, 100*(stats.v_cov_signed./stats.v_sum_for_fraction), 'k-', 'LineWidth', 1.2);

legend({'DN-prop','a-fit','b-fit','SourceInstab','|cov(a,b)|','cov(a,b) signed'}, 'Location','best');
export_fig_png_and_fig(fig, outBase, dpi, cfg.save_png, cfg.save_fig, cfg.close_figs);
end

function make_components_line_plot_L(cfg, lambda, stats, k, dpi, outBase, ttl)
U_DN   = k*sqrt(max(stats.v_DN,0));
U_a    = k*sqrt(max(stats.v_a,0));
U_b    = k*sqrt(max(stats.v_b,0));
U_src  = k*sqrt(max(stats.v_source,0));
U_covm = k*sqrt(max(stats.v_cov_mag,0));
U_tot  = k*sqrt(max(stats.v_sum_for_fraction,0));

fig = figure('Color','w'); hold on;
plot(lambda, U_DN,   'LineWidth', 1.6);
plot(lambda, U_a,    'LineWidth', 1.6);
plot(lambda, U_b,    'LineWidth', 1.6);
plot(lambda, U_src,  'LineWidth', 1.6);
plot(lambda, U_covm, 'LineWidth', 1.6);
plot(lambda, U_tot,  'k--', 'LineWidth', 1.4);
grid on;
xlabel('Wavelength (nm)');
ylabel(sprintf('Component equivalent U_{abs} on L (k=%d)', k));
title(ttl);
legend({'DN-prop','a-fit','b-fit','SourceInstab','|cov(a,b)|','Total'}, 'Location','best');
export_fig_png_and_fig(fig, outBase, dpi, cfg.save_png, cfg.save_fig, cfg.close_figs);

% 额外输出：相对不确定度分量等效曲线（相对于 |L|）
ref = stats.ref_abs(:);
U_DN_rel   = 100 * U_DN   ./ ref;
U_a_rel    = 100 * U_a    ./ ref;
U_b_rel    = 100 * U_b    ./ ref;
U_src_rel  = 100 * U_src  ./ ref;
U_covm_rel = 100 * U_covm ./ ref;
U_tot_rel  = 100 * U_tot  ./ ref;

fig = figure('Color','w'); hold on;
plot(lambda, U_DN_rel,   'LineWidth', 1.6);
plot(lambda, U_a_rel,    'LineWidth', 1.6);
plot(lambda, U_b_rel,    'LineWidth', 1.6);
plot(lambda, U_src_rel,  'LineWidth', 1.6);
plot(lambda, U_covm_rel, 'LineWidth', 1.6);
plot(lambda, U_tot_rel,  'k--', 'LineWidth', 1.4);
grid on;
xlabel('Wavelength (nm)');
ylabel(sprintf('Component equivalent U_{rel} on L (k=%d, %%)', k));
ylim([0 100]);
title([ttl ' [Relative]']);
legend({'DN-prop','a-fit','b-fit','SourceInstab','|cov(a,b)|','Total'}, 'Location','best');
export_fig_png_and_fig(fig, [outBase '_rel'], dpi, cfg.save_png, cfg.save_fig, cfg.close_figs);
end

function s = safe_name(t)
s = regexprep(t, '[^a-zA-Z0-9_]+', '_');
end

%% ======================================================================
% 累积：按波段统计 sum 与 count（用于空间均值）
% ======================================================================
function [sumv, cntv] = acc_band_sum(v, sumv, cntv)
tmp = v;
m = isfinite(tmp);
tmp(~m) = 0;
sv = squeeze(sum(sum(tmp,1),2));
cv = squeeze(sum(sum(m,1),2));
sumv = sumv + sv(:);
cntv = cntv + cv(:);
end

function uNblk = get_noise_block(urel_raw, rr0, rr1, c0, c1, B, szBlk)
nR = szBlk(1); nC = szBlk(2);

if isscalar(urel_raw)
    uNblk = repmat(urel_raw, [nR nC B]); return;
end
if ndims(urel_raw)==3
    uNblk = urel_raw(rr0:rr1, c0:c1, :); return;
end
if ndims(urel_raw)==2
    u2 = urel_raw(rr0:rr1, c0:c1);
    uNblk = repmat(u2, [1 1 B]); return;
end
uNblk = repmat(mean(urel_raw(:),'omitnan'), [nR nC B]);
end

function urel_noise_vec = get_noise_for_pixel(urel_raw, r, c, B)
if isscalar(urel_raw)
    urel_noise_vec = repmat(urel_raw, [B 1]);
elseif ndims(urel_raw)==3
    urel_noise_vec = squeeze(urel_raw(r,c,:));
elseif ndims(urel_raw)==2
    urel_noise_vec = repmat(urel_raw(r,c), [B 1]);
else
    urel_noise_vec = repmat(mean(urel_raw(:),'omitnan'), [B 1]);
end
urel_noise_vec = urel_noise_vec(:);
end

%% ======================================================================
% ROI 交互与工具
% ======================================================================
function cfg = configure_roi_for_plot(cfg, L_white, L_scene, lambda)
if ~cfg.do_plot, return; end
if ~isfield(cfg, 'plot_mode') || isempty(cfg.plot_mode), cfg.plot_mode = 'full'; end

if strcmpi(cfg.plot_mode, 'roi')
    if isempty(cfg.plot_roi)
        if cfg.roi_select_interactive
            cfg.plot_roi = select_roi_interactive(cfg, L_white, L_scene, lambda);
        else
            error('plot_mode=roi 但没有提供 cfg.plot_roi，也未启用交互选择');
        end
    end
    cfg.roi = convert_plot_roi_to_roi(cfg.plot_roi, cfg.roi);
    cfg.roi.enable = true;

elseif strcmpi(cfg.plot_mode, 'point')
    if cfg.roi_select_interactive
        [r, c] = select_point_interactive(cfg, L_white, L_scene, lambda);
        cfg.plot_roi = [r r c c];
    elseif isempty(cfg.plot_roi)
        error('plot_mode=point 但未启用交互选择，也没有 cfg.plot_roi');
    end
    cfg.roi = convert_plot_roi_to_roi(cfg.plot_roi, cfg.roi);
    cfg.roi.enable = true;
end
end

function plot_roi = select_roi_interactive(cfg, L_white, L_scene, lambda)
preview = pick_preview_cube(cfg, L_white, L_scene);
[~, ib] = min(abs(lambda - cfg.preview_band_nm));
img = preview(:,:,ib);
fig = figure('Color','w');
imagesc(img); axis image; colorbar;
title(sprintf('ROI select @ %.1f nm (%s)', lambda(ib), cfg.preview_what));
xlabel('Samples'); ylabel('Lines');
hold on;
disp('双击一个点=单点ROI；按住鼠标拖拽=矩形ROI');
setappdata(fig, 'roi_result', []);
setappdata(fig, 'roi_axes', gca);
set(fig, 'WindowButtonDownFcn', @(src, evt) roi_click_callback(src, cfg, size(img))); %#ok<INUSD>
uiwait(fig);
result = getappdata(fig, 'roi_result');
if isempty(result)
    if isvalid(fig), close(fig); end
    error('未选择 ROI');
end
plot_roi = result.plot_roi;
if cfg.close_figs && isvalid(fig), close(fig); end
end

function [r, c] = select_point_interactive(cfg, L_white, L_scene, lambda)
preview = pick_preview_cube(cfg, L_white, L_scene);
[~, ib] = min(abs(lambda - cfg.preview_band_nm));
img = preview(:,:,ib);
fig = figure('Color','w');
imagesc(img); axis image; colorbar;
title(sprintf('Point select @ %.1f nm (%s)', lambda(ib), cfg.preview_what));
xlabel('Samples'); ylabel('Lines');
hold on;
disp('双击一个像元选择单点');
setappdata(fig, 'roi_result', []);
setappdata(fig, 'roi_axes', gca);
set(fig, 'WindowButtonDownFcn', @(src, evt) point_click_callback(src, size(img))); %#ok<INUSD>
uiwait(fig);
result = getappdata(fig, 'roi_result');
if isempty(result)
    if isvalid(fig), close(fig); end
    error('未选择像元');
end
plot_roi = result.plot_roi;
r = plot_roi(1);
c = plot_roi(3);
if cfg.close_figs && isvalid(fig), close(fig); end
end

function roi_click_callback(fig, cfg, img_size)
ax = getappdata(fig, 'roi_axes');
if isempty(ax) || ~isvalid(ax), return; end
sel = get(fig, 'SelectionType');
cp = get(ax, 'CurrentPoint');
x1 = cp(1,1);
y1 = cp(1,2);
if strcmp(sel, 'open')
    if ~cfg.roi_allow_point, return; end
    plot_roi = [round(y1) round(y1) round(x1) round(x1)];
else
    rbbox;
    cp2 = get(ax, 'CurrentPoint');
    x2 = cp2(1,1);
    y2 = cp2(1,2);
    plot_roi = [round(min(y1,y2)) round(max(y1,y2)) round(min(x1,x2)) round(max(x1,x2))];
end
plot_roi = sanitize_plot_roi(plot_roi, img_size(1), img_size(2));
rectangle('Parent', ax, 'Position', [plot_roi(3), plot_roi(1), plot_roi(4)-plot_roi(3)+1, plot_roi(2)-plot_roi(1)+1], ...
    'EdgeColor', 'r', 'LineWidth', 1.2);
drawnow;
setappdata(fig, 'roi_result', struct('plot_roi', plot_roi));
uiresume(fig);
end

function point_click_callback(fig, img_size)
ax = getappdata(fig, 'roi_axes');
if isempty(ax) || ~isvalid(ax), return; end
sel = get(fig, 'SelectionType');
if ~strcmp(sel, 'open'), return; end
cp = get(ax, 'CurrentPoint');
x1 = cp(1,1);
y1 = cp(1,2);
plot_roi = [round(y1) round(y1) round(x1) round(x1)];
plot_roi = sanitize_plot_roi(plot_roi, img_size(1), img_size(2));
rectangle('Parent', ax, 'Position', [plot_roi(3), plot_roi(1), 1, 1], ...
    'EdgeColor', 'r', 'LineWidth', 1.2);
drawnow;
setappdata(fig, 'roi_result', struct('plot_roi', plot_roi));
uiresume(fig);
end

function roi = convert_plot_roi_to_roi(plot_roi, roi)
if nargin < 2 || isempty(roi), roi = struct(); end
if numel(plot_roi) ~= 4
    error('plot_roi 必须是 [r0 r1 c0 c1] 或 [r r c c]');
end
roi.bounds = round(plot_roi(:)).';
roi.row = [];
roi.col = [];
roi.half_size = 0;
end

function plot_roi = sanitize_plot_roi(plot_roi, H, W)
r0 = max(1, min(H, plot_roi(1)));
r1 = max(1, min(H, plot_roi(2)));
c0 = max(1, min(W, plot_roi(3)));
c1 = max(1, min(W, plot_roi(4)));
if r0 > r1, tmp = r0; r0 = r1; r1 = tmp; end
if c0 > c1, tmp = c0; c0 = c1; c1 = tmp; end
plot_roi = [r0 r1 c0 c1];
end

function preview = pick_preview_cube(cfg, L_white, L_scene)
if isfield(cfg, 'preview_what') && strcmpi(cfg.preview_what, 'L_white')
    preview = L_white;
else
    preview = L_scene;
end
end

function bounds = get_roi_bounds(roi)
if isfield(roi, 'bounds') && ~isempty(roi.bounds)
    bounds = roi.bounds;
else
    bounds = [];
end
end

function text = format_roi_bounds(cfg)
if isfield(cfg, 'plot_roi') && ~isempty(cfg.plot_roi)
    b = cfg.plot_roi;
elseif isfield(cfg, 'roi') && isfield(cfg.roi, 'bounds') && ~isempty(cfg.roi.bounds)
    b = cfg.roi.bounds;
else
    text = '[not set]';
    return;
end
text = sprintf('[%d %d %d %d] (r0 r1 c0 c1)', b(1), b(2), b(3), b(4));
end

function [r, c, note] = resolve_roi_pixel(roi, H, W)
if ~isfield(roi, 'enable') || ~roi.enable
    r = round(H/2); c = round(W/2);
    note = '(center)'; return;
end
if isfield(roi, 'bounds') && ~isempty(roi.bounds)
    b = roi.bounds;
    r = round((b(1) + b(2)) / 2);
    c = round((b(3) + b(4)) / 2);
    r = min(max(r, 1), H);
    c = min(max(c, 1), W);
    note = sprintf('[ROI r%d-%d c%d-%d]', b(1), b(2), b(3), b(4));
    return;
end
r = roi.row; c = roi.col;
if isempty(r), r = round(H/2); end
if isempty(c), c = round(W/2); end
r = min(max(round(r), 1), H);
c = min(max(round(c), 1), W);
hs = 0;
if isfield(roi, 'half_size') && ~isempty(roi.half_size)
    hs = max(round(roi.half_size), 0);
end
note = sprintf('[ROI hs=%d]', hs);
end

function roi_cube = extract_roi_cube(cube, roi)
[H, W, ~] = size(cube);
if isfield(roi, 'bounds') && ~isempty(roi.bounds)
    b = roi.bounds;
    r0 = max(1, b(1)); r1 = min(H, b(2));
    c0 = max(1, b(3)); c1 = min(W, b(4));
else
    [r, c] = resolve_roi_pixel(roi, H, W);
    hs = 0;
    if isfield(roi, 'half_size') && ~isempty(roi.half_size)
        hs = max(round(roi.half_size), 0);
    end
    r0 = max(1, r - hs); r1 = min(H, r + hs);
    c0 = max(1, c - hs); c1 = min(W, c + hs);
end
roi_cube = cube(r0:r1, c0:c1, :);
end
