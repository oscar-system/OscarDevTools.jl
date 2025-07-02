######
### defaults for julia-version, os and branches

const default_os = [ "ubuntu-latest" ]
const default_julia = [ "~1.10.0-0" ]
const default_branches = [ "<matching>", "release" ]

# for each package this contains an ordered list with
# pkg-version -> pair of lower and upper bound, more precisely:
# if pkgversion >= $version then check $lower <= julia_version < $upper
# newest entries should come first
# if no matching version is found the doctests will run with julia 1.6
const doctest_versions = Dict(
    :Oscar           => [v"0.14.0-DEV" => (v"1.10", v"1.12"),
                         v"0.13.0-DEV" => (v"1.9" , v"1.11"),
                         v"0.12.1-DEV" => (v"1.8" , v"1.11")],
    :Hecke           => [v"0.24.1"     => (v"1.10", v"1.11"),
                         v"0.19.5"     => (v"1.9" , v"1.10"),
                         v"0.16.7"     => (v"1.8" , v"1.9" )],
    :AbstractAlgebra => [v"0.35.3"     => (v"1.10", v"1.11"),
                         v"0.31.0"     => (v"1.9" , v"1.10"),
                         v"0.29.5"     => (v"1.8" , v"1.9" )],
    :Nemo            => [v"0.40.0"     => (v"1.10", v"1.11"),
                         v"0.35.1"     => (v"1.9" , v"1.10"),
                         v"0.33.8"     => (v"1.8" , v"1.9" )],
    :Singular        => [v"0.21.3"     => (v"1.10", v"1.11"),
                         v"0.18.8"     => (v"1.9" , v"1.10"),
                         v"0.18.3"     => (v"1.8" , v"1.9" )],
  )

### end defaults
######
