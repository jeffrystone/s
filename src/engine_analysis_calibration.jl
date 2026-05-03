"""Дополнительные пары L3/L4 в буфер калибровки с узлов без нового evaluate (ANALYSIS)."""

function maybe_push_population_l34_pairs!(
    env::Environment,
    st::Settings;
    rng::AbstractRNG,
)::Nothing
    maxp = st.analysis_population_calibration_pairs_max
    maxp <= 0 && return nothing
    isempty(env.nodes) && return nothing
    idxs = collect(eachindex(env.nodes))
    st.analysis_population_calibration_shuffle && shuffle!(rng, idxs)
    m = min(maxp, length(idxs))
    for j in 1:m
        nod = env.nodes[idxs[j]]
        push_metric_l34_pair!(env, st, nod.metric_components[3], nod.metric_components[4])
    end
    nothing
end
