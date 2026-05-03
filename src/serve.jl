using HTTP
using JSON3
using WebSockets
using Random: default_rng

mutable struct DashboardSimHandles
    task::AbstractTask
    settings::Settings
end

"""HTTP/WebSocket broadcaster and manual ingest."""

function fallback_dashboard_html()::String
    strip(raw"""
<!doctype html><html><head><meta charset="utf-8"/><title>Nodes</title></head>
<body style="margin:24px;background:#111;color:#ddd;font-family:system-ui">
<p>Не найден <code>web/index.html</code>. Откройте консоль — через WebSocket придут JSON-снимки.</p>
<pre id="log"></pre>
<script>
(function(){
  var u = location.protocol.replace("http","ws")+"//"+location.host+"/";
  var ws = new WebSocket(u);
  ws.onmessage=function(e){ var p=document.getElementById("log"); if(p)p.textContent=String(e.data).slice(0,2000); };
})();
</script></body></html>
""")
end

function dashboard_html_bytes()::Vector{UInt8}
    idx = normpath(joinpath(@__DIR__, "..", "web", "index.html"))
    isfile(idx) ? read(idx) : Vector{UInt8}(codeunits(fallback_dashboard_html()))
end

"""JSON параметров узла для MANUAL (поле `"params"`)."""
function symbolize_params!(dst::Dict{Symbol, Any}, raw::AbstractDict)
    for (kk, vv) in raw
        k = kk isa Symbol ? kk : Symbol(string(kk))
        if vv isa AbstractDict && !(vv isa AbstractVector)
            dc = Dict{Symbol,Any}()
            symbolize_params!(dc, vv)
            dst[k] = dc
        elseif vv isa AbstractVector || vv isa AbstractArray
            dst[k] = vec(collect(vv))
        elseif k === :N
            dst[k] = parse(BigInt, strip(string(vv)))
        else
            dst[k] = vv
        end
    end
    dst
end

function coerce_json_uint64(val)::Union{Nothing, UInt64}
    val === nothing && return nothing
    val isa UInt64 && return val
    val isa AbstractString && return parse(UInt64, String(val))
    val isa Integer && return UInt64(val)
    return UInt64(round(Int, Float64(val)))
end

function manual_payload_from_json(s::AbstractString)::Dict{Symbol, Any}
    d = JSON3.read(s, Dict{String,Any})
    out = Dict{Symbol,Any}()
    out[:action] = Symbol(get(d, "action", "noop"))
    if haskey(d, "params")
        pr = Dict{Symbol,Any}()
        symbolize_params!(pr, d["params"])
        out[:params] = pr
    end
    haskey(d, "hp") && (out[:hp] = Float64(get(d, "hp", 0)))
    haskey(d, "mp") && (out[:mp] = Float64(get(d, "mp", 0)))
    haskey(d, "node_id") && (out[:node_id] = coerce_json_uint64(get(d, "node_id", nothing)))
    haskey(d, "node_a") && (out[:node_a] = coerce_json_uint64(get(d, "node_a", nothing)))
    haskey(d, "node_b") && (out[:node_b] = coerce_json_uint64(get(d, "node_b", nothing)))
    haskey(d, "scar_id") && (out[:scar_id] = coerce_json_uint64(get(d, "scar_id", nothing)))
    haskey(d, "scar_index") &&
        (out[:scar_index] = round(Int, Float64(get(d, "scar_index", 1))))
    haskey(d, "frozen") && (out[:frozen] = Bool(get(d, "frozen", true)))
    if haskey(d, "burst_steps")
        out[:burst_steps] = round(Int, Float64(get(d, "burst_steps", 1)))
    elseif haskey(d, "burst")
        out[:burst_steps] = round(Int, Float64(get(d, "burst", 1)))
    end
    return out
end

function websocket_session(
    env_ref::Ref{Environment},
    ws,
    interval::Float64,
    sim::Union{Nothing,Ref{DashboardSimHandles}},
    send_event_delta::Bool,
    broadcast_metric_deltas::Bool,
)
    rng = default_rng()
    prev_ev_mt = Ref{Union{Nothing, Dict{Symbol, Float64}}}(nothing)
    prev_nd_mt = Ref{Union{Nothing, Dict{UInt64, Float64}}}(nothing)
    @async begin
        seq::UInt64 = 0
        while isopen(ws)
            seq += UInt64(1)
            env = env_ref[]
            len_before_snap::Int = length(env.recent_events)
            if broadcast_metric_deltas
                writeguarded(
                    ws,
                    snapshot_json_with_broadcast_metric_deltas(env, prev_ev_mt, prev_nd_mt),
                )
            else
                writeguarded(ws, snapshot_json(env))
            end
            if sim !== nothing && !env.paused
                h = sim[]
                nb = max(0, env.ws_burst_steps)
                for _ = 1:nb
                    step!(env, h.task, h.settings; rng)
                end
            end
            if send_event_delta
                env2 = env_ref[]
                writeguarded(
                    ws,
                    ws_events_delta_json(
                        seq,
                        env2.recent_events,
                        len_before_snap,
                        UInt64(env2.tick),
                        interval,
                    ),
                )
            end
            Base.sleep(interval)
        end
    end
    while isopen(ws)
        data, ok = readguarded(ws)
        !ok || isempty(data) || break
        try
            pl = manual_payload_from_json(String(copy(data)))
            put!(
                env_ref[].manual_events,
                Event(MANUAL; manual = true, payload = copy(pl)),
            )
        catch err
            @warn "manual JSON skipped" exception = (err, catch_backtrace())
        end
    end
end

function dashboard_gatekeeper(
    env_ref::Ref{Environment},
    interval::Float64,
    sim::Union{Nothing,Ref{DashboardSimHandles}},
    send_event_delta::Bool,
    broadcast_metric_deltas::Bool,
)
    function (_req, ws)
        websocket_session(
            env_ref,
            ws,
            interval,
            sim,
            send_event_delta,
            broadcast_metric_deltas,
        )
    end
end

function dashboard_js_bytes()::Vector{UInt8}
    p = normpath(joinpath(@__DIR__, "..", "web", "dashboard_app.js"))
    isfile(p) ? Vector{UInt8}(read(p)) : UInt8[]
end

function dashboard_request_path(req::HTTP.Request)::String
    s = req.target isa String ? String(req.target) : String(req.target)
    parts = split(s, '?'; limit = 2)
    isempty(parts[1]) && return "/"
    String(parts[1])
end

function dashboard_http_handler(html_doc::Vector{UInt8}, js_doc::Vector{UInt8})
    function (req::HTTP.Request)
        p = dashboard_request_path(req)
        if basename(String(p)) == "dashboard_app.js"
            isempty(js_doc) &&
                return HTTP.Response(
                    404;
                    body = Vector{UInt8}(codeunits("// dashboard_app.js missing")),
                ) |> WebSockets.Response
            return HTTP.Response(
                    200;
                    headers = ["Content-Type" => "application/javascript; charset=utf-8"],
                    body = js_doc,
                ) |>
                   WebSockets.Response
        end
        return HTTP.Response(200; body = html_doc) |> WebSockets.Response
    end
end

"""Не блокирующий запуск сервера. Остановка: `close(serverws)`. `(serverws, task)`."""
function start_dashboard(
    env_ref::Ref{Environment};
    host::String = "127.0.0.1",
    port::Integer = 8899,
    interval::Float64 = 0.1,
    auto_step::Bool = false,
    sim::Union{Nothing,Ref{DashboardSimHandles}} = nothing,
    send_event_delta::Bool = false,
    broadcast_metric_deltas::Bool = false,
)::Tuple{WebSockets.ServerWS, Task}
    sim_ref::Union{Nothing,Ref{DashboardSimHandles}} =
        (auto_step && sim !== nothing) ? sim : nothing
    if auto_step && sim === nothing
        @warn "auto_step=true но sim не передан; цикл только шлёт снимки без step!"
    end
    html_doc = dashboard_html_bytes()
    js_doc = dashboard_js_bytes()
    sw = WebSockets.ServerWS(
        dashboard_http_handler(html_doc, js_doc),
        dashboard_gatekeeper(
            env_ref,
            Float64(interval),
            sim_ref,
            send_event_delta,
            broadcast_metric_deltas,
        ),
    )
    t = @async WebSockets.serve(sw, host, Int(port))
    return (sw, t)
end
