# Test entry point. Runs the pure unit suite always, then the live
# integration suite when a daemon is reachable at MONGRELDB_URL.
#
#   julia --project=. test/runtests.jl

include("json_test.jl")
include("wire_shape_test.jl")
include("durable_retrieve_test.jl")

include("live_test.jl")
