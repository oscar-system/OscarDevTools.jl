module DevUtils

import Pkg
import LibGit2

using ..Helpers
import ..OscarCI.find_branch, ..OscarCI.github_repo_exists

export oscar_develop, oscar_update, oscar_branch, oscar_add_remotes

function fetch_project(repo::LibGit2.GitRepo)
   for remote in LibGit2.remotes(repo)
      LibGit2.fetch(repo; remote=remote)
   end
end

function add_remote(repo::LibGit2.GitRepo; fork=nothing)
   pkg = basename(LibGit2.path(repo))
   remote = isnothing(fork) ? "origin" : fork
   isnothing(LibGit2.lookup_remote(repo, remote)) || return

   @info "$pkg: adding remote '$remote'"
   url = pkg_url(pkg, fork=fork)
   if !github_repo_exists(pkg,fork)
      @warn "$pkg: no such repository at org '$fork'"
      return
   end
   LibGit2.GitRemote(repo, remote, url,
                              "+refs/heads/*:refs/remotes/$remote/*")
   LibGit2.set_remote_push_url(repo, remote, pkg_giturl(pkg, fork=fork))
   LibGit2.fetch(repo; remote=remote)
end

add_remote(pkgdir::AbstractString; kwargs...) = 
   add_remote(LibGit2.GitRepo(pkgdir); kwargs...)

function create_tracking_branch(repo::LibGit2.GitRepo, branch::AbstractString; remote::AbstractString="origin")
   pkg = basename(LibGit2.path(repo))
   @info "$pkg: creating branch '$branch' tracking from '$remote'"
   hash = LibGit2.GitHash(repo, "refs/remotes/$remote/$branch")
   LibGit2.branch!(repo, branch, string(hash); track="$remote")
   # for some reason LibGit2.jl does not set the correct upstream branch...
   LibGit2.with(LibGit2.GitConfig, repo) do cfg
      LibGit2.set!(cfg, "branch.$branch.remote", remote)
   end
end

function create_branch(repo::LibGit2.GitRepo, branch::AbstractString; start="origin/master")
   pkg = basename(LibGit2.path(repo))
   @info "$pkg: creating branch '$branch' (based on '$start')"
   fetch_project(repo)
   commit = start == "HEAD" ?
      LibGit2.head(repo) :
      LibGit2.lookup_branch(repo,"$start")
   isnothing(commit) && (commit = LibGit2.lookup_branch(repo,"$start", true))
   if !isnothing(commit)
      LibGit2.branch!(repo, branch, string(LibGit2.GitHash(commit)))
   else
      @warn "$pkg: start point '$start' not found"
   end
end

create_branch(pkgdir::AbstractString, branch; kwargs...) = create_branch(LibGit2.GitRepo(pkgdir), branch; kwargs...)

function update_project(repo::LibGit2.GitRepo)
   pkg = basename(LibGit2.path(repo))
   head = LibGit2.head(repo)
   upstream = LibGit2.upstream(head)
   if !isnothing(upstream)
      @info "$pkg: updating from '$(LibGit2.shortname(upstream))'"
      upstream = LibGit2.GitAnnotated(repo, upstream)
      fetch_project(repo)
      LibGit2.ffmerge!(repo, upstream)
   else
      @warn "$pkg: branch '$(LibGit2.shortname(head))' has no upstream"
   end
end

update_project(pkgdir::AbstractString) = update_project(LibGit2.GitRepo(pkgdir))

function checkout_branch(pkg::AbstractString, devdir::AbstractString; branch::AbstractString, fork=nothing, url=nothing)
   @info "$pkg: checkout branch '$branch'"
   # libgit2 is quite confusing...
   repo = LibGit2.GitRepo(devdir)
   LibGit2.fetch(repo; remote="origin")
   remote = LibGit2.lookup_remote(repo, isnothing(fork) ? "origin" : fork)
   # add new remote for fork if necessary
   if !isnothing(fork)
      add_remote(repo; fork=fork)
   end
   remote = LibGit2.name(remote)
   # check for branch
   commit = LibGit2.lookup_branch(repo,"$branch")
   if commit != nothing
      # switch branch and update
      LibGit2.branch!(repo, branch)
      update_project(devdir)
   else
      # create new tracking branch
      create_tracking_branch(repo, branch; remote=remote)
   end
end

function merge_branch(pkg::AbstractString, devdir::AbstractString, branch::Any)
   branch = branch == true ? "origin/master" : "$branch"
   @info "$pkg: trying to merge '$branch'"
   repo = LibGit2.GitRepo(devdir)
   fetch_project(repo)
   branch = LibGit2.GitAnnotated(repo, branch)
   if !LibGit2.merge!(repo, [branch])
      @error "$pkg: unable to merge '$branch'"
   end
end

function clone_project(pkg::AbstractString, devdir::AbstractString; branch::AbstractString, fork=nothing, url=nothing)
   @info "$pkg: cloning to '$devdir' (branch '$branch'):"
   if !isnothing(fork)
      # we create the main repo as well as the fork as upstream
      repo = LibGit2.clone(pkg_url(pkg; full=true), devdir)
      add_remote(repo; fork=fork)
      create_tracking_branch(repo, branch; remote=fork)
   else
      repo = LibGit2.clone(url, devdir, branch=branch)
   end
   LibGit2.set_remote_push_url(repo,"origin", pkg_giturl(pkg))
end

function checkout_project(pkg::AbstractString, dir::AbstractString; branch::AbstractString="master", fork=nothing, merge=false)
   (url, branch, fork) = find_branch(pkg, branch; fork=fork)
   devdir = abspath(joinpath(dir, pkg))
   if isdir(devdir)
      checkout_branch(pkg, devdir; branch=branch, fork=fork, url=url)
   else
      clone_project(pkg, devdir; branch=branch, fork=fork, url=url)
   end
   if merge !=false && (branch != "master" || !isnothing(fork))
      merge_branch(pkg, devdir, merge)
   end
   return devdir
end

function pkg_array_to_dict(pkgs::Array{String})
   pkgdict = Dict{String,Any}()
   for pkg in pkgs
      pkgre = match(r"(\w+)(?:#(.*))?", pkg)
      push!(pkgdict, pkgre[1] => pkgre[2])
   end
   return pkgdict
end

"""
    oscar_develop(pkgs::Array{String}; <keyword arguments>)
    oscar_develop(pkgs::Dict{String,Any}; <keyword arguments>)

For each of the Oscar packages given in `pkgs`, create a new checkout in `dir`,
and try to create new tracking branches for _existing_ upstream branches `branch`
(or fall back to `master`).

_Note:_ To create new branches for a new feature please use [`oscar_branch`](@ref).

If `fork` is given the branch will be looked up in `https://github.com/fork/pkg.jl`
and a second remote is created automatically; in addition to `origin` which will
always point to the main repository.

The push-urls are set to `git@github.com:org-name/PackageName.jl` to facilitate
pushing via ssh (both for `origin` and the optional `fork`).


These package checkouts are then added (dev'd) to a new julia project in `dir/project`
which you can then use by running julia with:
```
julia --project=dir/project
```

# Arguments
- `pkgs`: list of packages to operate on, please omit the `.jl`.
- `branch::String="master"`: branch for checkout.
- `dir="oscar-dev"`: development subdirectory.
- `fork=nothing`: github organisation/user for branch lookup for all packages.
- `active_repo=nothing`: used in CI to reuse the existing checkout of that package,
  corresponding to the github variable `\$GITHUB_REPOSITORY`.
- `merge=false`: used for CI: if `true` try to merge the latest `origin/master` into
  each checked out project; or any other branch if given a String specifying a `LibGit2.GitAnnotated`.
  Please note that this will not create the merge-commit (similar to `--no-commit`).

Each package name can optionally contain a branchname and a fork url:
- `PackageName#somebranch` will checkout `somebranch` from the default upstream.
- `PackageName#https://github.com/myfork/PackageName.jl#otherbranch` will use the
  `myfork` user for this package.
The package name and branch can also be given as dictionary mapping `PackageName.jl`
to `[forkurl#]branchname`.

# Examples
```julia-repl
julia> oscar_develop(["Oscar","Polymake"]; branch="some_feature")
```
```julia-repl
julia> oscar_develop(["Oscar","Singular#more_rings"]; dir="dev_more_rings")
```
"""
function oscar_develop(pkgs::Dict{String,Any}; dir=default_dev_dir, branch::AbstractString="master", fork=nothing, active_repo=nothing, merge=false)
   mkpath(dir)
   active_pkg = pkg_from_repo(active_repo)
   if isnothing(fork) && !isnothing(active_repo) && fork_from_repo(active_repo) != pkg_org(active_pkg)
      fork = fork_from_repo(active_repo)
   end
   Pkg.Registry.update()
   withenv("JULIA_PKG_DEVDIR"=>"$dir", "JULIA_PKG_PRECOMPILE_AUTO"=>0) do
      Pkg.activate(joinpath(dir,"project")) do
         @info "populating development directory '$dir':"
         try
            releases = keys(filter(pkg -> pkg.second == "release", pkgs))
            if "Oscar" in releases
               # pin oscar first to make sure to resolve for the latest release
               Pkg.add("Oscar")
               Pkg.pin("Oscar")
            end
            if length(releases) > 0
               # add all other released versions
               Pkg.add(collect(releases))
               # pin them to avoid downgrades during `develop`
               # -> pin currently disabled since pinning oscar should suffice for now
               ## Pkg.pin.(releases)
            end
            # then the currently active project
            pkgspecs = Pkg.Types.PackageSpec[]
            if !isnothing(active_pkg) && !in(active_pkg, Helpers.non_jl_repo)
               # during CI we always need to dev the active checkout
               @info "  reusing current dir for $active_pkg"
               push!(pkgspecs, Pkg.PackageSpec(path="."))
            end
            # finally add any explicitly specified branches
            # (these should be downstream of the active package)
            for (pkg, pkgbranch) in filter(pkg -> pkg.second != "release", pkgs)
               if pkg == active_pkg
                  continue
               else
                  isnothing(pkgbranch) && (pkgbranch=branch)
                  devdir = checkout_project(pkg, dir; branch=pkgbranch, fork=fork, merge=merge)
                  push!(pkgspecs, Pkg.PackageSpec(path=devdir))
               end
            end
            length(pkgspecs) > 0 && Pkg.develop(pkgspecs)
            # unpin everything again as this folder might be used for normal development now
            # length(releases) > 0 && Pkg.free.(releases)
            # -> only oscar for now, see above
            "Oscar" in releases && Pkg.free("Oscar")
         catch err
            # if we are running on github actions skip subsequent steps
            if err isa Pkg.Resolve.ResolverError && haskey(ENV,"MATRIX_CONTEXT") && haskey(ENV, "GITHUB_ENV")
               println("::error file=$(@__FILE__),line=$(@__LINE__),title=Pkg resolve failed::Skipping tests because resolving package versions failed:\n$(err.msg)")
               println("Target configuration:\n$(ENV["MATRIX_CONTEXT"])")
               open(ENV["GITHUB_OUTPUT"], "a") do io
                  println(io, "skiptests=true")
               end
               open(ENV["GITHUB_ENV"], "a") do io
                  skipmsg = """println("Tests skipped due to resolver failure.");"""
                  println(io, "oscar_run_tests=$skipmsg")
                  println(io, "oscar_run_doctests=$skipmsg")
               end
               open(ENV["GITHUB_STEP_SUMMARY"], "a") do io
                  println(io, "### ❌ Incompatible package versions")
                  println(io, "All tests were skipped.")
                  println(io, "#### Possible reasons:")
                  println(io, "- If this happens for the Oscar master branch the Project.toml might need an update to the compat entries in a matching branch.")
                  println(io, "- For the Oscar release this might be on purpose if an incompatible version bump is involved.")
                  println(io, "#### Pkg error:")
                  println(io, "```\n$(err.msg)\n```")
                  println(io, "#### Using configuration:")
                  println(io, "```\n$(ENV["MATRIX_CONTEXT"])\n```")
               end
               # exit early to avoid overriding skip-command from github_env_runtests
               exit(0)
            else
               rethrow()
            end
         end
      end
   end
   Pkg.precompile()
   if haskey(ENV, "MATRIX_CONTEXT") && haskey(ENV, "GITHUB_OUTPUT")
      open(ENV["GITHUB_OUTPUT"], "a") do io
         println(io, "skiptests=false")
      end
   else
      @info "Please start julia with:\njulia --project=$(abspath(joinpath(dir,"project")))"
   end
end

oscar_develop(pkgs::Array{String}; kwargs...) = 
   oscar_develop(pkg_array_to_dict(pkgs); kwargs...)

"""
    oscar_update(; <keyword arguments>)

For each Oscar package in `dir` fetch all remotes and do a fast forward merge
with the currently tracked upstream branch.
Similiar to doing `git pull --ff-only` in each directory.

# Arguments
- `dir="oscar-dev"`: development subdirectory.
"""
function oscar_update(; dir=default_dev_dir)
   for pkgdir in joinpath.(dir, pkg_names(dir))
      if isdir(joinpath(pkgdir,".git"))
         update_project(pkgdir)
      end
   end
   # update project after switching branches
   Pkg.activate(joinpath(dir,"project")) do
      Pkg.update()
   end
end

"""
    oscar_add_remotes(fork::String; <keyword arguments>)
    oscar_add_remotes(pkgs::Array{String}, fork::String; <keyword arguments>)

For each Oscar package in `pkgs` (or existing in `dir` if `pkgs` is not given)
add a new git remote for `https://github.com/fork/PackageName.jl`.
The push-url is set to `git@github.com:fork/PackageName.jl` to facilitate
pushing via ssh.

# Arguments
- `pkgs::Array{String}`: list of packages to operate on, please omit the `.jl`.
- `fork::String`: github organisation/user for new remote
- `dir="oscar-dev"`: development subdirectory.
"""
function oscar_add_remotes(pkgs::Array{String}, fork::AbstractString; dir=default_dev_dir)
   for pkgdir in joinpath.(dir, pkgs)
      if isdir(joinpath(pkgdir, ".git"))
         add_remote(pkgdir; fork=fork)
      end
   end
end

oscar_add_remotes(fork::AbstractString; dir=default_dev_dir) =
   oscar_add_remotes(pkg_names(dir), fork; dir=dir)


"""
    oscar_branch(branch::AbstractString; <keyword arguments>)
    oscar_branch(pkgs::Array{String}, branch::AbstractString; <keyword arguments>)

For each of the Oscar packages given in `pkgs` create a new local branch named
`branch` with start point `start`, in the working copies under the current
development directory given via `dir`.
If no `pkgs` array is given it will run on all subdirectories of `dir`.

If the directory `dir` does not exist and `pkgs is given it will checkout all
`pkgs` first by calling [`oscar_develop`](@ref).

# Arguments
- `pkgs::Array{String}`: list of packages to operate on, please omit the `.jl`.
- `branch::String`: new branch name.
- `dir="oscar-dev"`: development subdirectory.
- `start="origin/master"`: start point for the branches, use `HEAD` for the current
                           head in each directory.
"""
function oscar_branch(pkgs::Array{String}, branch::AbstractString; dir=default_dev_dir, start="origin/master")
   # if path is not there, develop it first
   if !ispath(dir)
     oscar_develop(pkgs; dir=dir)
   end
   for pkgdir in joinpath.(dir, pkgs)
      if isdir(joinpath(pkgdir, ".git"))
         create_branch(pkgdir, branch; start=start)
      end
   end
   # update project after switching branches
   Pkg.activate(joinpath(dir,"project")) do
      Pkg.update()
   end
end

oscar_branch(branch::AbstractString; dir=default_dev_dir, start="origin/master") =
   oscar_branch(pkg_names(dir), branch; dir=dir, start=start)

end
