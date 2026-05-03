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
end
