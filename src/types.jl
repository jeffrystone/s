using DataStructures: PriorityQueue

"""Сущности и события по AGENTS §2–§4."""
@enum EventType begin
    SHOT
    HEAVY_SHOT
    RESONANCE
    ANALYSIS
    MANUAL
end

abstract type MetricLevel end
struct L1 <: MetricLevel end
struct L2 <: MetricLevel end
struct L3 <: MetricLevel end
struct L4 <: MetricLevel end
struct L5 <: MetricLevel end

struct Event
    type::EventType
    node_id::UInt64
    partner_id::UInt64
    priority::Float64
    manual::Bool
    payload::Dict{Symbol, Any}
end

function Event(
    t::EventType;
    node_id::UInt64 = UInt64(0),
    partner_id::UInt64 = UInt64(0),
    priority::Float64 = 0.0,
    manual::Bool = false,
    payload::Dict{Symbol, Any} = Dict{Symbol, Any}(),
)
    Event(t, node_id, partner_id, priority, manual, payload)
end

mutable struct Node
    id::UInt64
    params::Dict{Symbol, Any}
    hp::Float64
    mp::Float64
    D::Float64
    mutation_history::Vector{Tuple{Symbol, Float64}}
    mating_history::Vector{Tuple{UInt64, Float64}}
    active::Bool
    mp_frozen::Bool
    heavy_shots::Vector{Tuple{Float64, Bool}}
    metric_components::Vector{Float64}
    resonance_win_streak::Int
end

function Node(id::UInt64, params::Dict{Symbol, Any}; hp::Float64, mp::Float64, D::Float64 = 0.5)
    Node(
        id, params, hp, mp, D,
        Tuple{Symbol, Float64}[],
        Tuple{UInt64, Float64}[],
        true,
        false,
        Tuple{Float64, Bool}[],
        zeros(Float64, 5),
        0,
    )
end

struct Scar
    center::Dict{Symbol, Any}
    radius::Float64
    potential::Float64
    fail_level::Int
    decay_rate::Float64
    last_update::UInt64
end

mutable struct Environment
    nodes::Vector{Node}
    scars::Vector{Scar}
    event_queue::PriorityQueue{Tuple{Event, UInt64}, Float64}
    exploitation_budget::Float64
    exploration_budget::Float64
    metric_weights::Vector{Float64}
    crossover_weights::Dict{Symbol, Float64}
    resonance_memory::Dict{Tuple{UInt64, UInt64}, Float64}
    tick::UInt64
    cold_start::Bool
    manual_events::Channel{Event}
    next_id::UInt64
    schedule_seq::UInt64
    d_history::Vector{Float64}
    stuck_counter::Int
    stop_reason::Symbol
end

"""Индекс 1..5 для весов метрик (L1..L5)."""
level_index(::Type{L1}) = 1
level_index(::Type{L2}) = 2
level_index(::Type{L3}) = 3
level_index(::Type{L4}) = 4
level_index(::Type{L5}) = 5

"""Ключ min-очереди: меньший = важнее; seq разводит одинаковые приоритеты (FIFO-порядка вставки)."""
queue_key(priority::Float64, seq::UInt64)::Float64 =
    -priority + eps(Float64) * Float64(seq % 1024)
