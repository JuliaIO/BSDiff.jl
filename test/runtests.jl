using Test
using BSDiff
using Pkg.Artifacts

import bsdiff_jll

const test_data = artifact"test_data"

@testset "BSDiff" begin
    @testset "API coverage" begin
        # create new, old and reference patch files
        dir = mktempdir()
        old_file = joinpath(dir, "old")
        new_file = joinpath(dir, "new")
        suffix_file = joinpath(dir, "suffixes")
        write(old_file, "Goodbye, world.")
        write(new_file, "Hello, world!")
        # check API passing only two paths
        @testset "2-arg API" begin
            patch_file = bsdiff(old_file, new_file)
            new_file′ = bspatch(old_file, patch_file)
            @test read(new_file′, String) == "Hello, world!"
        end
        # check API passing all three paths
        @testset "3-arg API" begin
            patch_file = joinpath(dir, "patch")
            new_file′ = joinpath(dir, "new′")
            bsdiff(old_file, new_file, patch_file)
            bspatch(old_file, new_file′, patch_file)
            @test read(new_file′, String) == "Hello, world!"
        end
        @testset "suffixsort API" begin
            suffixsort(old_file, suffix_file)
            patch_file = bsdiff((old_file, suffix_file), new_file)
            new_file′ = bspatch(old_file, patch_file)
            @test read(new_file′, String) == "Hello, world!"
            # test that tempfile API makes the same file
            suffix_file′ = suffixsort(old_file)
            @test read(suffix_file) == read(suffix_file′)
        end
        rm(dir, recursive=true, force=true)
    end
    @testset "registry data" begin
        registry_data = joinpath(test_data, "registry")
        old = joinpath(registry_data, "before.tar")
        new = joinpath(registry_data, "after.tar")
        ref = joinpath(registry_data, "reference.diff")
        old_data = read(old)
        new_data = read(new)
        @testset "low-level API" begin
            # test that diff is identical to reference bsdiff output
            diff = sprint() do io
                BSDiff.write_diff(io, old_data, new_data)
            end |> codeunits
            # this test is unequal because the original bsdiff code is buggy:
            # it uses `memcmp(old, new, min(length(old), length(new)))` whereas
            # it should break memcmp ties by comparing the length of old & new
            @test read(ref) ≠ diff
            # test that applying reference patch to old produces new
            new_data′ = open(ref) do patch
                sprint() do new
                    BSDiff.apply_patch(old_data, patch, new, length(new_data))
                end |> codeunits
            end
            @test new_data == new_data′
        end
        if !Sys.iswindows() # bsdiff_jll doesn't compile on Windows
            @testset "high-level API" begin
                # test that bspatch command accepts patches we generate
                patch = bsdiff(old, new)
                new′ = tempname()
                bsdiff_jll.bspatch() do bspatch
                    run(`$bspatch $old $new′ $patch`)
                end
                @test new_data == read(new′)
                rm(new′)
                # test that we accept patches generated by bsdiff command
                patch = tempname()
                bsdiff_jll.bsdiff() do bsdiff
                    run(`$bsdiff $old $new $patch`)
                end
                new′ = bspatch(old, patch)
                @test new_data == read(new′)
            end
        end
    end
end
