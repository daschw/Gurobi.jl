using Compat

depsfile = joinpath(dirname(@__FILE__),"deps.jl")
if isfile(depsfile)
    rm(depsfile)
end

function write_depsfile(path)
    f = open(depsfile,"w")
    println(f,"const libgurobi = \"$path\"")
    close(f)
end

aliases = ["gurobi80","gurobi75","gurobi70","gurobi65","gurobi60","gurobi56","gurobi55"]

paths_to_try = copy(aliases)

for a in aliases
    if haskey(ENV, "GUROBI_HOME")
        if Compat.Sys.isunix()
            push!(paths_to_try, joinpath(ENV["GUROBI_HOME"],"lib",string("lib",a,".so")))
        end
        if Compat.Sys.iswindows()
            push!(paths_to_try, joinpath(ENV["GUROBI_HOME"],"bin",string(a,".",Libdl.dlext)))
        end
    end
    # gurobi uses .so on OS X for some reason
    if Compat.Sys.isapple()
        push!(paths_to_try, string("lib$a.so"))
    end
end

found = false
for l in paths_to_try
    d = Libdl.dlopen_e(l)
    if d != C_NULL
        found = true
        write_depsfile(l)
        break
    end
end

if !found
    error("Unable to locate Gurobi installation. Note that this must be downloaded separately from gurobi.com")
end
