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
        # test that applying patch to old produces new
        new′ = open(ref) do patch
            sprint() do out
                BSDiff.apply_patch(old, patch, out, length(new))
            end |> codeunits
        end
        @test new == new′
    end
end
