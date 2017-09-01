
mutable struct ChanceConstrainedOPF
    model::JuMP.Model
    p
    α
end

function ChanceConstrainedOPF(
        ref::NetworkReference,
        solver::MathProgBase.AbstractMathProgSolver
    )
    model = JuMPChance.ChanceModel(solver=solver)
    JuMP.@variable(model, ref.gen[i].pmin <= p[i in 1:ref.ngen] <= ref.gen[i].pmax, start=ref.gen[i].pstart)
    JuMP.@variable(model,                    α[i in 1:ref.ngen] >= 0)
    JuMPChance.@indepnormal(model,           ω[j in 1:ref.nbus], mean=0, var=ref.stdω[j]^2)
    function busvalue(i)
        result = ω[i] - ref.bus[i].pd - ref.bus[i].gs
        if !isempty(ref.bus[i].gens)
            result += sum(p[g] - α[g]*sum(ω) for g in ref.bus[i].gens)
        end
        result
    end
    busvalue = [busvalue(i) for i in 1:ref.nbus]
    θ(i) = sum(ref.π[i,j]*busvalue[j] for j in 1:ref.nbus)
    lineflow(l) = ref.line[l].β*(θ(ref.line[l].frombus) - θ(ref.line[l].tobus))
    JuMP.@constraints model begin
        sum(α[i] for i in 1:ref.ngen) == 1
        sum(α[g] for g in ref.bus[ref.r].gens) == 0
        powerbalance, 0 == sum(sum(p[g] for g in b.gens) - b.pd - b.gs for b in ref.bus)
    end
    for i in 1:ref.ngen
        JuMP.@constraint(model, p[i] - sum(ω)*α[i] <= ref.gen[i].pmax, with_probability=ref.bus_prob)
        JuMP.@constraint(model, p[i] - sum(ω)*α[i] >= ref.gen[i].pmin, with_probability=ref.bus_prob)
    end
    for l in 1:ref.nline
        JuMP.@constraint(model, lineflow(l) <= ref.line[l].rate, with_probability=ref.line_prob)
        JuMP.@constraint(model, lineflow(l) >= -ref.line[l].rate, with_probability=ref.line_prob)
    end
    JuMP.@objective(model, Min, cost(ref, p))
    ChanceConstrainedOPF(model,p,α)
end

ChanceConstrainedOPF(filename::String; kwargs...) =
    ChanceConstrainedOPF(PM.build_ref(PM.parse_file(filename)); kwargs...)

ChanceConstrainedOPF(ref::Dict{Symbol,Any}; kwargs...) =
    ChanceConstrainedOPF(NetworkReference(ref); kwargs...)

function get_opf_solution(opf::ChanceConstrainedOPF, ω)
    return JuMP.getvalue(opf.p) - JuMP.getvalue(opf.α)*sum(ω)
end

mutable struct FullChanceConstrainedOPF
    model::JuMP.Model
    p
    α
end

function FullChanceConstrainedOPF(
        ref::NetworkReference,
        solver::MathProgBase.AbstractMathProgSolver
    )
    model = JuMPChance.ChanceModel(solver=solver)
    JuMP.@variable(model, ref.gen[i].pmin <= p[i in 1:ref.ngen] <= ref.gen[i].pmax, start=ref.gen[i].pstart)
    JuMP.@variable(model,                    α[i in 1:ref.ngen, j in 1:ref.nbus] >= 0)
    JuMPChance.@indepnormal(model,           ω[j in 1:ref.nbus], mean=0, var=ref.stdω[j]^2)
    function busvalue(i)
        result = ω[i] - ref.bus[i].pd - ref.bus[i].gs
        if !isempty(ref.bus[i].gens)
            result += sum(
                p[g] - sum(α[g,j]*ω[j] for j in 1:ref.nbus)
                for g in ref.bus[i].gens
            )
        end
        result
    end
    busvalue = [busvalue(i) for i in 1:ref.nbus]
    θ(i) = sum(ref.π[i,j]*busvalue[j] for j in 1:ref.nbus)
    lineflow(l) = ref.line[l].β*(θ(ref.line[l].frombus) - θ(ref.line[l].tobus))
    JuMP.@constraints model begin
        [j in 1:ref.nbus], sum(α[i,j] for i in 1:ref.ngen) == 1
        powerbalance, 0 == sum(sum(p[g] for g in b.gens) - b.pd - b.gs for b in ref.bus)
    end
    for i in 1:ref.ngen
        JuMP.@constraint(model, p[i] - sum(α[i,j]*ω[j] for j in 1:ref.nbus) <= ref.gen[i].pmax, with_probability=ref.bus_prob)
        JuMP.@constraint(model, p[i] - sum(α[i,j]*ω[j] for j in 1:ref.nbus) >= ref.gen[i].pmin, with_probability=ref.bus_prob)
    end
    for l in 1:ref.nline
        JuMP.@constraint(model, lineflow(l) <= ref.line[l].rate, with_probability=ref.line_prob)
        JuMP.@constraint(model, lineflow(l) >= -ref.line[l].rate, with_probability=ref.line_prob)
    end
    JuMP.@objective(model, Min, cost(ref, p))
    FullChanceConstrainedOPF(model,p,α)
end

function get_opf_solution(opf::FullChanceConstrainedOPF, ω)
    return JuMP.getvalue(opf.p) - JuMP.getvalue(opf.α)*ω
end

mutable struct SingleScenarioOPF
    model::JuMP.Model
    p::Vector{JuMP.Variable}
    ω::Vector{JuMP.Variable}
end

function SingleScenarioOPF(
        ref::NetworkReference,
        solver::MathProgBase.AbstractMathProgSolver
    )
    model = JuMP.Model(solver=solver)
    JuMP.@variable(model, ref.gen[i].pmin <= p[i in 1:ref.ngen] <= ref.gen[i].pmax, start=ref.gen[i].pstart)
    JuMP.@variable(model,                    ω[i in 1:ref.nbus])
    JuMP.@expression(model, busvalue[i in 1:ref.nbus],
        sum(p[g] for g in ref.bus[i].gens) + ω[i] - ref.bus[i].pd - ref.bus[i].gs 
    )
    lineflow(l) = ref.line[l].β*(
        θ(ref,busvalue,ref.line[l].frombus) - θ(ref,busvalue,ref.line[l].tobus)
    )
    JuMP.@constraints model begin
        [l in 1:ref.nline], lineflow(l) <= ref.line[l].rate
        [l in 1:ref.nline], lineflow(l) >= -ref.line[l].rate
        0 == sum(sum(p[g] for g in ref.bus[i].gens) + ω[i] - ref.bus[i].pd - ref.bus[i].gs
                 for i in 1:ref.nbus)
    end
    JuMP.@objective(model, Min, cost(ref, p))
    SingleScenarioOPF(model,p,ω)
end

SingleScenarioOPF(filename::String; kwargs...) =
    SingleScenarioOPF(PM.build_ref(PM.parse_file(filename)); kwargs...)

SingleScenarioOPF(ref::Dict{Symbol,Any}; kwargs...) =
    SingleScenarioOPF(NetworkReference(ref); kwargs...)

function get_opf_solution(opf::SingleScenarioOPF, ω)
    for i in eachindex(ω); JuMP.fix(opf.ω[i], ω[i]) end
    @assert JuMP.solve(opf.model) == :Optimal
    JuMP.getvalue(opf.p)
end
