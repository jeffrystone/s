using Random: AbstractRNG, default_rng, shuffle
using LinearAlgebra: dot, norm
using Statistics: mean, cor, std
using DataStructures: isempty, PriorityQueue
using NearestNeighbors: KDTree, knn, inrange

"""Planner and simulation helpers (cold start, shots, resonance, analysis). ASCII comments."""
const _LEVELS = (L1, L2, L3, L4, L5)

const _ENGINE_PARTS = (
    "engine_helpers.jl",
    "engine_incremental_D.jl",
    "engine_analysis_calibration.jl",
    "engine_analysis_schedule.jl",
    "engine_appeals.jl",
    "engine_shots.jl",
    "engine_resonance.jl",
    "engine_manual.jl",
    "engine_step_setup.jl",
    "engine_validate.jl",
)
for fname in _ENGINE_PARTS
    include(joinpath(@__DIR__, fname))
end
