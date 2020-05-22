using Test
using BSDiff
using Pkg.Artifacts

import bsdiff_classic_jll
import bsdiff_endsley_jll
import zrl_jll

println("LOWMEM: ", get(ENV, "JULIA_BSDIFF_LOWMEM", "false"))

const test_data = artifact"test_data"
const FORMATS = sort!(collect(keys(BSDiff.FORMATS)))

readers(file) = [
    f -> f(file),
    f -> f(file), # open(f, file),
    f -> f(file), # open(f, `cat $file`),
]
writers(file) = [
    f -> f(file),
    f -> f(file), # open(f, file, write=true),
    f -> f(file), # open(f, pipeline(`cat`, file), write=true),
]

@testset "BSDiff" begin
    @testset "API coverage" begin
        # create new, old and reference patch files
        dir = mktempdir()
        old_file = joinpath(dir, "old")
        new_file = joinpath(dir, "new")
        index_file = joinpath(dir, "index")
        write(old_file, "Goodbye, world.")
        write(new_file, "Hello, world!")
        for format in (nothing, :classic, :endsley)
            @show format
            fmt = format == nothing ? [] : [:format => format]
            # check API passing only two paths
            @testset "2-arg API" begin
                for old in readers(old_file),
                    new in readers(new_file)
                    patch_file = old() do old; new() do new
                    bsdiff(old, new; fmt...)
                    end; end
                    for patch in readers(patch_file)
                        new_file′ = old() do old; patch() do patch
                        bspatch(old, patch; fmt...)
                        end; end
                        @test read(new_file′, String) == "Hello, world!"
                        new_file′ = old() do old; patch() do patch
                        bspatch(old, patch) # format auto-detected
                        end; end
                        @test read(new_file′, String) == "Hello, world!"
                    end
                end
            end
            # check API passing all three paths
            @testset "3-arg API" begin
                patch_file = joinpath(dir, "patch")
                new_file′ = joinpath(dir, "new′")
                for old in readers(old_file),
                    new in readers(new_file),
                    patch in writers(patch_file)
                    old() do old; new() do new; patch() do patch
                        bsdiff(old, new, patch; fmt...)
                    end; end; end
                    for new′ in writers(new_file′),
                        patch in readers(patch_file)
                        old() do old; new′() do new′; patch() do patch
                            bspatch(old, new′, patch; fmt...)
                        end; end; end
                        @test read(new_file′, String) == "Hello, world!"
                        old() do old; new′() do new′; patch() do patch
                            bspatch(old, new′, patch) # format auto-detected
                        end; end; end
                        @test read(new_file′, String) == "Hello, world!"
                    end
                end
            end
            @testset "bsindex API" begin
                for old in readers(old_file),
                    index in writers(index_file)
                    old() do old; index() do index
                        bsindex(old, index)
                    end; end
                    for index in readers(index_file),
                        new in readers(new_file)
                        patch_file = old() do old; index() do index; new() do new
                        bsdiff((old, index), new; fmt...)
                        end; end; end
                        new_file′ = old() do old
                        bspatch(old, patch_file; fmt...)
                        end
                        @test read(new_file′, String) == "Hello, world!"
                    end
                    # test that 1-arg API makes the same file
                    index_file′ = old() do old
                    bsindex(old)
                    end
                    @test read(index_file) == read(index_file′)
                end
            end
            GC.gc(true)
            GC.gc(true)
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
        @testset "hi-level API (w/ timing)" for format in FORMATS
            println("[ raw data ]")
            @show format
            index = bsindex(old)
            patch = @time bsdiff((old, index), new, format = format)
            patch = @time bsdiff((old, index), new, format = format)
            patch = @time bsdiff((old, index), new, format = format)
            new′ = bspatch(old, patch)
            @test read(new) == read(new′)
            @show filesize(patch)
        end
        @testset "ZRL data (w/timing)" for format in FORMATS
            println("[ ZRL data ]")
            @show format
            old_zrl = tempname()
            new_zrl = tempname()
            zrl_jll.zrle() do zrle
                run(pipeline(`$zrle $old`, old_zrl))
                run(pipeline(`$zrle $new`, new_zrl))
            end
            index = bsindex(old_zrl)
            patch = @time bsdiff((old_zrl, index), new_zrl, format = format)
            patch = @time bsdiff((old_zrl, index), new_zrl, format = format)
            patch = @time bsdiff((old_zrl, index), new_zrl, format = format)
            new_zrl′ = bspatch(old_zrl, patch)
            @test read(new_zrl) == read(new_zrl′)
            @show filesize(patch)
            rm(old_zrl)
            rm(new_zrl)
        end
        @testset "low-level API" begin
            # test that diff is identical to reference diff
            index = BSDiff.generate_index(old_data)
            diff = sprint() do io
                patch = BSDiff.EndsleyPatch(io, length(new_data))
                BSDiff.generate_patch(patch, old_data, new_data, index)
            end |> codeunits
            @test read(ref) == diff
            # test that applying reference patch to old produces new
            new_data′ = open(ref) do io
                patch = BSDiff.EndsleyPatch(io, length(new_data))
                sprint() do new_io
                    BSDiff.apply_patch(patch, old_data, new_io)
                end |> codeunits
            end
            @test new_data == new_data′
        end
        if !Sys.iswindows() # bsdiff JLLs don't compile on Windows
            for (format, jll) in [
                    (:classic, bsdiff_classic_jll),
                    (:endsley, bsdiff_endsley_jll),
                ]
                @testset "high-level API" begin
                    # test that bspatch command accepts patches we generate
                    patch = bsdiff(old, new, format = format)
                    new′ = tempname()
                    jll.bspatch() do bspatch
                        run(`$bspatch $old $new′ $patch`)
                    end
                    @test new_data == read(new′)
                    rm(new′)
                    # test that we accept patches generated by bsdiff command
                    patch = tempname()
                    jll.bsdiff() do bsdiff
                        run(`$bsdiff $old $new $patch`)
                    end
                    new′ = bspatch(old, patch, format = format)
                    @test new_data == read(new′)
                    new′ = bspatch(old, patch) # format auto-detected
                    @test new_data == read(new′)
                end
            end
        end
    end
end
