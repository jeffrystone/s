using HTTP
using JSON3
using WebSockets

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
    return out
end

function websocket_session(env_ref::Ref{Environment}, ws, interval::Float64)
    @async begin
        while isopen(ws)
            writeguarded(ws, snapshot_json(env_ref[]))
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

function dashboard_gatekeeper(env_ref::Ref{Environment}, interval::Float64)
    function (_req, ws)
        websocket_session(env_ref, ws, interval)
    end
end

function dashboard_http_handler(html_doc::Vector{UInt8})
    function (_req)
        HTTP.Response(200; body = html_doc) |> WebSockets.Response
    end
end

"""Не блокирующий запуск сервера. Остановка: `close(serverws)`. `(serverws, task)`."""
function start_dashboard(
    env_ref::Ref{Environment};
    host::String = "127.0.0.1",
    port::Integer = 8899,
    interval::Float64 = 0.1,
)::Tuple{WebSockets.ServerWS, Task}
    html_doc = dashboard_html_bytes()
    sw = WebSockets.ServerWS(
        dashboard_http_handler(html_doc),
        dashboard_gatekeeper(env_ref, Float64(interval)),
    )
    t = @async WebSockets.serve(sw, host, Int(port))
    return (sw, t)
end
