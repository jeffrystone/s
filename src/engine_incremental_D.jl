"""§8 опционально: точечное обновление `D`, если затронут один уровень и задача допускает (Pollard под флагом)."""

function finalize_metric_D!(
    task::AbstractTask,
    node::Node,
    mw::AbstractVector,
    k::Int,
    st::Settings;
    prev_at_k::Union{Nothing, Float64} = nothing,
)::Nothing
    lk = clamp(k, 1, 5)
    if prev_at_k !== nothing &&
       st.incremental_D_pollard &&
       task isa PollardFactoringTask &&
       length(mw) >= 5 &&
       length(node.metric_components) >= 5
        dk = mw[lk] * (node.metric_components[lk] - prev_at_k)
        node.D = clamp(node.D + dk, 0.0, 1.0)
        return nothing
    end
    recompute_D!(node, mw)
    nothing
end
