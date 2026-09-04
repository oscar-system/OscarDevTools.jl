using Pkg;

include("defaults.jl")

# checks the currently running julia version if it matches the
# version required for the doctests of a given package

function allow_doctests(pkg::Symbol, julia_version=VERSION)
   dep = first(filter(d->d.name == string(pkg), collect(values(Pkg.dependencies()))))
   docs_mode = :doctest
   if pkg === :Oscar && dep.version > v"1.7.0"
      docs_mode = :test_and_build
   end

   if haskey(doctest_versions, pkg)
      for (pv, jvb) in doctest_versions[pkg]
         if dep.version >= pv
            return first(jvb) <= julia_version < last(jvb) ? docs_mode : nothing
         end
      end
   end

   # fallback to LTS
   return v"1.10" <= julia_version < v"1.11" ? docs_mode : nothing
end

function doctest_cmd(pkg::Symbol; docs_mode=:doctest)
   mod = getproperty(@__MODULE__, pkg)
   setup = QuoteNode(isdefined(mod, :doctestsetup) ? mod.doctestsetup() : :(using $(pkg)))
   filters = isdefined(mod, :doctestfilters) ? mod.doctestfilters() : []
   docmeta = isdefined(mod, :docmeta) ? mod.docmeta() : Dict{Symbol, Any}()
   docbuild = pkg === :Oscar && docs_mode === :test_and_build ?
      :( Oscar.build_doc(; doctest=false, warnonly=false, open_browser=false) ) : :()
   return quote
             DocMeta.setdocmeta!($pkg, :DocTestSetup, $setup; recursive = true); doctest($pkg; doctestfilters=$filters, meta=$docmeta); $docbuild;
          end
end

macro maybe_doctest(pkg::Symbol)
   docs_mode = allow_doctests(pkg)
   if docs_mode !== nothing
      return doctest_cmd(pkg; docs_mode)
   else
      msg = "Skipping doctest for $pkg due to julia version ($VERSION) mismatch."
      if haskey(ENV, "GITHUB_STEP_SUMMARY")
         open(ENV["GITHUB_STEP_SUMMARY"], "a") do io
            println(io, msg)
         end
      else
         println(msg)
      end
      return nothing
   end
end

# we include this even when oscar is not tested to add some debug output for
# printing the doctests and to allow testing of experimental oscar projects
# (via documenter - walkdir hack)
oscdep = filter(x -> x.name == "Oscar", collect(values(Pkg.dependencies())))
if !isempty(oscdep)
   doc_helpers = joinpath(first(oscdep).source, "docs", "documenter_helpers.jl")
   if isfile(doc_helpers)
      include(doc_helpers)
   end
end
