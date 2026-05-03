using Test
using Random
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
    j = snapshot_json(env)
    @test j isa String && occursin("\"tick\"", j)
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
    snap = state_snapshot(env)
    @test haskey(snap, :mean_D_history)
    @test snap[:mean_D_history][end] ≈ avgD rtol = 1e-9

    rm(tune_dir_sl; recursive = true)
    rm(tune_dir_rf; recursive = true)
end
