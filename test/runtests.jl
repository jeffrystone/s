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

@testset "snapshot JSON" begin
    st = Settings(; cold_start_ticks = 180)
    ta = PollardFactoringTask()
    env =
        build_environment(ta, st; N_init = 2, shared_N = BigInt(143), rng = MersenneTwister(11))
    j = snapshot_json(env)
    @test j isa String
    @test occursin("\"tick\"", j)
end
