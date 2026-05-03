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
