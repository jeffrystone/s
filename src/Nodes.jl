module Nodes

export Node,
       Scar,
       Environment,
       Event,
       EventType,
       SHOT,
       HEAVY_SHOT,
       RESONANCE,
       ANALYSIS,
       MANUAL,
       MetricLevel,
       L1,
       L2,
       L3,
       L4,
       L5,
       Settings,
       AbstractTask,
       evaluate,
       normalize,
       crossover,
       embed,
       supports_embed,
       generate_random_params,
       failure_scar_meta,
       params_forbidden_by_scars,
       PollardFactoringTask,
       build_environment,
       step!,
       simulate!,
       state_snapshot,
       snapshot_json,
       start_dashboard,
       greet,
       push_metric_l34_pair!,
       maybe_calibration_l34_weights!,
       drain_manual!

include("types.jl")
include("config.jl")
include("task_api.jl")


include(joinpath("tasks", "pollard.jl"))

include("engine.jl")
include("snapshot.jl")
include("serve.jl")

greet() =
    "Nodes.jl: движок планирования Pollard-симуляция + WebSocket-бродкаст доступен через start_dashboard(...)"

end
