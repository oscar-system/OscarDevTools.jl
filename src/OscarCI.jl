module OscarCI

import GitHub
import JSON
import TOML

using ..Helpers

# these are not reexported from the main module but should be easily
# accessible for the ci runner by using OscarDevTools.OscarCI

export github_auth, github_repo, github_repo_exists, find_branch,
       parse_meta, ci_matrix, github_json,
       parse_job, job_meta_env, job_pkgs, github_env_runtests

######
### defaults for julia-version, os and branches

const default_os = [ "ubuntu-latest" ]
const default_julia = [ "~1.6.0-0" ]
const default_branches = [ "master", "release" ]

### end defaults
######

global gh_auth = nothing

function github_auth(;token::AbstractString="")
   if !isempty(token)
      global gh_auth = GitHub.authenticate(token)
   elseif haskey(ENV,"GITHUB_TOKEN")
      global gh_auth = GitHub.authenticate(ENV["GITHUB_TOKEN"])
   else
      @info "Using anonymous github auth"
      global gh_auth = GitHub.AnonymousAuth()
   end
end


function github_repo(pkg::AbstractString; fork=nothing)
   isnothing(gh_auth) && github_auth()
   return GitHub.repo(pkg_url(pkg; full=false, fork=fork); auth=gh_auth)
end

function github_repo_exists(name::AbstractString, org::AbstractString)
   try
      github_repo(name; fork=org)
      return true
   catch
      return false
   end
end

parse_meta(file::AbstractString) = TOML.parsefile(file)

# we try to find a matching branch in the main repo for that pkg
# or in a given fork, or via a full 'url#branch'
function find_branch(pkg::AbstractString, branch::AbstractString; fork=nothing)
   isnothing(gh_auth) && github_auth()
   if startswith(branch, "https://")
      (pkg_fork, pkg_branch, _) = pkg_parsebranch(pkg, branch)
      return find_branch(pkg, pkg_branch; fork=pkg_fork)
   end
   @info "locating branch '$branch' for '$pkg'" * (isnothing(fork) ? "" : " (in fork '$fork')")
   if !isnothing(fork)
      try
         GitHub.reference(github_repo(pkg; fork=fork),
                                 "heads/$branch"; 
                                 auth=gh_auth)
         @info "  -> found in fork: '$fork'"
         return (pkg_url(pkg; full=true, fork=fork), branch, fork)
      catch
         @info "  -- not found in fork: '$fork'"
      end
   end
   if branch != "master"
      try
         GitHub.reference(github_repo(pkg), "heads/$branch"; auth=gh_auth)
         @info "  -> found in main repo"
         return (pkg_url(pkg; full=true), branch, nothing)
      catch
         @info "  -- not found in main repo"
      end
      @warn "  ** branch '$branch' not found, using default 'master' branch"
   end
   # fallback to master branch in default repo
   return (pkg_url(pkg; full=true), "master", nothing)
end

# generate a dict describing branches, includes, os and julia versions 
# for use in github actions
function ci_matrix(meta::Dict{String,Any}; pr=0, fork=nothing, active_repo=nothing)
   isnothing(gh_auth) && github_auth()

   matrix = Dict{String,Any}(meta["env"])
   active_pkg = pkg_from_repo(active_repo)

   # assign defaults if unset
   get!(matrix,"os",default_os)
   get!(matrix,"julia-version",default_julia)
   global_branches = copy(default_branches)

   pr_branch = ""
   if pr > 0 && !isnothing(active_pkg) && isnothing(fork)
      @info "fetching $active_pkg PR #$pr."
      ghpr = GitHub.pull_request(github_repo(active_pkg), pr; auth=gh_auth)
      # check if this comes from a fork
      if ghpr.head.ref != "master"
         if ghpr.head.repo.full_name != pkg_url(active_pkg; full=false)
            fork = ghpr.head.user.login
         end
         pr_branch = ghpr.head.ref
         pushfirst!(global_branches, pr_branch)
      else
         @warn "PR branch name 'master' cannot be used for branch autodetection"
      end
      # TODO: we might even look into pr.body and parse the branch from there?
      # e.g.: look for such a line
      # SomePkg.jl: otherUser/SomePkg.jl#branchname
   end
   
   global_axis_pkgs = []

   # for each package lookup branch with the same name in fork and main repo
   for (pkg,pkgmeta) in meta["pkgs"]
      # adjustments for first version of toml files
      # keep for compat reasons for now
      if isa(pkgmeta, Array)
         @info "legacy: mapping meta to branches"
         meta["pkgs"][pkg] = Dict("branches" => pkgmeta,
                                  "test" => pkg == "Oscar",
                                  "testoptions" => [])
         pkgmeta = meta["pkgs"][pkg]
      end

      totest = get!(pkgmeta, "test", false)
      testopts = get!(pkgmeta, "testoptions", [])

      # ignore currently active repo
      pkg == active_pkg && continue

      # add pkgs without 'branches' entry to the global pkg list
      # and dont create a separate axis
      if !haskey(pkgmeta,"branches")
         push!(global_axis_pkgs,pkg)
         continue
      end

      branches = pkgmeta["branches"]

      if !isempty(pr_branch)
         (url, branch, pkg_fork) = find_branch(pkg, pr_branch; fork=fork)
         # don't (re-)add 'master'
         if !isnothing(pkg_fork) || !in(branch,branches)
            push!(branches, isnothing(pkg_fork) ?  branch : "$url#$branch")
         end
      end
      if !isempty(branches)
         matrix[pkg] = [Dict("name" => pkg_parsebranch(pkg,branch)[3],
                             "branch" => branch,
                             "test" => totest,
                             "options" => testopts)
                           for branch in branches]
      end
   end
   if !isempty(global_axis_pkgs)
      pkgs = Dict(pkg => Dict("test" => meta["pkgs"][pkg]["test"],
                              "options" => meta["pkgs"][pkg]["testoptions"])
                  for pkg in global_axis_pkgs )
      namestr = "["*join(global_axis_pkgs,",")*"]"
      branchdicts = []
      for branch in global_branches 
         push!(branchdicts,Dict("name" => "$namestr#$branch",
                                "branch" => branch,
                                "pkgs" => deepcopy(pkgs)))
         # we need to record the fork-url for the matching branch if necessary
         if branch == pr_branch
            for (pkgname, pkgmeta) in pkgs
               (url, pkg_branch, pkg_fork) = find_branch(pkgname, branch; fork=fork)
               if !isnothing(pkg_fork)
                  branchdicts[end]["pkgs"][pkgname]["url"] = "$url#$pkg_branch"
               end
            end
         end
      end
      matrix["branches"] = branchdicts
   end
   
   # add includes for custom configurations
   matrix["include"] = []
   if haskey(meta, "include")
      for (name,inc) in meta["include"]
         named_include = Dict()
         for (key,val) in inc
            if key in ("os","julia-version")
               named_include[key] = val
            else
               named_include[key] = Dict{String,Any}(
                                                     "name" => "$(pkg_parsebranch(key,val)[3])",
                                                     "branch" => val
                                                    )
               named_include[key]["test"] = haskey(meta["pkgs"],key) ?
               meta["pkgs"][key]["test"] : false
               named_include[key]["options"] = haskey(meta["pkgs"],key) ?
               meta["pkgs"][key]["testoptions"] : []
            end
         end
         push!(matrix["include"],named_include)
      end
   end
   return matrix
end


# this allows setting a github output variable 'matrix'
# which we can then use as input for the matrix-strategy
github_json(github_matrix::Dict{String,Any}) =
   "::set-output name=matrix::" * JSON.json(github_matrix)

# extract some data from the matrix context of one job

function job_meta(job_json::AbstractString)
   job_dict = JSON.parse(job_json)
   meta = Dict{String,Any}(filter(p->(!in(p.first, ("os","julia-version","branches"))), job_dict))
   if haskey(job_dict,"branches")
      global_branch = job_dict["branches"]["branch"]
      for (pkgname, pkgmeta) in job_dict["branches"]["pkgs"]
         if !haskey(meta,pkgname)
            meta[pkgname] = Dict("branch" => get(pkgmeta,"url",
                                                 global_branch),
                                 "test" => pkgmeta["test"],
                                 "options" => pkgmeta["options"],
                                 "name" => "$pkgname#$global_branch" )
         end
      end
   end
   return meta
end

job_meta_env(var::AbstractString) = job_meta(ENV[var])

job_pkgs(job::Dict) = Dict{String,Any}(pkg => val["branch"] for (pkg,val) in job)

# keep this for now for older OscarCI.yml files
parse_job(job_json::AbstractString) = job_pkgs(job_meta(job_json))

# generate one long julia command that tests all packages with test==true
# and passes any test_args to Pkg.test
# the testcommand is then stored as an env variable an run in the next step
# (using the gitub actions `>> $GITHUB_ENV style`
# doing the tests separately via github actions syntax seems complicated
function github_env_runtests(job::Dict; varname::String, filename::String)
   testcmd = ["using Pkg;"]
   for (pkg, param) in job
      if get(param, "test", false)
         if length(get(param, "options", [])) > 0
            push!(testcmd, """Pkg.test("$pkg"; test_args=$(string.(param["options"])));""")
         else
            push!(testcmd, """Pkg.test("$pkg");""")
         end
      end
   end
   open(filename, "a") do io
      println(io, "$varname=", join(testcmd))
   end
end

end
