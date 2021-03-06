using OnlineStats, OnlineStatsBase, StatsModels, Tables

using OnlineStats: XY
using StatsModels: has_schema

mutable struct Formulated{O<:OnlineStat{XY}} <: OnlineStat{NamedTuple}
    formula::FormulaTerm
    stat::O
end

OnlineStatsBase._fit!(f::Formulated, row) =
    OnlineStatsBase._fit!(f.stat, reverse(modelcols(f.formula, row)))

function OnlineStatsBase.value(f::Formulated, args...; kwargs...)
    val = value(f.stat, args...; kwargs...)
    rhs = f.formula.rhs
    if val isa AbstractVector && length(val) == width(rhs)
        val = NamedTuple{(Symbol.(coefnames(rhs))..., )}((val..., ))
    end
    return val
end

OnlineStatsBase.nobs(f::Formulated) = nobs(f.stat)


a, b = rand(100), rand(100);
β = [1.; 2; 3];
y = hcat(ones(100), a, b) * β .+ randn(100).*.01;

d = (y=y, a=a, b=b);
d_rows = Tables.rowtable(d);

f = apply_schema(@formula(y ~ 1 + a + b), schema(d_rows));
fit!(Formulated(f, LinReg()), d_rows)
