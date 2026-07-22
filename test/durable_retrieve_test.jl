# Offline unit tests for 0.64 durable HLC recovery parsers.
using Test
using MongrelDB

@testset "durable HLC parse" begin
    fixture = Dict(
        "query_id" => "abcdefabcdefabcdefabcdefabcdefab",
        "status" => "committed",
        "state" => "completed",
        "server_state" => "completed",
        "terminal_state" => "committed",
        "committed" => true,
        "committed_statements" => 1,
        "last_commit_epoch" => 17,
        "last_commit_hlc" => Dict(
            "physical_micros" => 1700000000000000,
            "logical" => 3,
            "node_tiebreaker" => 7,
        ),
        "outcome" => Dict(
            "committed" => true,
            "last_commit_epoch" => 17,
            "last_commit_hlc" => Dict(
                "physical_micros" => 1700000000000000,
                "logical" => 3,
                "node_tiebreaker" => 7,
            ),
            "serialization" => "succeeded",
            "serialization_state" => "succeeded",
            "terminal_state" => "committed",
        ),
        "durable" => Dict(
            "committed" => true,
            "last_commit_epoch" => 17,
            "last_commit_hlc" => Dict(
                "physical_micros" => 1700000000000000,
                "logical" => 3,
                "node_tiebreaker" => 7,
            ),
            "serialization" => "succeeded",
            "serialization_state" => "succeeded",
            "terminal_state" => "committed",
        ),
    )
    status = parse_query_status(fixture)
    @test status.committed === true
    hlc = commit_hlc(status)
    @test hlc !== nothing
    @test hlc.physical_micros == 1700000000000000
    @test hlc.logical == 3
    @test hlc.node_tiebreaker == 7
    @test serialization_state(status) == "succeeded"
    @test status.outcome.last_commit_epoch == 17
    @test parse_commit_hlc(nothing) === nothing
    @test parse_commit_hlc(Dict()) === nothing
    @test parse_commit_hlc(Dict("logical" => 1)) === nothing
end
