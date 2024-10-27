using Test
using BSDiff
using ArgTools
using Pkg.Artifacts

import bsdiff_classic_jll
import bsdiff_endsley_jll
import zrl_jll

using Aqua: Aqua
Aqua.test_all(BSDiff)

const test_data = artifact"test_data"
const FORMATS = sort!(collect(keys(BSDiff.FORMATS)))

@testset "BSDiff" begin
    @testset "API coverage" begin
        # create new and old files
        dir = mktempdir()
        old_file = joinpath(dir, "old")
        new_file = joinpath(dir, "new")
        write(old_file, "Goodbye, world.")
        write(new_file, "Hello, world!")

        # generate reference index
        index_file = joinpath(dir, "index")
        index_file = bsindex(old_file)

        @testset "bsindex" begin
            arg_readers(old_file) do old
                index_file′ = @arg_test old bsindex(old)
                @test read(index_file′) == read(index_file)

                arg_writers() do index_file′, index
                    @arg_test old index begin
                        @test index == bsindex(old, index)
                    end
                    @test read(index_file′) == read(index_file)
                end
            end
        end

        for format in (nothing, :classic, :endsley)
            fmt = format == nothing ? [] : [:format => format]

            # generate and test reference patch first
            patch_file = bsdiff(old_file, new_file; fmt...)
            @testset "reference patch" begin
                new_file′ = bspatch(old_file, patch_file; fmt...)
                @test read(new_file′) == read(new_file)
                rm(new_file′)
            end

            @testset "bsdiff" begin
                arg_readers(old_file) do old
                    arg_readers(new_file) do new
                        patch_file′ = @arg_test old new begin
                            bsdiff(old, new; fmt...)
                        end
                        @test read(patch_file′) == read(patch_file)
                        rm(patch_file′)

                        arg_readers(index_file) do index
                            patch_file′ = @arg_test old index new begin
                                bsdiff((old, index), new; fmt...)
                            end
                            @test read(patch_file′) == read(patch_file)
                            rm(patch_file′)
                        end

                        arg_writers() do patch_file′, patch
                            @arg_test old new patch begin
                                @test patch == bsdiff(old, new, patch; fmt...)
                            end
                            @test read(patch_file′) == read(patch_file)
                        end
                    end
                end
            end

            @testset "bspatch" begin
                arg_readers(old_file) do old
                    arg_readers(patch_file) do patch
                        # auto-detected format
                        new_file′ = @arg_test old patch begin
                            bspatch(old, patch)
                        end
                        @test read(new_file′) == read(new_file)
                        rm(new_file′)

                        arg_writers() do new_file′, new
                            @arg_test old new patch begin
                                @test new == bspatch(old, new, patch)
                            end
                            @test read(new_file′) == read(new_file)
                        end
                        format === nothing &&
                            return # tests below are the same

                        # explicit format
                        new_file′ = @arg_test old patch begin
                            bspatch(old, patch; fmt...) # explicit format
                        end
                        @test read(new_file′) == read(new_file)
                        rm(new_file′)

                        arg_writers() do new_file′, new
                            @arg_test old new patch begin
                                @test new == bspatch(old, new, patch; fmt...)
                            end
                            @test read(new_file′) == read(new_file)
                        end
                    end
                end
            end
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
