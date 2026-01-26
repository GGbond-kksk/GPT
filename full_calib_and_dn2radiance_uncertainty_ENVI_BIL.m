function rad_out = full_calib_and_dn2radiance_uncertainty_ENVI_BIL()
%% 一键跑完（完整可运行版）：积分球辐射定标 -> 读ENVI BIL DN/角度不确定度 -> 辐亮度立方体 + 不确定度立方体(k=1)
% ✅ 额外新增：
%   1) 自动输出“贡献图”（方差预算占比堆叠 + 分量等效Uabs曲线 + 中心像元版本）
%   2) 所有图同时保存 .png + .fig（按你最新要求）
% ❌ 不用 ROI（全图统计）
%
% 运行方式：
%   rad_out = full_calib_and_dn2radiance_uncertainty_ENVI_BIL();

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
cfg.L_sigma_ratio = 0.02;  % 积分球辐亮度相对标准不确定度（用于拟合 a,b 的权重传播）
cfg.use_parfor    = false;

% ========== B) DN/不确定度立方体所在目录（默认：本 .m 文件目录）==========
thisFile = mfilename('fullpath');
thisDir  = fileparts(thisFile);
cfg.cube_dir = thisDir; % ✅ 自动取本文件所在文件夹

% ---------- 白板/场景 DN：ENVI BIL ----------
cfg.white_dn_bil = fullfile(cfg.cube_dir, '01sun70+1_diff_SZAx_VZA0_VAA177_1-1_registered_registered.bil'); % TODO
cfg.white_dn_hdr = ''; % 留空则自动推断同名 .hdr
cfg.scene_dn_bil = fullfile(cfg.cube_dir, 'sun70+1_shapan_SZAx_VZA0_VAA177_1-1_registered_registered.bil'); % TODO
cfg.scene_dn_hdr = '';

% ---------- DN噪声相对不确定度(k=1) ----------
cfg.urel_DN_noise = 0.01; % 可为标量或cube（如有bil也支持：cfg.urel_DN_noise_bil / cfg.urel_DN_noise_hdr）

% ---------- 白板角度不确定度（对DN的相对标准不确定度k=1） ----------
cfg.white_sza_bil = fullfile(cfg.cube_dir, 'DIFF_SAAx_RRMSE_mean_cube_registered.bil');
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

% ---------- 直接作用在L上的不确定度（相对u_rel,k=1） ----------
cfg.urel_L_spectralCal_txt = fullfile(cfg.cube_dir, 'urel_L_spectralCal_fromMC.txt'); % TODO
cfg.urel_L_sourceInstab_txt= fullfile(cfg.cube_dir, 'urel_L_sourceInstab_rel.txt');   % TODO

% ========== 输出 ==========
cfg.out_dir        = fullfile(cfg.cube_dir, 'RadianceCubes_withUncertainty_Output');
cfg.save_mat        = true;
cfg.block_rows      = 0;      % 大数据可设 200~800（主计算）
cfg.use_single      = false;
cfg.export_envi_bil = true;
cfg.export_dtype    = 'single';
if ~exist(cfg.out_dir,'dir'); mkdir(cfg.out_dir); end

% ========== 绘图 ==========
cfg.do_plot      = true;
cfg.plot_band_nm = 550;
cfg.save_png_dpi = 300;
cfg.unc_k        = 2;   % 画图时显示 ±2σ（k=2）

% ========== 保存fig（你最新要求） ==========
cfg.save_fig = true;   % ✅ 同步保存 .fig
cfg.save_png = true;   % ✅ 仍保存 .png

% ========== 贡献图 ==========
cfg.do_contrib_plot    = true;
cfg.contrib_block_rows = max(cfg.block_rows, 200); % 贡献统计按块处理
cfg.contrib_plot_k     = 2;                         % 分量等效Uabs图用k=2

% ========== ROI/点选输出（新增） ==========
cfg.roi = struct();
cfg.roi.enable    = false; % true: 使用 ROI/点位输出
cfg.roi.row       = [];    % 行号（1-based），空则默认中心
cfg.roi.col       = [];    % 列号（1-based），空则默认中心
cfg.roi.half_size = 0;     % ROI 半径（像元）。0 = 单点

%% ================== 1) 读取积分球辐亮度（Excel） ==================
[lambda, radiances] = load_radiances_excel(cfg.excel_file);
[bands, num_conditions] = size(radiances);

%% ================== 2) 读取标定 DN（多个CSV） ==================
DN_calib = load_dn_cube_from_csv(cfg.csv_files, cfg.num_pixels, bands, num_conditions); % [W x B x cond]

%% ================== 3) 标定：逐像元逐波段 OLS 拟合 + σa/σb/covab ==================
fprintf('▶ 开始标定：W=%d, B=%d, 条件数=%d ...\n', cfg.num_pixels, bands, num_conditions);
[a_matrix, b_matrix, r2_matrix, sa_matrix, sb_matrix, cab_matrix] = ...
    calculate_coefficients_ols_unc(DN_calib, radiances, cfg.L_sigma_ratio, cfg.use_parfor);
fprintf('✅ 标定完成。\n');

%% ================== 4) 读取 DN 白板/场景（ENVI BIL） ==================
DN_white = read_envi_cube_to_HWB(cfg.white_dn_bil, cfg.white_dn_hdr);
DN_scene = read_envi_cube_to_HWB(cfg.scene_dn_bil, cfg.scene_dn_hdr);

assert(size(DN_white,2) == cfg.num_pixels, 'DN_white samples(W)=%d 与 num_pixels=%d 不一致', size(DN_white,2), cfg.num_pixels);
assert(size(DN_scene,2) == cfg.num_pixels, 'DN_scene samples(W)=%d 与 num_pixels=%d 不一致', size(DN_scene,2), cfg.num_pixels);
assert(size(DN_white,3) == bands, 'DN_white bands=%d 与标定 bands=%d 不一致', size(DN_white,3), bands);
assert(size(DN_scene,3) == bands, 'DN_scene bands=%d 与标定 bands=%d 不一致', size(DN_scene,3), bands);

%% ================== 5) 读取 DN 噪声 u_rel（标量/ENVI BIL） ==================
if isfield(cfg,'urel_DN_noise_bil') && ~isempty(cfg.urel_DN_noise_bil)
    urel_DN_noise_raw = read_envi_cube_to_HWB(cfg.urel_DN_noise_bil, cfg.urel_DN_noise_hdr);
else
    urel_DN_noise_raw = cfg.urel_DN_noise;
end

%% ================== 6) 读取角度不确定度（对DN的 u_rel，ENVI BIL） ==================
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

%% ================== 7) 先把每项 u_rel * |DN| 变成 σ(DN)，再合成 ==================
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

%% ================== 8) 白板：DN -> L + sigma_L 3D（不含9.x额外项） ==================
fprintf('▶ 白板：DN -> L + sigma_L ...\n');
[L_white, sigma_L_white_k1, u_rel_L_white_k1] = dn_cube_to_radiance_cube( ...
    DN_white, urel_DN_noise_raw, sigmaDN_ang_w, ...
    a_matrix, b_matrix, sa_matrix, sb_matrix, cab_matrix, cfg.block_rows);

%% ================== 9) 场景：DN -> L + sigma_L 3D（不含9.x额外项） ==================
fprintf('▶ 场景：DN -> L + sigma_L ...\n');
[L_scene, sigma_L_scene_k1, u_rel_L_scene_k1] = dn_cube_to_radiance_cube( ...
    DN_scene, urel_DN_noise_raw, sigmaDN_ang_s, ...
    a_matrix, b_matrix, sa_matrix, sb_matrix, cab_matrix, cfg.block_rows);

%% ================== 9.x) 叠加“直接作用在L上”的两类不确定度（相对u_rel,k=1） ==================
urel_L_specCal = load_urel_spectrum_txt(cfg.urel_L_spectralCal_txt, lambda, 'spectralCal', 'rel'); % [B x 1]
urel_L_source  = load_urel_spectrum_txt(cfg.urel_L_sourceInstab_txt,  lambda, 'sourceInstab','rel'); % [B x 1]
B = bands;

% 展开到 cube 并合成
urel3_spec     = repmat(reshape(urel_L_specCal, [1 1 B]), [size(L_white,1) size(L_white,2) 1]);
urel3_source_w = repmat(reshape(urel_L_source,  [1 1 B]), [size(L_white,1) size(L_white,2) 1]);
urel3_source_s = repmat(reshape(urel_L_source,  [1 1 B]), [size(L_scene,1) size(L_scene,2) 1]);

sigma_add_spec_white   = urel3_spec      .* L_white;
sigma_add_source_white = urel3_source_w  .* L_white;
sigma_L_white_k1_total = sqrt( sigma_L_white_k1.^2 + sigma_add_spec_white.^2 + sigma_add_source_white.^2 );
u_rel_L_white_k1_total = sigma_L_white_k1_total ./ max(abs(L_white), 1e-12);

sigma_add_spec_scene   = repmat(reshape(urel_L_specCal, [1 1 B]), [size(L_scene,1) size(L_scene,2) 1]) .* L_scene;
sigma_add_source_scene = urel3_source_s .* L_scene;
sigma_L_scene_k1_total = sqrt( sigma_L_scene_k1.^2 + sigma_add_spec_scene.^2 + sigma_add_source_scene.^2 );
u_rel_L_scene_k1_total = sigma_L_scene_k1_total ./ max(abs(L_scene), 1e-12);

sigma_L_white_k1 = sigma_L_white_k1_total;
u_rel_L_white_k1 = u_rel_L_white_k1_total;
sigma_L_scene_k1 = sigma_L_scene_k1_total;
u_rel_L_scene_k1 = u_rel_L_scene_k1_total;

tmp_urel_L_specCal_k1 = urel_L_specCal(:);
tmp_urel_L_source_k1  = urel_L_source(:);

%% ================== 9) 绘图（辐亮度 L 的不确定度；统一 ±2σ） ==================
if cfg.do_plot
    figDir = fullfile(cfg.out_dir, 'Figures');
    if ~exist(figDir,'dir'); mkdir(figDir); end
    unitL = 'W·m^{-2}·sr^{-1}·nm^{-1}';
    assert(numel(lambda)==B, 'lambda 长度应等于 bands');

    % 1) specCal/source 两条谱（画成 k=2）
    fig = figure('Color','w');
    plot(lambda, 100*cfg.unc_k*urel_L_specCal(:), 'LineWidth', 1.8);
    xlabel('Wavelength (nm)'); ylabel(sprintf('U_{rel,specCal} (k=%d, %%)', cfg.unc_k));
    grid on; title(sprintf('Spectral calibration uncertainty on radiance (relative, k=%d)', cfg.unc_k));
    export_fig_png_and_fig(fig, fullfile(figDir,'Fig_uRel_specCal_k2'), cfg.save_png_dpi, cfg.save_png, cfg.save_fig);

    fig = figure('Color','w');
    plot(lambda, 100*cfg.unc_k*urel_L_source(:), 'LineWidth', 1.8);
    xlabel('Wavelength (nm)'); ylabel(sprintf('U_{rel,source} (k=%d, %%)', cfg.unc_k));
    grid on; title(sprintf('Source instability uncertainty on radiance (relative, k=%d)', cfg.unc_k));
    export_fig_png_and_fig(fig, fullfile(figDir,'Fig_uRel_sourceInstab_k2'), cfg.save_png_dpi, cfg.save_png, cfg.save_fig);

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
    grid on; title(sprintf('Final radiance relative uncertainty (k=%d)', cfg.unc_k));
    export_fig_png_and_fig(fig, fullfile(figDir,'Fig_Urel_cube_summary_k2'), cfg.save_png_dpi, cfg.save_png, cfg.save_fig);

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
    grid on; title(sprintf('Final radiance absolute uncertainty (k=%d)', cfg.unc_k));
    export_fig_png_and_fig(fig, fullfile(figDir,'Fig_Uabs_cube_summary_k2'), cfg.save_png_dpi, cfg.save_png, cfg.save_fig);

    % 4) 单波段空间图 + 直方图（用 Uabs(k=2)）
    [~, ib] = min(abs(lambda - cfg.plot_band_nm));
    band_nm = lambda(ib);
    Uw_map = cfg.unc_k * sigma_L_white_k1(:,:,ib);
    Us_map = cfg.unc_k * sigma_L_scene_k1(:,:,ib);

    fig = figure('Color','w'); imagesc(Uw_map); axis image; colorbar;
    title(sprintf('White: U_{abs}(k=%d) @ %.1f nm', cfg.unc_k, band_nm));
    xlabel('Samples'); ylabel('Lines');
    export_fig_png_and_fig(fig, fullfile(figDir, sprintf('Fig_map_Uabs_white_k2_%dnm', round(band_nm))), ...
        cfg.save_png_dpi, cfg.save_png, cfg.save_fig);

    fig = figure('Color','w'); imagesc(Us_map); axis image; colorbar;
    title(sprintf('Scene: U_{abs}(k=%d) @ %.1f nm', cfg.unc_k, band_nm));
    xlabel('Samples'); ylabel('Lines');
    export_fig_png_and_fig(fig, fullfile(figDir, sprintf('Fig_map_Uabs_scene_k2_%dnm', round(band_nm))), ...
        cfg.save_png_dpi, cfg.save_png, cfg.save_fig);

    fig = figure('Color','w'); hold on;
    histogram(Uw_map(:), 60, 'Normalization','pdf');
    histogram(Us_map(:), 60, 'Normalization','pdf');
    xlabel(sprintf('U_{abs}(k=%d) @ %.1f nm [%s]', cfg.unc_k, band_nm, unitL));
    ylabel('PDF'); legend({'White','Scene'}, 'Location','best');
    grid on; title('Distribution of radiance absolute uncertainty');
    export_fig_png_and_fig(fig, fullfile(figDir, sprintf('Fig_hist_Uabs_k2_%dnm', round(band_nm))), ...
        cfg.save_png_dpi, cfg.save_png, cfg.save_fig);

    % 5) 点选像元：辐亮度谱 + ±2σ 不确定度带（默认中心像元）
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
    export_fig_png_and_fig(fig, fullfile(figDir,'Fig_white_centerSpectrum_pm2Sigma'), cfg.save_png_dpi, cfg.save_png, cfg.save_fig);

    fig = figure('Color','w'); hold on;
    fill([lambda; flipud(lambda)], [Ls0-cfg.unc_k*Ss0; flipud(Ls0+cfg.unc_k*Ss0)], ...
        [0.7 0.7 0.7], 'EdgeColor','none', 'FaceAlpha',0.5);
    plot(lambda, Ls0, 'LineWidth', 1.8);
    xlabel('Wavelength (nm)'); ylabel(['Radiance [' unitL ']']);
    title(sprintf('Scene pixel radiance with ±%dσ band (row=%d, col=%d) %s', cfg.unc_k, rs, cs, roi_note_s));
    grid on;
    export_fig_png_and_fig(fig, fullfile(figDir,'Fig_scene_centerSpectrum_pm2Sigma'), cfg.save_png_dpi, cfg.save_png, cfg.save_fig);

    % 贡献图（新增）
    if isfield(cfg,'do_contrib_plot') && cfg.do_contrib_plot
        angW = struct('sza', sigmaDN_SZA_w, 'saa', sigmaDN_SAA_w, 'vza', [], 'vaa', []);
        angS = struct('sza', sigmaDN_SZA_s, 'saa', sigmaDN_SAA_s, 'vza', sigmaDN_VZA_s, 'vaa', sigmaDN_VAA_s);
        plot_radiance_uncertainty_contributions( ...
            cfg, figDir, lambda, ...
            DN_white, angW, L_white, ...
            DN_scene, angS, L_scene, ...
            a_matrix, sa_matrix, sb_matrix, cab_matrix, ...
            urel_DN_noise_raw, urel_L_specCal, urel_L_source);
    end

    % 6) ROI 统计（可选）：相对/绝对不确定度空间摘要
    if cfg.roi.enable
        roiW = extract_roi_cube(u_rel_L_white_k1, cfg.roi);
        roiS = extract_roi_cube(u_rel_L_scene_k1, cfg.roi);
        roiW_abs = extract_roi_cube(sigma_L_white_k1, cfg.roi);
        roiS_abs = extract_roi_cube(sigma_L_scene_k1, cfg.roi);

        uW_rel_roi = reshape(roiW, [], B);
        uS_rel_roi = reshape(roiS, [], B);
        UrelW_mean_roi = cfg.unc_k * mean(uW_rel_roi, 1, 'omitnan');
        UrelS_mean_roi = cfg.unc_k * mean(uS_rel_roi, 1, 'omitnan');
        UrelW_med_roi  = cfg.unc_k * median(uW_rel_roi, 1, 'omitnan');
        UrelS_med_roi  = cfg.unc_k * median(uS_rel_roi, 1, 'omitnan');

        fig = figure('Color','w'); hold on;
        plot(lambda, 100*UrelW_mean_roi, 'LineWidth', 1.8);
        plot(lambda, 100*UrelS_mean_roi, 'LineWidth', 1.8);
        plot(lambda, 100*UrelW_med_roi,  '--', 'LineWidth', 1.4);
        plot(lambda, 100*UrelS_med_roi,  '--', 'LineWidth', 1.4);
        xlabel('Wavelength (nm)');
        ylabel(sprintf('U_{rel}(k=%d, %%) (ROI summary)', cfg.unc_k));
        legend({'White mean','Scene mean','White median','Scene median'}, 'Location','best');
        grid on; title('ROI radiance relative uncertainty');
        export_fig_png_and_fig(fig, fullfile(figDir,'Fig_Urel_ROI_summary_k2'), cfg.save_png_dpi, cfg.save_png, cfg.save_fig);

        sW_abs_roi = reshape(roiW_abs, [], B);
        sS_abs_roi = reshape(roiS_abs, [], B);
        UabsW_mean_roi = cfg.unc_k * mean(sW_abs_roi, 1, 'omitnan');
        UabsS_mean_roi = cfg.unc_k * mean(sS_abs_roi, 1, 'omitnan');
        UabsW_med_roi  = cfg.unc_k * median(sW_abs_roi, 1, 'omitnan');
        UabsS_med_roi  = cfg.unc_k * median(sS_abs_roi, 1, 'omitnan');

        fig = figure('Color','w'); hold on;
        plot(lambda, UabsW_mean_roi, 'LineWidth', 1.8);
        plot(lambda, UabsS_mean_roi, 'LineWidth', 1.8);
        plot(lambda, UabsW_med_roi,  '--', 'LineWidth', 1.4);
        plot(lambda, UabsS_med_roi,  '--', 'LineWidth', 1.4);
        xlabel('Wavelength (nm)');
        ylabel(sprintf('U_{abs}(k=%d) [%s] (ROI summary)', cfg.unc_k, unitL));
        legend({'White mean','Scene mean','White median','Scene median'}, 'Location','best');
        grid on; title('ROI radiance absolute uncertainty');
        export_fig_png_and_fig(fig, fullfile(figDir,'Fig_Uabs_ROI_summary_k2'), cfg.save_png_dpi, cfg.save_png, cfg.save_fig);
    end

    fprintf('✅ 绘图完成：已保存到：%s\n', figDir);
end

%% ================== 10) 可选：转 single 省内存 ==================
if cfg.use_single
    L_white = single(L_white);
    sigma_L_white_k1 = single(sigma_L_white_k1);
    u_rel_L_white_k1 = single(u_rel_L_white_k1);
    L_scene = single(L_scene);
    sigma_L_scene_k1 = single(sigma_L_scene_k1);
    u_rel_L_scene_k1 = single(u_rel_L_scene_k1);
end

%% ================== 11) 输出结构体 ==================
rad_out = struct();
rad_out.lambda = lambda(:);

[roi_rw, roi_cw] = resolve_roi_pixel(cfg.roi, size(L_white,1), size(L_white,2));
[roi_rs, roi_cs] = resolve_roi_pixel(cfg.roi, size(L_scene,1), size(L_scene,2));
rad_out.roi = struct( ...
    'enable', cfg.roi.enable, ...
    'row', cfg.roi.row, ...
    'col', cfg.roi.col, ...
    'half_size', cfg.roi.half_size, ...
    'white_pixel', [roi_rw roi_cw], ...
    'scene_pixel', [roi_rs roi_cs]);

% 标定参数
rad_out.a_matrix = a_matrix;
rad_out.b_matrix = b_matrix;
rad_out.sigma_a_k1 = sa_matrix;
rad_out.sigma_b_k1 = sb_matrix;
rad_out.cov_ab = cab_matrix;
rad_out.r2_matrix = r2_matrix;
rad_out.L_sigma_ratio = cfg.L_sigma_ratio;

% 白板输出
rad_out.L_white = L_white;
rad_out.sigma_L_white_k1 = sigma_L_white_k1;
rad_out.u_rel_L_white_k1 = u_rel_L_white_k1;

% 场景输出
rad_out.L_scene = L_scene;
rad_out.sigma_L_scene_k1 = sigma_L_scene_k1;
rad_out.u_rel_L_scene_k1 = u_rel_L_scene_k1;

% 两条直接作用在L上的谱（相对，k=1）
rad_out.urel_L_specCal_k1 = tmp_urel_L_specCal_k1;
rad_out.urel_L_source_k1  = tmp_urel_L_source_k1;

rad_out.note = ['DN uncertainty is combined in ABSOLUTE domain first: ' ...
    'each u_rel(DN) term is multiplied by |DN| to get sigma(DN), then RSS. ' ...
    'SpecCal & SourceInstab are relative u(L) (k=1) applied as (u_rel*L).'];

%% ================== 12) 保存 MAT ==================
if cfg.save_mat
    outFile = fullfile(cfg.out_dir, 'RadianceCubes_withUncertainty.mat');
    save(outFile, '-struct', 'rad_out', '-v7.3');
    fprintf('✅ 已保存 MAT：%s\n', outFile);
end

%% ================== 13) 导出 ENVI BIL（辐亮度 & sigma_L） ==================
if cfg.export_envi_bil
    Lw = cast(L_white, cfg.export_dtype);
    Sw = cast(sigma_L_white_k1, cfg.export_dtype);
    Ls = cast(L_scene, cfg.export_dtype);
    Ss = cast(sigma_L_scene_k1, cfg.export_dtype);

    write_envi_bil(Lw, fullfile(cfg.out_dir,'L_white.bil'), lambda);
    write_envi_bil(Sw, fullfile(cfg.out_dir,'sigmaL_white_k1.bil'), lambda);

    write_envi_bil(Ls, fullfile(cfg.out_dir,'L_scene.bil'), lambda); % 你可改名
    write_envi_bil(Ss, fullfile(cfg.out_dir,'sigmaL_scene_k1.bil'), lambda);

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
    calculate_coefficients_ols_unc(DN_cube, radiances, L_sigma_ratio, use_parfor)
[W, B, cond] = size(DN_cube);
if size(radiances,1) ~= B || size(radiances,2) ~= cond
    error('radiances尺寸应为 [B x cond]，实际=%s', mat2str(size(radiances)));
end

a_matrix = zeros(W,B);
b_matrix = zeros(W,B);
r2_matrix = zeros(W,B);
sa_matrix = zeros(W,B);
sb_matrix = zeros(W,B);
cab_matrix= zeros(W,B);

if use_parfor
    parfor band = 1:B %#ok<PFBNS>
        L = radiances(band,:).';
        sigma_L = abs(L) * L_sigma_ratio;
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
        sigma_L = abs(L) * L_sigma_ratio;
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
% 1) 点值辐亮度
L = DN .* a3 + b3;

% 2) DN端：先转绝对再合成
sigmaDN_noise = urel_DN_noise .* abs(DN);
sigmaDN_tot   = sqrt( sigmaDN_noise.^2 + sigmaDN_ang.^2 );

% 3) 传播到 L：参数项 + DN项（含 cov(a,b)）
var_param = (DN.^2) .* (sa3.^2) + (sb3.^2) + 2 .* DN .* cab3;
var_DN    = (a3.^2) .* (sigmaDN_tot.^2);

sigmaL2 = max(var_param + var_DN, 0);
sigmaL  = sqrt(sigmaL2);
urelL   = sigmaL ./ max(abs(L), 1e-12);
end

function X3 = expand_to_cube(X, H, W, B, name)
if isscalar(X)
    X3 = repmat(X, [H W B]);
    return;
end
if ndims(X) == 2
    sz = size(X);
    if isequal(sz, [H W])
        X3 = repmat(X, [1 1 B]);
        return;
    end
    if isequal(sz, [W 1]) || isequal(sz, [1 W])
        Xv = reshape(X, [1 W 1]);
        X3 = repmat(Xv, [H 1 B]);
        return;
    end
    if isequal(sz, [W B])
        X3 = repmat(reshape(X, [1 W B]), [H 1 1]);
        return;
    end
    error('%s 的2D尺寸不支持：%s', name, mat2str(sz));
end
if ndims(X) == 3
    if isequal(size(X), [H W B])
        X3 = X;
        return;
    end
    if isequal(size(X), [W B H])
        X3 = permute(X, [3 1 2]);
        return;
    end
    error('%s 的3D尺寸不支持：%s', name, mat2str(size(X)));
end
error('%s 维度不支持（需标量/2D/3D）', name);
end

%% ======================================================================
% 9.x 用：读取谱不确定度 txt，并插值到目标波长（支持 rel/abs）
% ======================================================================
function u_out = load_urel_spectrum_txt(txt_file, lambda_target, tagName, mode)
if nargin < 4 || isempty(mode)
    mode = 'rel';
end
mode = lower(string(mode));
B = numel(lambda_target);
lambda_target = lambda_target(:);

if isempty(txt_file) || ~isfile(txt_file)
    error('找不到 %s txt：%s', tagName, string(txt_file));
end
M = readmatrix(txt_file);
if isempty(M)
    error('%s txt 为空：%s', tagName, txt_file);
end
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
if ~isfile(bil_file)
    error('找不到数据文件：%s', bil_file);
end
if nargin < 2 || isempty(hdr_file)
    [p,n,~] = fileparts(bil_file);
    hdr_guess = fullfile(p, [n '.hdr']);
    if isfile(hdr_guess)
        hdr_file = hdr_guess;
    else
        error('未提供HDR，且未找到同名HDR：%s', hdr_guess);
    end
end
if ~isfile(hdr_file)
    error('找不到HDR文件：%s', hdr_file);
end

hdr = read_envi_hdr(hdr_file);
samples = hdr.samples;
lines   = hdr.lines;
bands   = hdr.bands;
offset  = hdr.header_offset;
interleave = lower(hdr.interleave);

[precision, ~] = envi_dtype_to_matlab(hdr.data_type);
machinefmt = ternary(hdr.byte_order==0, 'ieee-le', 'ieee-be');

fid = fopen(bil_file, 'r', machinefmt);
if fid < 0
    error('无法打开：%s', bil_file);
end
cleaner = onCleanup(@() fclose(fid)); %#ok<NASGU>

if offset > 0
    fseek(fid, offset, 'bof');
end

nElem = double(samples) * double(lines) * double(bands);
raw = fread(fid, nElem, ['*' precision]);
if numel(raw) ~= nElem
    error('读取元素数不够：读到 %d，期望 %d（检查HDR参数/文件是否完整）', numel(raw), nElem);
end

switch interleave
    case 'bil'
        raw3 = reshape(raw, [samples, bands, lines]);
        cube = permute(raw3, [3 1 2]); % [lines, samples, bands]
    case 'bsq'
        raw3 = reshape(raw, [samples, lines, bands]);
        cube = permute(raw3, [2 1 3]);
    case 'bip'
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
    if isempty(line); continue; end
    if startsWith(lower(line),'envi'); continue; end

    m = regexp(line, '^\s*([^=]+?)\s*=\s*(.*)\s*$', 'tokens', 'once');
    if isempty(m); continue; end
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
if fid < 0
    error('无法写入：%s', bil_path);
end
cleaner = onCleanup(@() fclose(fid)); %#ok<NASGU>
fwrite(fid, raw3(:), precision);

[p,n,~] = fileparts(bil_path);
hdr_path = fullfile(p, [n '.hdr']);
fid2 = fopen(hdr_path, 'w');
if fid2 < 0
    error('无法写HDR：%s', hdr_path);
end
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
        if k < bands
            fprintf(fid2, '%.8g, ', lambda(k));
        else
            fprintf(fid2, '%.8g', lambda(k));
        end
    end
    fprintf(fid2, '}\n');
end
end

function f = safe_field(key)
f = regexprep(key, '[^a-zA-Z0-9_]', '_');
end

function out = ternary(cond, a, b)
if cond; out = a; else; out = b; end
end

%% ======================================================================
% E) 图导出：同时保存 .png + .fig（新增）
% ======================================================================
function export_fig_png_and_fig(fig, out_base, dpi, save_png, save_fig)
if nargin < 4, save_png = true; end
if nargin < 5, save_fig = true; end
if nargin < 3 || isempty(dpi), dpi = 300; end

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
end

%% ======================================================================
% D) 贡献图（新增）
% ======================================================================
function plot_radiance_uncertainty_contributions( ...
    cfg, figDir, lambda, ...
    DNw, angW, Lw, ...
    DNs, angS, Ls, ...
    a_matrix, sa_matrix, sb_matrix, cab_matrix, ...
    urel_DN_noise_raw, urel_spec_vec, urel_source_vec)

lambda = lambda(:);
B = numel(lambda);

statsW = summarize_var_terms_spatial( ...
    DNw, angW, Lw, ...
    a_matrix, sa_matrix, sb_matrix, cab_matrix, ...
    urel_DN_noise_raw, urel_spec_vec, urel_source_vec, ...
    cfg.contrib_block_rows);

statsS = summarize_var_terms_spatial( ...
    DNs, angS, Ls, ...
    a_matrix, sa_matrix, sb_matrix, cab_matrix, ...
    urel_DN_noise_raw, urel_spec_vec, urel_source_vec, ...
    cfg.contrib_block_rows);

make_stack_fraction_plot(cfg, lambda, statsW, cfg.save_png_dpi, ...
    fullfile(figDir,'Fig_ContribFraction_Variance_White'), ...
    'White radiance variance contribution (spatial mean)');

make_stack_fraction_plot(cfg, lambda, statsS, cfg.save_png_dpi, ...
    fullfile(figDir,'Fig_ContribFraction_Variance_Scene'), ...
    'Scene radiance variance contribution (spatial mean)');

make_components_line_plot(cfg, lambda, statsW, cfg.contrib_plot_k, cfg.save_png_dpi, ...
    fullfile(figDir,'Fig_ContribComponents_Uabs_White'), ...
    sprintf('White: component equivalent U_{abs} (k=%d, spatial mean)', cfg.contrib_plot_k));

make_components_line_plot(cfg, lambda, statsS, cfg.contrib_plot_k, cfg.save_png_dpi, ...
    fullfile(figDir,'Fig_ContribComponents_Uabs_Scene'), ...
    sprintf('Scene: component equivalent U_{abs} (k=%d, spatial mean)', cfg.contrib_plot_k));

% 点选像元版本（默认中心像元）
[rw,cw,roi_note_w] = resolve_roi_pixel(cfg.roi, size(DNw,1), size(DNw,2));
[rs,cs,roi_note_s] = resolve_roi_pixel(cfg.roi, size(DNs,1), size(DNs,2));

pixW = var_terms_single_pixel( ...
    squeeze(DNw(rw,cw,:)), get_angle_pixel(angW, rw, cw, B), squeeze(Lw(rw,cw,:)), ...
    squeeze(a_matrix(cw,:)).', squeeze(sa_matrix(cw,:)).', squeeze(sb_matrix(cw,:)).', squeeze(cab_matrix(cw,:)).', ...
    get_noise_for_pixel(urel_DN_noise_raw, rw, cw, B), urel_spec_vec(:), urel_source_vec(:));

pixS = var_terms_single_pixel( ...
    squeeze(DNs(rs,cs,:)), get_angle_pixel(angS, rs, cs, B), squeeze(Ls(rs,cs,:)), ...
    squeeze(a_matrix(cs,:)).', squeeze(sa_matrix(cs,:)).', squeeze(sb_matrix(cs,:)).', squeeze(cab_matrix(cs,:)).', ...
    get_noise_for_pixel(urel_DN_noise_raw, rs, cs, B), urel_spec_vec(:), urel_source_vec(:));

make_stack_fraction_plot(cfg, lambda, pixW, cfg.save_png_dpi, ...
    fullfile(figDir,'Fig_ContribFraction_Variance_White_Point'), ...
    sprintf('White pixel variance contribution (r=%d,c=%d) %s', rw, cw, roi_note_w));

make_stack_fraction_plot(cfg, lambda, pixS, cfg.save_png_dpi, ...
    fullfile(figDir,'Fig_ContribFraction_Variance_Scene_Point'), ...
    sprintf('Scene pixel variance contribution (r=%d,c=%d) %s', rs, cs, roi_note_s));

make_components_line_plot(cfg, lambda, pixW, cfg.contrib_plot_k, cfg.save_png_dpi, ...
    fullfile(figDir,'Fig_ContribComponents_Uabs_White_Point'), ...
    sprintf('White pixel component U_{abs} (k=%d) %s', cfg.contrib_plot_k, roi_note_w));

make_components_line_plot(cfg, lambda, pixS, cfg.contrib_plot_k, cfg.save_png_dpi, ...
    fullfile(figDir,'Fig_ContribComponents_Uabs_Scene_Point'), ...
    sprintf('Scene pixel component U_{abs} (k=%d) %s', cfg.contrib_plot_k, roi_note_s));
end

function stats = summarize_var_terms_spatial( ...
    DN, ang, L, ...
    a_matrix, sa_matrix, sb_matrix, cab_matrix, ...
    urel_DN_noise_raw, urel_spec_vec, urel_source_vec, ...
    block_rows)

[H,W,B] = size(DN);

a3   = reshape(a_matrix,  [1 W B]);
sa3  = reshape(sa_matrix, [1 W B]);
sb3  = reshape(sb_matrix, [1 W B]);
cab3 = reshape(cab_matrix,[1 W B]);

urel_spec_vec   = urel_spec_vec(:);
urel_source_vec = urel_source_vec(:);

sum_va      = zeros(B,1); cnt_va      = zeros(B,1);
sum_vb      = zeros(B,1); cnt_vb      = zeros(B,1);
sum_vcov    = zeros(B,1); cnt_vcov    = zeros(B,1);
sum_vnoise  = zeros(B,1); cnt_vnoise  = zeros(B,1);
sum_vsza    = zeros(B,1); cnt_vsza    = zeros(B,1);
sum_vsaa    = zeros(B,1); cnt_vsaa    = zeros(B,1);
sum_vvza    = zeros(B,1); cnt_vvza    = zeros(B,1);
sum_vvaa    = zeros(B,1); cnt_vvaa    = zeros(B,1);
sum_vspec   = zeros(B,1); cnt_vspec   = zeros(B,1);
sum_vsource = zeros(B,1); cnt_vsource = zeros(B,1);

if block_rows <= 0, block_rows = 200; end

for rr0 = 1:block_rows:H
    rr1 = min(H, rr0+block_rows-1);

    DNblk  = DN(rr0:rr1,:,:);
    Lblk   = L(rr0:rr1,:,:);
    angblk = get_angle_block(ang, rr0, rr1, 1, W, B, size(DNblk));

    nR = size(DNblk,1);

    uNblk = get_noise_block(urel_DN_noise_raw, rr0, rr1, 1, W, B, size(DNblk));
    sigmaDN_noise = uNblk .* abs(DNblk);

    aR   = repmat(a3,   [nR 1 1]);
    saR  = repmat(sa3,  [nR 1 1]);
    sbR  = repmat(sb3,  [nR 1 1]);
    cabR = repmat(cab3, [nR 1 1]);

    v_a     = (DNblk.^2) .* (saR.^2);
    v_b     = (sbR.^2);
    v_cov   = 2 .* DNblk .* cabR;
    v_noise = (aR.^2) .* (sigmaDN_noise.^2);
    v_sza   = (aR.^2) .* (angblk.sza.^2);
    v_saa   = (aR.^2) .* (angblk.saa.^2);
    v_vza   = (aR.^2) .* (angblk.vza.^2);
    v_vaa   = (aR.^2) .* (angblk.vaa.^2);

    urel_spec_blk   = repmat(reshape(urel_spec_vec,   [1 1 B]), [nR W 1]);
    urel_source_blk = repmat(reshape(urel_source_vec, [1 1 B]), [nR W 1]);

    v_spec   = (urel_spec_blk   .* Lblk).^2;
    v_source = (urel_source_blk .* Lblk).^2;

    [sum_va, cnt_va]           = acc_band_sum(v_a,     sum_va, cnt_va);
    [sum_vb, cnt_vb]           = acc_band_sum(v_b,     sum_vb, cnt_vb);
    [sum_vcov, cnt_vcov]       = acc_band_sum(v_cov,   sum_vcov, cnt_vcov);
    [sum_vnoise, cnt_vnoise]   = acc_band_sum(v_noise, sum_vnoise, cnt_vnoise);
    [sum_vsza, cnt_vsza]       = acc_band_sum(v_sza,   sum_vsza, cnt_vsza);
    [sum_vsaa, cnt_vsaa]       = acc_band_sum(v_saa,   sum_vsaa, cnt_vsaa);
    [sum_vvza, cnt_vvza]       = acc_band_sum(v_vza,   sum_vvza, cnt_vvza);
    [sum_vvaa, cnt_vvaa]       = acc_band_sum(v_vaa,   sum_vvaa, cnt_vvaa);
    [sum_vspec, cnt_vspec]     = acc_band_sum(v_spec,  sum_vspec, cnt_vspec);
    [sum_vsource, cnt_vsource] = acc_band_sum(v_source,sum_vsource, cnt_vsource);
end

mean_va      = sum_va      ./ max(cnt_va,1);
mean_vb      = sum_vb      ./ max(cnt_vb,1);
mean_vcov    = sum_vcov    ./ max(cnt_vcov,1); % signed
mean_vnoise  = sum_vnoise  ./ max(cnt_vnoise,1);
mean_vsza    = sum_vsza    ./ max(cnt_vsza,1);
mean_vsaa    = sum_vsaa    ./ max(cnt_vsaa,1);
mean_vvza    = sum_vvza    ./ max(cnt_vvza,1);
mean_vvaa    = sum_vvaa    ./ max(cnt_vvaa,1);
mean_vspec   = sum_vspec   ./ max(cnt_vspec,1);
mean_vsource = sum_vsource ./ max(cnt_vsource,1);

stats = pack_stats(mean_va, mean_vb, mean_vcov, mean_vnoise, mean_vsza, mean_vsaa, mean_vvza, mean_vvaa, mean_vspec, mean_vsource);
end

function stats = var_terms_single_pixel(DN, ang, L, a, sa, sb, cab, urel_noise, urel_spec, urel_source)
DN = DN(:); L = L(:);
a=a(:); sa=sa(:); sb=sb(:); cab=cab(:);
urel_noise=urel_noise(:);
urel_spec=urel_spec(:); urel_source=urel_source(:);

sigmaDN_noise = urel_noise .* abs(DN);

v_a      = (DN.^2) .* (sa.^2);
v_b      = (sb.^2);
v_cov    = 2 .* DN .* cab;
v_noise  = (a.^2) .* (sigmaDN_noise.^2);
v_sza    = (a.^2) .* (ang.sza(:).^2);
v_saa    = (a.^2) .* (ang.saa(:).^2);
v_vza    = (a.^2) .* (ang.vza(:).^2);
v_vaa    = (a.^2) .* (ang.vaa(:).^2);
v_spec   = (urel_spec  .* L).^2;
v_source = (urel_source.* L).^2;

stats = pack_stats(v_a, v_b, v_cov, v_noise, v_sza, v_saa, v_vza, v_vaa, v_spec, v_source);
end

function stats = pack_stats(v_a, v_b, v_cov, v_noise, v_sza, v_saa, v_vza, v_vaa, v_spec, v_source)
v_cov_signed = v_cov;
v_cov_mag    = abs(v_cov);

v_sum = v_a + v_b + v_noise + v_sza + v_saa + v_vza + v_vaa + v_spec + v_source + v_cov_mag; % 占比堆叠用正项
v_sum(v_sum<=0) = NaN;

stats.v_a = v_a;
stats.v_b = v_b;
stats.v_cov_signed = v_cov_signed;
stats.v_cov_mag = v_cov_mag;
stats.v_noise = v_noise;
stats.v_sza = v_sza;
stats.v_saa = v_saa;
stats.v_vza = v_vza;
stats.v_vaa = v_vaa;
stats.v_spec = v_spec;
stats.v_source = v_source;
stats.v_sum_for_fraction = v_sum;
end

function make_stack_fraction_plot(cfg, lambda, stats, dpi, outBase, ttl)
frac = [ ...
    stats.v_noise ./ stats.v_sum_for_fraction, ...
    stats.v_sza   ./ stats.v_sum_for_fraction, ...
    stats.v_saa   ./ stats.v_sum_for_fraction, ...
    stats.v_vza   ./ stats.v_sum_for_fraction, ...
    stats.v_vaa   ./ stats.v_sum_for_fraction, ...
    stats.v_a     ./ stats.v_sum_for_fraction, ...
    stats.v_b     ./ stats.v_sum_for_fraction, ...
    stats.v_spec  ./ stats.v_sum_for_fraction, ...
    stats.v_source./ stats.v_sum_for_fraction, ...
    stats.v_cov_mag ./ stats.v_sum_for_fraction ...
    ];
frac = 100*frac;

fig = figure('Color','w');
area(lambda, frac, 'LineStyle','none'); grid on;
xlabel('Wavelength (nm)');
ylabel('Variance contribution (%)');
title({ttl; 'cov(a,b) magnitude is stacked; signed cov effect is overlaid as a line.'});
hold on;
cov_signed_pct = 100 * (stats.v_cov_signed ./ stats.v_sum_for_fraction);
plot(lambda, cov_signed_pct, 'k-', 'LineWidth', 1.2);
legend({'DN noise','SZA','SAA','VZA','VAA','a-fit','b-fit','SpecCal','Source','|cov(a,b)|','cov(a,b) signed'}, 'Location','best');

export_fig_png_and_fig(fig, outBase, dpi, cfg.save_png, cfg.save_fig);
end

function make_components_line_plot(cfg, lambda, stats, k, dpi, outBase, ttl)
U_noise  = k*sqrt(max(stats.v_noise,0));
U_sza    = k*sqrt(max(stats.v_sza,0));
U_saa    = k*sqrt(max(stats.v_saa,0));
U_vza    = k*sqrt(max(stats.v_vza,0));
U_vaa    = k*sqrt(max(stats.v_vaa,0));
U_a      = k*sqrt(max(stats.v_a,0));
U_b      = k*sqrt(max(stats.v_b,0));
U_spec   = k*sqrt(max(stats.v_spec,0));
U_source = k*sqrt(max(stats.v_source,0));
U_covm   = k*sqrt(max(stats.v_cov_mag,0));

fig = figure('Color','w'); hold on;
plot(lambda, U_noise,  'LineWidth', 1.6);
plot(lambda, U_sza,    'LineWidth', 1.6);
plot(lambda, U_saa,    'LineWidth', 1.6);
plot(lambda, U_vza,    'LineWidth', 1.6);
plot(lambda, U_vaa,    'LineWidth', 1.6);
plot(lambda, U_a,      'LineWidth', 1.6);
plot(lambda, U_b,      'LineWidth', 1.6);
plot(lambda, U_spec,   'LineWidth', 1.6);
plot(lambda, U_source, 'LineWidth', 1.6);
plot(lambda, U_covm,   'LineWidth', 1.6);
grid on;
xlabel('Wavelength (nm)');
ylabel(sprintf('Component equivalent U_{abs} (k=%d)', k));
legend({'DN noise','SZA','SAA','VZA','VAA','a-fit','b-fit','SpecCal','Source','|cov(a,b)|'}, 'Location','best');
title(ttl);

export_fig_png_and_fig(fig, outBase, dpi, cfg.save_png, cfg.save_fig);
end

function [sumv, cntv] = acc_band_sum(v, sumv, cntv)
tmp = v;
m = isfinite(tmp);
tmp(~m) = 0;
sv = squeeze(sum(sum(tmp,1),2));
cv = squeeze(sum(sum(m,1),2));
sumv = sumv + sv;
cntv = cntv + cv;
end

function uNblk = get_noise_block(urel_raw, rr0, rr1, c0, c1, B, szBlk)
nR = szBlk(1); nC = szBlk(2);

if isscalar(urel_raw)
    uNblk = repmat(urel_raw, [nR nC B]);
    return;
end

if ndims(urel_raw)==3
    uNblk = urel_raw(rr0:rr1, c0:c1, :);
    return;
end

if ndims(urel_raw)==2
    u2 = urel_raw(rr0:rr1, c0:c1);
    uNblk = repmat(u2, [1 1 B]);
    return;
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

function angblk = get_angle_block(ang, rr0, rr1, c0, c1, B, szBlk)
nR = szBlk(1); nC = szBlk(2);

angblk.sza = get_angle_cube(ang.sza, rr0, rr1, c0, c1, B, nR, nC);
angblk.saa = get_angle_cube(ang.saa, rr0, rr1, c0, c1, B, nR, nC);
angblk.vza = get_angle_cube(ang.vza, rr0, rr1, c0, c1, B, nR, nC);
angblk.vaa = get_angle_cube(ang.vaa, rr0, rr1, c0, c1, B, nR, nC);
end

function angpix = get_angle_pixel(ang, r, c, B)
angpix.sza = get_angle_vec(ang.sza, r, c, B);
angpix.saa = get_angle_vec(ang.saa, r, c, B);
angpix.vza = get_angle_vec(ang.vza, r, c, B);
angpix.vaa = get_angle_vec(ang.vaa, r, c, B);
end

function cube = get_angle_cube(src, rr0, rr1, c0, c1, B, nR, nC)
if isempty(src)
    cube = zeros(nR, nC, B);
    return;
end
if isscalar(src)
    cube = repmat(src, [nR nC B]);
    return;
end
if ndims(src) == 3
    cube = src(rr0:rr1, c0:c1, :);
    return;
end
if ndims(src) == 2
    cube = repmat(src(rr0:rr1, c0:c1), [1 1 B]);
    return;
end
cube = zeros(nR, nC, B);
end

function vec = get_angle_vec(src, r, c, B)
if isempty(src)
    vec = zeros(B,1);
    return;
end
if isscalar(src)
    vec = repmat(src, [B 1]);
    return;
end
if ndims(src) == 3
    vec = squeeze(src(r,c,:));
    return;
end
if ndims(src) == 2
    vec = repmat(src(r,c), [B 1]);
    return;
end
vec = zeros(B,1);
end

function [r,c] = center_rc(cube)
r = round(size(cube,1)/2);
c = round(size(cube,2)/2);
end

function [r, c, note] = resolve_roi_pixel(roi, H, W)
if nargin < 3
    error('resolve_roi_pixel: 需要 H, W');
end
if ~isfield(roi, 'enable') || ~roi.enable
    r = round(H/2);
    c = round(W/2);
    note = '(center)';
    return;
end
r = roi.row;
c = roi.col;
if isempty(r); r = round(H/2); end
if isempty(c); c = round(W/2); end
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
[r, c] = resolve_roi_pixel(roi, H, W);
hs = 0;
if isfield(roi, 'half_size') && ~isempty(roi.half_size)
    hs = max(round(roi.half_size), 0);
end
r0 = max(1, r - hs);
r1 = min(H, r + hs);
c0 = max(1, c - hs);
c1 = min(W, c + hs);
roi_cube = cube(r0:r1, c0:c1, :);
end
