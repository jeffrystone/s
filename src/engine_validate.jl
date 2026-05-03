"""Инварианты среды для тестов и отладки (не вызывать в горячем цикле по умолчанию)."""
function validate_environment!(env::Environment)::Bool
    seen = Set{UInt64}()
    nid_max = UInt64(0)
    for n in env.nodes
        if n.id in seen
            return false
        end
        push!(seen, n.id)
        nid_max = max(nid_max, n.id)
    end
    env.next_id > nid_max || return false

    sseen = Set{UInt64}()
    sid_max = UInt64(0)
    for s in env.scars
        if s.id in sseen
            return false
        end
        push!(sseen, s.id)
        sid_max = max(sid_max, s.id)
    end
    env.next_scar_id > sid_max || return false

    env.exploitation_budget < 0 && return false
    env.exploration_budget < 0 && return false
    env.ws_burst_steps < 1 && return false

    nw = env.metric_weights
    length(nw) == 5 || return false
    sw = sum(nw)
    (sw <= 0 || abs(sw - 1.0) > 0.2) && return false
    true
end
