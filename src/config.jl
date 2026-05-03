using StaticArrays

"""Параметры среды (AGENTS §7)."""
Base.@kwdef mutable struct Settings
    cost::SVector{5, Float64} = SA[1.0, 5.0, 20.0, 100.0, 500.0]
    metric_weights::SVector{5, Float64} = SA[fill(1 / 5, 5)...]
    analysis_interval::Int = 20
    cold_start_ticks::Int = 80
    D_thresh_heavy::Float64 = 0.35
    heavy_shot_hp_min::Float64 = 520.0
    scar_eps::Float64 = 1e-4
    stuck_window::Int = 30
    stuck_ticks::Int = 15
    exploration_transfer::Float64 = 0.10
    manual_channel_capacity::Int = 128
    analysis_priority_quantum::Float64 = 1.0
    default_hp::Float64 = 100.0
    default_mp::Float64 = 50.0
    attention_alpha::Float64 = 1.0
    attention_beta::Float64 = 1.0
    attention_gamma::Float64 = 1.0
    use_kdtree_resonance::Bool = false
    kdtree_nn::Int = 8
    kdtree_rebuild_ticks::Int = 50
    resonance_stuck_jitter_amp::Float64 = 1.35
    appeal_l3_vs_l4::Bool = true
    appeal_l3_threshold::Float64 = 0.40
    appeal_l4_threshold::Float64 = 0.58
    appeal_min_gap::Float64 = 0.18
    appeal_hp_cost_heavy::Float64 = 40.0
    appeal_hp_cost_light::Float64 = 12.0
    appeal_use_l5_recheck::Bool = false
    evaluate_cache_enabled::Bool = false
    evaluate_cache_max::Int = 4096
    analysis_calibration_min_samples::Int = 16
    analysis_calibration_buffer_max::Int = 256
    analysis_calibration_eta::Float64 = 0.06
    analysis_calibration_corr_strong::Float64 = 0.35
    analysis_calibration_gap_threshold::Float64 = 0.08
    crossover_learning_enabled::Bool = true
    crossover_learning_eta::Float64 = 0.04
    attention_suffer_gamma::Float64 = 1.35
    resonance_offspring_two_stage::Bool = false
    resonance_two_stage_L1_gate::Float64 = 0.95
    analysis_priority_force_high::Bool = false
    analysis_priority_floor::Float64 = 920.0
    """При постановке ANALYSIS по календарю `tick % interval` приоритет не ниже этого (выше любого SHOT/HEAVY в текущих клэмпах)."""
    analysis_min_priority_when_due::Float64 = 2400.0
    appeal_extend_L2_vs_L3::Bool = false
    appeal_l2_vs_l3_min_gap::Float64 = 0.16
    """Если true — апелляции после выстрелов L2/L3/L4 идут через единый `metric_appeal_dispatch_after_shot!`. Если false — старая ветка `if k==3/4` в `handle_shot!`."""
    appeal_unified_dispatch::Bool = true
    """Если true: после успешной оценки L2 при конфликте с накопленным L3 — дорогая переоценка L3."""
    appeal_l2_challenge_l3::Bool = false
    calibration_extra_node_samples::Bool = false
    calibration_extra_nodes_per_analysis::Int = 8
    recent_events_max::Int = 96
    parallel_offspring::Bool = true
    parallel_offspring_min_trials::Int = 12
    scar_kdtree_min::Int = 16
    """Путь к JSON для сохранения `attention_tune_*` (`nothing` = не сохранять)."""
    attention_tune_persist_path::Union{Nothing,String} = nothing
    """Условное усиление внимания после MANUAL `force_resonance`, если ребёнок лучше родителей."""
    manual_win_tune_enabled::Bool = true
    """Мультипликатор: `attention_tune_gamma *= (1 + eta)` при успехе (и по флагу ниже alpha/beta)."""
    manual_win_tune_eta::Float64 = 0.02
    """Если false — умножаются все три множителя `attention_tune_*`."""
    manual_win_tune_gamma_only::Bool = true
    """Максимум шагов `step!` за один период WebSocket при `auto_step` (`ws_burst_steps`)."""
    dashboard_burst_steps_max::Int = 128
end
