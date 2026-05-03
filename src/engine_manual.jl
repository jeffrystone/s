function handle_manual!(
    env::Environment,
    task::AbstractTask,
    st::Settings,
    ev::Event;
    rng::AbstractRNG,
)
    pl = ev.payload
    action = Symbol(get(pl, :action, :noop))
    aud =
        Dict{Symbol, Any}(:tick_sim => UInt64(env.tick), :action => String(action))

    if action === :delete_node
        nid = UInt64(get(pl, :node_id, UInt64(0)))
        nd = fetch_node(env.nodes, nid)
        if nd !== nothing && st.manual_delete_node_creates_scar
            cen, rad, fv, dec = failure_scar_meta(task, nd.params)
            push!(
                env.scars,
                Scar(
                    env.next_scar_id,
                    cen,
                    rad,
                    1.0,
                    fv,
                    dec,
                    UInt64(env.tick),
                ),
            )
            env.next_scar_id += UInt64(1)
        end
        filter!(n -> n.id != nid, env.nodes)
    elseif action === :force_resonance
        a = UInt64(get(pl, :node_a, UInt64(0)))
        b = UInt64(get(pl, :node_b, UInt64(0)))
        r = perform_resonance_between!(env, task, st, rng, a, b)
        aud[:child_improved] = r.child_improved
        if st.manual_win_tune_enabled && r.child_improved
            η = st.manual_win_tune_eta
            if st.manual_win_tune_gamma_only
                env.attention_tune_gamma *= (1.0 + η)
            else
                env.attention_tune_alpha *= (1.0 + η * 0.55)
                env.attention_tune_beta *= (1.0 + η * 0.55)
                env.attention_tune_gamma *= (1.0 + η)
            end
            maybe_save_attention_tune!(env, st)
        end
    elseif action === :clear_scar
        sid = UInt64(get(pl, :scar_id, UInt64(0)))
        filter!(s -> s.id != sid, env.scars)
    elseif action === :set_active
        nid = UInt64(get(pl, :node_id, UInt64(0)))
        act = Bool(get(pl, :active, true))
        nd = fetch_node(env.nodes, nid)
        nd !== nothing && (nd.active = act)
    elseif action === :set_mp_frozen
        nid = UInt64(get(pl, :node_id, UInt64(0)))
        fr = Bool(get(pl, :frozen, true))
        nd = fetch_node(env.nodes, nid)
        if nd !== nothing
            nd.mp_frozen = fr
        end
    elseif action === :pause
        env.paused = true
    elseif action === :resume
        env.paused = false
    elseif action === :reference_pair
        env.attention_tune_alpha *= Float64(get(pl, :boost_alpha, 1.02))
        env.attention_tune_beta *= Float64(get(pl, :boost_beta, 1.02))
        env.attention_tune_gamma *= Float64(get(pl, :boost_gamma, 1.02))
        maybe_save_attention_tune!(env, st)
    elseif action === :set_tick_burst
        bs = if haskey(pl, :burst_steps)
            Int(round(Float64(get(pl, :burst_steps, 1))))
        else
            Int(round(Float64(get(pl, :burst, 1))))
        end
        env.ws_burst_steps = clamp(bs, 1, st.dashboard_burst_steps_max)
    elseif action === :add_node
        sh =
            isempty(env.nodes) ? big(221) :
            big(get(env.nodes[1].params, :N, BigInt(221)))
        base_p = generate_random_params(
            task,
            env.scars;
            rng = rng,
            shared_N = sh,
            extreme_seed_fraction = st.pollard_extreme_seed_fraction,
        )
        pr = get(pl, :params, base_p)
        pr = pr isa Dict{Symbol, Any} ? pr : base_p
        hp = Float64(get(pl, :hp, st.default_hp))
        mp = Float64(get(pl, :mp, st.default_mp))
        nid = env.next_id
        env.next_id += UInt64(1)
        nn = Node(nid, copy(pr); hp = hp, mp = mp, D = 0.5)
        warm_start!(task, nn, st)
        push!(env.nodes, nn)
    end

    push!(env.manual_audit, aud)
    record_recent_event!(
        env,
        st,
        Dict{Symbol, Any}(
            :tick_sim => UInt64(env.tick),
            :type => "MANUAL",
            :action => String(action),
        ),
    )
    nothing
end

function drain_manual!(
    env::Environment,
    task::AbstractTask,
    st::Settings;
    rng::AbstractRNG = default_rng(),
)
    while isready(env.manual_events)
        ev = take!(env.manual_events)
        ev.type === MANUAL || continue
        handle_manual!(env, task, st, ev; rng = rng)
    end
    nothing
end
