using Test
using OscarDevTools
using OscarDevTools.OscarCI
using JSON

@testset "cimatrix from meta-files" verbose=true begin
   for file in readdir("meta")
      if endswith(file, ".toml")
         println("checking $file")
         ciprefs = parse_meta(joinpath("meta",file));
         res = JSON.parsefile(joinpath("result",replace(file,".toml"=>".json")))
         prnum = get(res, "prnumber", 0)
         repo = get(res, "repo", "oscar-system/OscarDevTools.jl")

         cimat = ci_matrix(ciprefs; pr=prnum, active_repo = repo)
         @test cimat == res["cimat"]
      end
   end
end
