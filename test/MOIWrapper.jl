using Gurobi, Base.Test, MathOptInterface, MathOptInterface.Test

const MOI  = MathOptInterface
const MOIT = MathOptInterface.Test
const MOIB = MathOptInterface.Bridges

@testset "Unit Tests" begin
    config = MOIT.TestConfig()
    solver = GurobiOptimizer(OutputFlag=0)

    MOIT.basic_constraint_tests(solver, config)

    MOIT.unittest(solver, config,
        ["solve_affine_interval", "solve_qcp_edge_cases"]
    )

    @testset "solve_affine_interval" begin
        MOIT.solve_affine_interval(
            MOIB.SplitInterval{Float64}(GurobiOptimizer(OutputFlag=0)),
            config
        )
    end

    @testset "solve_qcp_edge_cases" begin
        MOIT.solve_qcp_edge_cases(solver,
            MOIT.TestConfig(atol=1e-4)
        )
    end

    MOIT.modificationtest(solver, config, [
        "solve_func_scalaraffine_lessthan"
    ])
end

@testset "Linear tests" begin
    linconfig = MOIT.TestConfig()
    @testset "Default Solver"  begin
        solver = GurobiOptimizer(OutputFlag=0)
        MOIT.contlineartest(solver, linconfig, [
            # linear10 requires interval
            "linear10",
            # these require infeasibility certificates
            "linear8a", "linear8b", "linear8c", "linear12"]
        )
    end
    @testset "InfUnbdInfo=1" begin
        solver_nopresolve = GurobiOptimizer(OutputFlag=0, InfUnbdInfo=1)
        MOIT.linear8atest(solver_nopresolve, linconfig)
        MOIT.linear8btest(solver_nopresolve, linconfig)
        MOIT.linear8ctest(solver_nopresolve, linconfig)
    end
    @testset "No certificate" begin
        solver = GurobiOptimizer(OutputFlag=0)
        MOIT.linear12test(solver, MOIT.TestConfig(infeas_certificates=false))
    end
    @testset "Interval Bridge" begin
        MOIT.linear10test(
            MOIB.SplitInterval{Float64}(GurobiOptimizer(OutputFlag=0)),
            linconfig
        )
    end
end

@testset "Quadratic tests" begin
    quadconfig = MOIT.TestConfig(atol=1e-4, rtol=1e-4, duals=false, query=false)
    solver = GurobiOptimizer(OutputFlag=0)
    MOIT.contquadratictest(solver, quadconfig)
end

@testset "Linear Conic tests" begin
    linconfig = MOIT.TestConfig()
    solver = GurobiOptimizer(OutputFlag=0)
    MOIT.lintest(solver, linconfig, ["lin3","lin4"])

    solver_nopresolve = GurobiOptimizer(OutputFlag=0, InfUnbdInfo=1)
    MOIT.lintest(solver_nopresolve, linconfig)
end

@testset "Integer Linear tests" begin
    intconfig = MOIT.TestConfig()
    solver = GurobiOptimizer(OutputFlag=0)
    MOIT.intlineartest(solver, intconfig, ["int3"])
    @testset "int3" begin
        MOIT.int3test(
            MOIB.SplitInterval{Float64}(GurobiOptimizer(OutputFlag=0)),
            intconfig
        )
    end
end
@testset "ModelLike tests" begin
    solver = GurobiOptimizer()
    @testset "nametest" begin
        MOIT.nametest(solver)
    end
    @testset "validtest" begin
        MOIT.validtest(solver)
    end
    @testset "emptytest" begin
        MOIT.emptytest(solver)
    end
    @testset "orderedindicestest" begin
        MOIT.orderedindicestest(solver)
    end
    @testset "canaddconstrainttest" begin
        MOIT.canaddconstrainttest(solver, Float64, Complex{Float64})
    end
    @testset "copytest" begin
        solver2 = GurobiOptimizer()
        MOIT.copytest(solver,solver2)
    end
end

@testset "Gurobi Callback" begin
    @testset "Generic callback" begin
        m = GurobiOptimizer(OutputFlag=0)
        x = MOI.addvariable!(m)
        MOI.addconstraint!(m, MOI.SingleVariable(x), MOI.GreaterThan(1.0))
        MOI.set!(m, MOI.ObjectiveFunction{MOI.ScalarAffineFunction{Float64}}(),
            MOI.ScalarAffineFunction{Float64}(
                [MOI.ScalarAffineTerm{Float64}(1.0, x)],
                0.0
            )
        )

        cb_calls = Int32[]
        function callback_function(cb_data::Gurobi.CallbackData, cb_where::Int32)
            push!(cb_calls, cb_where)
            nothing
        end

        MOI.set!(m, Gurobi.CallbackFunction(), callback_function)
        MOI.optimize!(m)

        @test length(cb_calls) > 0
        @test Gurobi.CB_MESSAGE in cb_calls
        @test Gurobi.CB_PRESOLVE in cb_calls
        @test !(Gurobi.CB_MIPSOL in cb_calls)
    end

    @testset "Lazy cut" begin
        m = GurobiOptimizer(OutputFlag=0, Cuts=0, Presolve=0, Heuristics=0, LazyConstraints=1)
        MOI.Utilities.loadfromstring!(m,"""
            variables: x, y
            maxobjective: y
            c1: x in Integer()
            c2: y in Integer()
            c3: x in Interval(0.0, 2.0)
            c4: y in Interval(0.0, 2.0)
        """)
        x = MOI.get(m, MOI.VariableIndex, "x")
        y = MOI.get(m, MOI.VariableIndex, "y")

        # We now define our callback function that takes two arguments:
        #   (1) the callback handle; and
        #   (2) the location from where the callback was called.
        # Note that we can access m, x, and y because this function is defined
        # inside the same scope
        cb_calls = Int32[]
        function callback_function(cb_data::Gurobi.CallbackData, cb_where::Int32)
            push!(cb_calls, cb_where)
            if cb_where == Gurobi.CB_MIPSOL
                Gurobi.loadcbsolution!(m, cb_data, cb_where)
                x_val = MOI.get(m, MOI.VariablePrimal(), x)
                y_val = MOI.get(m, MOI.VariablePrimal(), y)
                # We have two constraints, one cutting off the top
                # left corner and one cutting off the top right corner, e.g.
                # (0,2) +---+---+ (2,2)
                #       |xx/ \xx|
                #       |x/   \x|
                #       |/     \|
                # (0,1) +       + (2,1)
                #       |       |
                # (0,0) +---+---+ (2,0)
                TOL = 1e-6  # Allow for some impreciseness in the solution
                if y_val - x_val > 1 + TOL
                    Gurobi.cblazy!(cb_data, m,
                        MOI.ScalarAffineFunction{Float64}(
                            MOI.ScalarAffineTerm.([-1.0, 1.0], [x, y]),
                            0.0
                        ),
                        MOI.LessThan{Float64}(1.0)
                    )
                elseif y_val + x_val > 3 + TOL
                    Gurobi.cblazy!(cb_data, m,
                        MOI.ScalarAffineFunction{Float64}(
                            MOI.ScalarAffineTerm.([1.0, 1.0], [x, y]),
                            0.0
                        ),
                        MOI.LessThan{Float64}(3.0)
                    )
                end
            end
        end

        MOI.set!(m, Gurobi.CallbackFunction(), callback_function)
        MOI.optimize!(m)

        @test MOI.get(m, MOI.VariablePrimal(), x) == 1
        @test MOI.get(m, MOI.VariablePrimal(), y) == 2

        @test length(cb_calls) > 0
        @test Gurobi.CB_MESSAGE in cb_calls
        @test Gurobi.CB_PRESOLVE in cb_calls
        @test Gurobi.CB_MIPSOL in cb_calls
    end
end
