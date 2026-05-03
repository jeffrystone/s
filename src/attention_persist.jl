using JSON3

"""Сохранить `attention_tune_alpha/beta/gamma` в JSON (атомарная замена файла)."""
function save_attention_tune(env::Environment, path::AbstractString)
    dst = abspath(String(path))
    dir = dirname(dst)
    isdir(dir) || mkpath(dir)
    payload = Dict{String,Any}(
        "attention_tune_alpha" => Float64(env.attention_tune_alpha),
        "attention_tune_beta" => Float64(env.attention_tune_beta),
        "attention_tune_gamma" => Float64(env.attention_tune_gamma),
        "tick_sim" => UInt64(env.tick),
    )
    tmp = tempname(dir; suffix = ".json")
    try
        io = open(tmp, "w")
        try
            JSON3.write(io, payload)
        finally
            close(io)
        end
        mv(tmp, dst; force = true)
    catch
        rm(tmp; force = true)
        rethrow()
    end
    return dst
end

"""Загрузить множители внимания из JSON."""
function load_attention_tune!(env::Environment, path::AbstractString)::Bool
    p = abspath(String(path))
    isfile(p) || return false
    d = JSON3.read(read(p, String))
    env.attention_tune_alpha = clamp(Float64(d["attention_tune_alpha"]), 0.2, 6.0)
    env.attention_tune_beta = clamp(Float64(d["attention_tune_beta"]), 0.2, 6.0)
    env.attention_tune_gamma = clamp(Float64(d["attention_tune_gamma"]), 0.2, 6.0)
    return true
end

"""Если задан путь в `Settings`, сохранить тюны после MANUAL-сдвигов."""
function maybe_save_attention_tune!(env::Environment, st::Settings)::Nothing
    path = st.attention_tune_persist_path
    (path isa String && !isempty(strip(path))) || return nothing
    try
        save_attention_tune(env, path)
    catch err
        @warn "attention_tune persist failed" path exception = err
    end
    return nothing
end
