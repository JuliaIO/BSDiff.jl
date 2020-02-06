using Test
using BSDiff
using Pkg.Artifacts

const test_data = artifact"test_data"

@testset "BSDiff" begin
    @testset "registry data" begin
        registry_data = joinpath(test_data, "registry")
        old = read(joinpath(registry_data, "before.tar"))
        new = read(joinpath(registry_data, "after.tar"))
        ref = joinpath(registry_data, "reference.diff")
        # test that diff is identical to bsdiff output
        diff = sprint() do io
            BSDiff.write_diff(io, old, new)
        end |> codeunits
        @test read(ref) == diff
        # test that patching before reproduces
        new′ = Vector{UInt8}(undef, length(new))
        open(ref) do io
            BSDiff.apply_patch(io, old, new′)
        end
        @test new == new′
    end
end
