using Test
using Random
using Statistics: mean
using JSON3
using StaticArrays: SA
using Nodes

@testset "greet / module load" begin
    @test greet() isa String
end

@testset "Pollard evaluate smoke" begin
    t = PollardFactoringTask(; l5_max_iter = 200)
    N = BigInt(221)
    p = Dict{Symbol,Any}(:N => N, :start_x => 7, :poly_coeff => 23)
    r1, ok1 = Nodes.evaluate(t, p, L1)
    @test ok1 === false && r1 isa Float64
    r5, ok5 = evaluate(t, copy(p), L5)
    @test typeof(ok5) === Bool && r5 isa Float64
end

@testset "ANALYSIS без голода очереди: d_history пополняется при перегрузе SHOT/RESONANCE" begin
    st = Nodes.Settings(;
        cold_start_ticks = 0,
        analysis_interval = 2,
        metric_weights = SA[0.19, 0.19, 0.21, 0.21, 0.20],
        default_hp = 220.0,
        default_mp = 72.0,
        heavy_shot_hp_min = 900.0,
        D_thresh_heavy = 0.12,
        analysis_min_priority_when_due = 2400.0,
    )
    ta = Nodes.PollardFactoringTask(; l5_max_iter = 96)
    rng = MersenneTwister(201)
    env = Nodes.build_environment(ta, st; N_init = 22, shared_N = BigInt(221), rng = rng)
    d0 = length(env.d_history)
    for _ = 1:360
        Nodes.step!(env, ta, st; rng = rng)
        env.stop_reason !== :running && break
    end
    @test env.stop_reason === :running
    @test length(env.d_history) - d0 >= 150
end

@testset "snapshot_json_with_broadcast_metric_deltas задаёт ключи Δws" begin
    st = Nodes.Settings(; cold_start_ticks = 20)
    ta = Nodes.PollardFactoringTask(; l5_max_iter = 64)
    rng = MersenneTwister(3)
    env = Nodes.build_environment(ta, st; N_init = 4, shared_N = BigInt(221), rng = rng)
    prev_ev = Ref{Union{Nothing, Dict{Symbol, Float64}}}(nothing)
    prev_nd = Ref{Union{Nothing, Dict{UInt64, Float64}}}(nothing)
    Nodes.step!(env, ta, st; rng = rng)
    j1 =
        Nodes.snapshot_json_with_broadcast_metric_deltas(env, prev_ev, prev_nd)
    d1 = JSON3.read(j1, Dict)
    @test haskey(d1, "event_time_delta_s") && haskey(d1, "per_node_time_delta_s")
end

@testset "Environment + несколько тактов симуляции" begin
    rng = MersenneTwister(7)
    st = Settings(; cold_start_ticks = 120, heavy_shot_hp_min = 40.0)
    ta = PollardFactoringTask(; l5_max_iter = 512)
    env = build_environment(ta, st; N_init = 5, shared_N = BigInt(221), rng)

    sid1 = env.nodes[1].id
    @test sid1 isa UInt64

    for _ = 1:80
        step!(env, ta, st; rng)
    end
    @test length(env.nodes) >= 1
end

@testset "snapshot: новые ключи state_snapshot" begin
    st = Settings(; cold_start_ticks = 50)
    ta = PollardFactoringTask(; l5_max_iter = 128)
    env = build_environment(ta, st; N_init = 2, shared_N = BigInt(143), rng = MersenneTwister(3))
    step!(env, ta, st; rng = MersenneTwister(3))
    snap = state_snapshot(env)
    @test haskey(snap, :cpu_usage_per_core)
    @test length(snap[:cpu_usage_per_core]) == Sys.CPU_THREADS
    @test haskey(snap, :event_time_s) && snap[:event_time_s] isa Dict
    @test haskey(snap, :per_node_time_s) && snap[:per_node_time_s] isa Dict
    @test snap[:metric_l34_buffer_len] isa Int
    @test haskey(snap, :t_wall_ms)
    @test haskey(snap, :recent_events)
    @test haskey(snap, :crossover_weights)
    @test haskey(snap, :mean_D_history)
    @test snap[:mean_D_history] isa Vector{Float64}
    @test haskey(snap, :exploration_ratio_history)
    @test snap[:exploration_ratio_history] isa Vector{Float64}
    @test haskey(snap, :ws_burst_steps)
    @test snap[:ws_burst_steps] isa Int && snap[:ws_burst_steps] == 1
    j = snapshot_json(env)
    @test j isa String && occursin("\"tick\"", j)
end

@testset "recent_events_append_slice и ws_events_delta_json" begin
    r = Vector{Dict{Symbol,Any}}([
        Dict{Symbol,Any}(:a => 1, :tick_sim => UInt64(1)),
        Dict{Symbol,Any}(:a => 2, :tick_sim => UInt64(2)),
        Dict{Symbol,Any}(:a => 3, :tick_sim => UInt64(3)),
    ])
    @test length(recent_events_append_slice(r, 0)) == 3
    @test length(recent_events_append_slice(r, 2)) == 1
    @test isempty(recent_events_append_slice(r, 3))
    @test isempty(recent_events_append_slice(r, -1))

    dj = ws_events_delta_json(UInt64(5), r, 1, UInt64(9), 0.12)
    @test occursin("\"delta\"", dj)
    @test occursin("events_append", dj)
    ply = ws_events_delta_payload(UInt64(1), r, 0, UInt64(2), 0.1)
    @test ply[:delta] === true && ply[:seq] == 1 && haskey(ply, :broadcast_interval_ms)
end

@testset "L5 находит делитель для N=221" begin
    t = PollardFactoringTask(; l5_max_iter = 50_000)
    p = Dict{Symbol,Any}(:N => BigInt(221), :start_x => 2, :poly_coeff => 1)
    r, ok = Nodes.evaluate(t, p, L5)
    @test ok
    @test r == 0.0
    @test haskey(p, :_factor)
end

@testset "калибровка L3/L4 корректирует веса при систематическом перекосе" begin
    st = Settings(; analysis_calibration_min_samples = 8, analysis_calibration_buffer_max = 64)
    ta = PollardFactoringTask()
    rng = MersenneTwister(42)
    env = build_environment(ta, st; N_init = 1, shared_N = BigInt(221), rng = rng)
    w0 = copy(env.metric_weights)
    for _ = 1:24
        push_metric_l34_pair!(env, st, 0.22, 0.82)
    end
    maybe_calibration_l34_weights!(env, st)
    @test sum(env.metric_weights) ≈ 1.0 rtol = 1e-6
    @test env.metric_weights[3] < w0[3]
    @test env.metric_weights[4] > w0[4]
end

@testset "MANUAL delete_node force_resonance clear_scar set_mp_frozen" begin
    st = Settings(; cold_start_ticks = 20)
    ta = PollardFactoringTask()
    rng = MersenneTwister(1)
    env = build_environment(ta, st; N_init = 3, shared_N = BigInt(143), rng = rng)
    n_a = env.nodes[1]
    n_b = env.nodes[2]
    n_rm = env.nodes[3]
    scar_id = env.next_scar_id
    push!(
        env.scars,
        Scar(
            scar_id,
            Dict{Symbol,Any}(:start_x => -1_000_000, :poly_coeff => -1_000_000),
            0.05,
            0.4,
            2,
            0.02,
            env.tick,
        ),
    )
    env.next_scar_id += UInt64(1)
    put!(
        env.manual_events,
        Event(MANUAL; payload = Dict{Symbol,Any}(:action => :delete_node, :node_id => n_rm.id)),
    )
    drain_manual!(env, ta, st; rng)
    @test length(env.nodes) == 2
    @test isnothing(findfirst(n -> n.id == n_rm.id, env.nodes))

    put!(
        env.manual_events,
        Event(
            MANUAL;
            payload = Dict{Symbol,Any}(
                :action => :force_resonance,
                :node_a => n_a.id,
                :node_b => n_b.id,
            ),
        ),
    )
    n_before = length(env.nodes)
    drain_manual!(env, ta, st; rng)
    @test length(env.nodes) == n_before + 1

    sid_clear = UInt64(scar_id)
    @test findfirst(s -> s.id == sid_clear, env.scars) !== nothing
    put!(
        env.manual_events,
        Event(MANUAL; payload = Dict{Symbol,Any}(:action => :clear_scar, :scar_id => scar_id)),
    )
    drain_manual!(env, ta, st; rng)
    @test findfirst(s -> s.id == sid_clear, env.scars) === nothing

    victim = env.nodes[1]
    put!(
        env.manual_events,
        Event(
            MANUAL;
            payload = Dict{Symbol,Any}(
                :action => :set_mp_frozen,
                :node_id => victim.id,
                :frozen => true,
            ),
        ),
    )
    drain_manual!(env, ta, st; rng)
    @test victim.mp_frozen === true
end

@testset "резонанс: mating_history и crossover_weights после резонанса (итер. 1)" begin
    st = Settings(; cold_start_ticks = 15, crossover_learning_eta = 0.12)
    ta = PollardFactoringTask()
    rng = MersenneTwister(9)
    env = build_environment(ta, st; N_init = 2, shared_N = BigInt(221), rng = rng)
    n_a, n_b = env.nodes
    put!(
        env.manual_events,
        Event(
            MANUAL;
            payload = Dict{Symbol, Any}(
                :action => :force_resonance,
                :node_a => n_a.id,
                :node_b => n_b.id,
            ),
        ),
    )
    drain_manual!(env, ta, st; rng = rng)
    @test !isempty(n_a.mating_history)
    @test n_a.mating_history[end][1] == n_b.id
    cw1 = env.crossover_weights
    @test sum(values(cw1)) ≈ 1.0 rtol = 1e-5
end

@testset "MANUAL pause/resume и reference_pair" begin
    st = Settings(; cold_start_ticks = 30)
    ta = PollardFactoringTask(; l5_max_iter = 64)
    rng = MersenneTwister(11)
    env = build_environment(ta, st; N_init = 2, shared_N = BigInt(221), rng)
    ta0 = env.tick
    put!(env.manual_events, Event(MANUAL; payload = Dict{Symbol,Any}(:action => :pause)))
    step!(env, ta, st; rng)
    @test env.paused === true
    @test env.tick === ta0

    put!(env.manual_events, Event(MANUAL; payload = Dict{Symbol,Any}(:action => :resume)))
    step!(env, ta, st; rng)
    @test env.paused === false
    @test env.tick > ta0

    n_a, n_b = env.nodes[1], env.nodes[2]
    a0 = env.attention_tune_alpha
    b0 = env.attention_tune_beta
    g0 = env.attention_tune_gamma
    aud_n = length(env.manual_audit)
    put!(
        env.manual_events,
        Event(
            MANUAL;
            payload = Dict{Symbol, Any}(
                :action => :reference_pair,
                :node_a => n_a.id,
                :node_b => n_b.id,
                :boost_alpha => Float64(1.08),
                :boost_beta => Float64(1.09),
                :boost_gamma => Float64(1.07),
            ),
        ),
    )
    drain_manual!(env, ta, st; rng)
    @test env.attention_tune_alpha > a0
    @test env.attention_tune_beta > b0
    @test env.attention_tune_gamma > g0
    @test length(env.manual_audit) == aud_n + 1
    @test env.manual_audit[end][:action] == "reference_pair"
end

@testset "MANUAL set_tick_burst и ws_burst_steps в снапшоте" begin
    st = Settings(; cold_start_ticks = 50, dashboard_burst_steps_max = 64)
    ta = PollardFactoringTask(; l5_max_iter = 64)
    rng = MersenneTwister(11)
    env = build_environment(ta, st; N_init = 2, shared_N = BigInt(143), rng = rng)
    put!(
        env.manual_events,
        Event(MANUAL; payload = Dict{Symbol,Any}(:action => :set_tick_burst, :burst_steps => 400)),
    )
    drain_manual!(env, ta, st; rng = rng)
    @test env.ws_burst_steps == 64
    put!(
        env.manual_events,
        Event(MANUAL; payload = Dict{Symbol,Any}(:action => :set_tick_burst, :burst => 7)),
    )
    drain_manual!(env, ta, st; rng = rng)
    @test env.ws_burst_steps == 7
    snap = state_snapshot(env)
    @test snap[:ws_burst_steps] == 7
end

@testset "персист attention_tune, успешный force_resonance, mean_D_history" begin
    ta = PollardFactoringTask(; l5_max_iter = 256)

    tune_dir_sl = mktempdir()
    tune_path_sl = joinpath(tune_dir_sl, "roundtrip.json")
    env0 = build_environment(ta, Settings(; cold_start_ticks = 50); N_init = 1, rng = MersenneTwister(0))
    env0.attention_tune_alpha = 1.112
    env0.attention_tune_beta = 1.223
    env0.attention_tune_gamma = 1.334
    save_attention_tune(env0, tune_path_sl)
    env1 = build_environment(ta, Settings(; cold_start_ticks = 50); N_init = 1, rng = MersenneTwister(1))
    @test load_attention_tune!(env1, tune_path_sl)
    @test env1.attention_tune_alpha ≈ 1.112 rtol = 1e-9
    @test env1.attention_tune_beta ≈ 1.223 rtol = 1e-9
    @test env1.attention_tune_gamma ≈ 1.334 rtol = 1e-9

    tune_dir_rf = mktempdir()
    tune_path_rf = joinpath(tune_dir_rf, "autosave.json")
    st = Settings(; cold_start_ticks = 120, attention_tune_persist_path = tune_path_rf, manual_win_tune_eta = 0.02)
    rngb = MersenneTwister(1)
    env = build_environment(ta, st; N_init = 2, shared_N = BigInt(221), rng = rngb)
    g_before = env.attention_tune_gamma
    n_a, n_b = env.nodes
    put!(
        env.manual_events,
        Event(
            MANUAL;
            payload = Dict{Symbol,Any}(
                :action => :force_resonance,
                :node_a => n_a.id,
                :node_b => n_b.id,
            ),
        ),
    )
    drain_manual!(env, ta, st; rng = MersenneTwister(902))
    @test env.manual_audit[end][:child_improved] === true
    @test env.attention_tune_gamma ≈ g_before * 1.02 rtol = 1e-6
    @test isfile(tune_path_rf) && filesize(tune_path_rf) > Int64(40)

    avgD = isempty(env.nodes) ? 0.0 : sum(n.D for n in env.nodes) / length(env.nodes)
    push!(env.d_history, avgD)
    denb = env.exploitation_budget + env.exploration_budget
    r_expl = denb > 1e-12 ? clamp(env.exploration_budget / denb, 0.0, 1.0) : 0.5
    push!(env.exploration_ratio_history, r_expl)
    snap = state_snapshot(env)
    @test haskey(snap, :mean_D_history)
    @test snap[:mean_D_history][end] ≈ avgD rtol = 1e-9
    @test haskey(snap, :exploration_ratio_history)
    @test snap[:exploration_ratio_history][end] ≈ r_expl rtol = 1e-9
    @test length(snap[:exploration_ratio_history]) == length(snap[:mean_D_history])

    rm(tune_dir_sl; recursive = true)
    rm(tune_dir_rf; recursive = true)
end

@testset "validate_environment!" begin
    ta = PollardFactoringTask()
    env = build_environment(ta, Settings(); N_init = 6, rng = MersenneTwister(901))
    @test Nodes.validate_environment!(env)
end

@testset "MANUAL delete_node создаёт шрам если manual_delete_node_creates_scar" begin
    st = Settings(; cold_start_ticks = 40, manual_delete_node_creates_scar = true)
    ta = PollardFactoringTask()
    rng = MersenneTwister(903)
    env = build_environment(ta, st; N_init = 2, rng = rng)
    nod = env.nodes[2]
    n0 = length(env.scars)
    put!(
        env.manual_events,
        Event(MANUAL; payload = Dict{Symbol,Any}(:action => :delete_node, :node_id => nod.id)),
    )
    drain_manual!(env, ta, st; rng = rng)
    @test length(env.scars) == n0 + 1
end

@testset "Pollard generate_random_params с extreme_seed_fraction" begin
    ta = PollardFactoringTask()
    rng = MersenneTwister(904)
    p = Nodes.generate_random_params(
        ta,
        Scar[];
        rng = rng,
        shared_N = BigInt(221),
        extreme_seed_fraction = 1.0,
    )
    sx = Int(p[:start_x])
    pc = Int(p[:poly_coeff])
    @test (sx <= 128 || sx >= 99500) && (pc <= 40 || pc >= 920)
end

@testset "календарный ANALYSIS exclusive: первый такт только анализа" begin
    st = Nodes.Settings(; cold_start_ticks = 120, analysis_interval = 40, analysis_calendar_exclusive_slot = true)
    ta = Nodes.PollardFactoringTask(; l5_max_iter = 32)
    rng = MersenneTwister(905)
    env = Nodes.build_environment(ta, st; N_init = 6, rng = rng)
    dlen0 = length(env.d_history)
    Nodes.step!(env, ta, st; rng = rng)
    @test UInt64(env.tick) == UInt64(1)
    @test length(env.d_history) == dlen0 + 1
end

@testset "incremental_D_pollard эквивалентен полному скалярному скору D" begin
    using LinearAlgebra: dot

    ta = PollardFactoringTask(; l5_max_iter = 32)
    st_inc = Settings(; incremental_D_pollard = true, cold_start_ticks = 200)
    p = Dict{Symbol,Any}(:N => BigInt(221), :start_x => 91, :poly_coeff => 12)
    n_inc = Node(UInt64(1), copy(p); hp = 80.0, mp = 40.0)
    n_full = Node(UInt64(2), deepcopy(p); hp = 80.0, mp = 40.0)
    Nodes.warm_start!(ta, n_inc, st_inc)
    Nodes.warm_start!(ta, n_full, st_inc)
    mw_full = Float64[w for w in st_inc.metric_weights]
    k = 3
    newv = 0.37
    prevk = n_inc.metric_components[k]
    n_inc.metric_components[k] = newv
    n_full.metric_components[k] = newv
    Nodes.finalize_metric_D!(ta, n_inc, mw_full, k, st_inc; prev_at_k = prevk)
    n_full.D = clamp(dot(mw_full, n_full.metric_components), 0.0, 1.0)
    @test n_inc.D ≈ n_full.D rtol = 1e-12 atol = 1e-14
    @test n_inc.D ≈ dot(mw_full, n_inc.metric_components) rtol = 1e-12
end

@testset "повтор симуляции с одним RNG даёт одинаковый хвост" begin
    function run_trace(master::UInt64)::Tuple{Int, UInt64, Float64}
        ta = PollardFactoringTask(; l5_max_iter = 64)
        st = Settings(; cold_start_ticks = 100)
        rng = Random.Xoshiro(master)
        env = build_environment(ta, st; rng = rng, N_init = 5, shared_N = BigInt(221))
        meanD0::Float64 = isempty(env.nodes) ? 1.0 : mean(n.D for n in env.nodes)
        tick0::UInt64 = env.tick
        for _ = 1:72
            step!(env, ta, st; rng = rng)
        end
        meanD::Float64 = isempty(env.nodes) ? meanD0 : mean(n.D for n in env.nodes)
        tick1::UInt64 = env.tick
        return (
            isempty(env.nodes) ? Int(tick1) % 10007 : length(env.nodes),
            tick1 - tick0,
            meanD,
        )
    end

    @test run_trace(UInt64(9_876_543)) == run_trace(UInt64(9_876_543))
    @test run_trace(UInt64(9_876_543)) != run_trace(UInt64(9_876_544))
end

@testset "use_simulation_rng_seed задаёт сборку без учёта rng kwarg" begin
    ta = PollardFactoringTask(; l5_max_iter = 32)
    st = Settings(;
        use_simulation_rng_seed = true,
        simulation_rng_seed = UInt64(12_612_612),
        cold_start_ticks = 50,
        pollard_extreme_seed_fraction = 0.0,
    )
    e_bad = build_environment(ta, st; rng = MersenneTwister(1), N_init = 6, shared_N = BigInt(221))
    e_good =
        build_environment(ta, st; rng = MersenneTwister(9_009_009), N_init = 6, shared_N = BigInt(221))
    sig(xs) =
        sort!([
            (Int(big(x.params[:start_x])), Int(big(x.params[:poly_coeff]))) for x in xs
        ])
    @test sig(e_bad.nodes) == sig(e_good.nodes)
end

@testset "resonance_initiator_hp_floor: низкий hp не даёт парт с RESONANCE" begin
    st = Settings(; cold_start_ticks = 0, resonance_initiator_hp_floor = 500.0, default_hp = 120.0)
    ta = PollardFactoringTask(; l5_max_iter = 32)
    rng = MersenneTwister(12_081)
    env = build_environment(ta, st; N_init = 6, shared_N = BigInt(221), rng = rng)
    Nodes.rebuild_schedule!(env, ta, st; rng = rng)
    rn = 0
    while !isempty(env.event_queue)
        pr = Base.popfirst!(env.event_queue)
        ev, _ = pr.first
        if ev.type === RESONANCE
            rn += 1
        end
    end
    @test rn == 0
end

@testset "MANUAL set_active отключает SHOT узла при ребилде" begin
    st = Settings(; cold_start_ticks = 120)
    ta = PollardFactoringTask(; l5_max_iter = 32)
    rng = MersenneTwister(71_971)
    env = build_environment(ta, st; N_init = 3, shared_N = BigInt(221), rng = rng)
    nid = env.nodes[2].id
    put!(
        env.manual_events,
        Event(MANUAL; payload = Dict{Symbol,Any}(:action => :set_active, :node_id => nid, :active => false)),
    )
    drain_manual!(env, ta, st; rng = rng)
    Nodes.rebuild_schedule!(env, ta, st; rng = rng)
    saw_n = false
    while !isempty(env.event_queue)
        pr = Base.popfirst!(env.event_queue)
        ev, _ = pr.first
        if ev.node_id === nid && ev.type === SHOT
            saw_n = true
            break
        end
    end
    @test !saw_n
end

@testset "validate_environment! после симуляционных шагов" begin
    ta = PollardFactoringTask(; l5_max_iter = 64)
    st = Settings(; cold_start_ticks = 100)
    rng = Random.Xoshiro(44_883)
    env = build_environment(ta, st; N_init = 5, shared_N = BigInt(221), rng = rng)
    for _ = 1:40
        step!(env, ta, st; rng = rng)
    end
    @test Nodes.validate_environment!(env)
end
