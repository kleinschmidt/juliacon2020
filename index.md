
class: middle


.slide-title[






# StatsModels.jl: Mistakes were made






## Dave Kleinschmidt — [`@kleinschmidt`](https://github.com/kleinschmidt)






### Rutgers University (New Brunswick)






### JuliaCon 2020 - [davekleinschmidt.com/juliacon2020/](https://www.davekleinschmidt.com/juliacon2020/)


]


???


Thanks for joining me here, whatever "here" means for you.  I'm going to tell you today about some progress we've made in developing StatsModels.jl and also some mistakes we've made along the way.


---






# What is this about


Data is often tabular: **named variables** (columns) with **different types**


Models need a **numerical representation**


StatsModels.jl provides **`@formula` domain-specific language** to specify **table-to-array** transformations for modeling


???


Critical "last-mile" step in between data pre-processing and your model


---






# A very quick example


```julia
using StatsModels

a = rand(10)
b = repeat(["argle", "bargle"], outer=5)
y = 1.0 .+ 2a + 3(b .== "bargle") + 4(a .* (b .== "bargle"))

# we get a table:
data = (a=a, b=b, y=y)

# what's the relationship between y, a, and b?
f = @formula(y ~ 1 + a + b + a&b)
sch = schema(data)
y, X = modelcols(apply_schema(f, sch), data)

β̂ = X \ y
```


```
4-element Array{Float64,1}:
 1.0000000000000007
 1.9999999999999971
 3.0000000000000004
 4.000000000000003
```


???


I'm not going to say a TON about the DSL here, because 2018...


A table: a is Floats, b is strings, y is some linear combination of these.


---






# Three goals


Julia is a good language for these kinds of infrastructure problems because it lends itself to packages that are


1. **Composable** — support any Tables.jl table (row or column), arbitrary Julia functions in the `@formula`
2. **Hackable** — muck around with the `@formula` without relying on weird, opaque, non-public internals
3. **Extendable** —  provide means to not just *use* `@formula` but *extend* it


???


Obviously not mutually exclusive.


---






# Some history


**2012–2019**: DataFrames.jl: 


`@formula` → `Terms` (variable-by-term matrix) → `ModelFrame` (DataFrame wrapper) → `ModelMatrix`


  * .red[✘ **Composable**]—`DataFrame` in, specialized `ModelMatrix` out
  * .red[✘ **Hackable**]—opaque internal representation of the formula
  * .red[✘ **Extendable**]—DSL syntax rules baked into `@formula` / `Terms`


--


**2018–2019**: Terms 2.0: Son of Terms [(#71)](https://github.com/JuliaStats/StatsModels.jl/pull/71)/[JuliaCon2018](https://www.youtube.com/watch?v=HORLJrsghs4)


`@formula` → `AbstractTerm`s → `apply_schema` (+`schema`) → `modelcols` (+table/row) → `AbstractArray`


  * .green[✔ **Composable**]—Tables.jl in, `AbstractArray` out, arbitrary functions mosly work in `@formula`
  * .green[✔ **Hackable**]—Everything is an `AbstractTerm`
  * .red[✔/✘ **Extendable**]—Anyone can claim syntax as "special" at any point


--


**2019–*future***: `¯\_(ツ)_/¯`


  * Fixing mistakes in extending `@formula` syntax
  * What about performance??


???


So what I want to share is where I think we've done a good job with making a **composable** and **hackable** `@formula`, and then talk about some of the challenges with making this **truly extendable**.  then to wrap up I'll talk about some of the design challenges we're still grappling with here.


---






# Composable


Supports any [Tables.jl](https://github.com/JuliaData/Tables.jl) data source.


Both "column-oriented" ("`NamedTuple` of `Vector`s") and "row-oriented" ("`Vector` of `NamedTuple`s")<superscript>*</superscript>


.footnote[<superscript>*</superscript>caveat: schema extraction converts everything to columns right now)]


---




# Composable


[OnlineStats.jl](https://github.com/joshday/OnlineStats.jl) provides 


> Online algorithms are well suited for streaming data or when data is too large to hold in memory. OnlineStats processes observations one by one and all algorithms use O(1) memory."



```julia
using OnlineStats

a, b = rand(100), rand(100)
β = [1.; 2; 3]
X = hcat(ones(100), a, b)
y = X * β .+ randn(100).*.01

fit!(LinReg(), zip(eachrow(X), y))
```


```
LinReg: n=100 | value=[0.998046, 2.00239, 2.99899]
```


--


...but what if your data 


  * is in a table?
  * has strings?
  * needs non-linear transformations applied?


???


example from the OnlineStats docs.  I want to show you how simnple it is to combine the strengths of StatsModels and OnlineStats...


---




# Composable


StatsModels.jl and OnlineStats.jl have a small API surface, so we can **compose** them:


```julia
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
```


---




# Composable


Wrap any `OnlineStat` to take in tabular data:


```julia
a, b = rand(100), rand(100)
β = [1.; 2; 3]
X = hcat(ones(100), a, b)
y = X * β .+ randn(100).*.01

# a table
d = (y=y, a=a, b=b)

# iterate NamedTuples
d_rows = Tables.rowtable(d)
first(d_rows)
```


```
(y = 1.5490374625491479, a = 0.08652148083051237, b = 0.12922914123145235)
```


```julia
f = apply_schema(@formula(y ~ 1 + a + b), schema(d_rows))
fit!(Formulated(f, LinReg()), d_rows)
```


```
ex-Formulated: n=100 | value=((Intercept) = 1.00319, a = 2.00052, b = 2.99614)
```


---




# Composable


Wrap any `OnlineStat` to take in tabular data...even with categorical variables!


```julia
a, b = rand(100), repeat(["argle", "bargle"], outer=50)
β = [1.; 2; 3]
#                      vvvvvvvvvvvv manually construct indicator variable for c
X = hcat(ones(100), a, b.=="bargle")
y = X * β .+ randn(100).*.01

d = (y=y, a=a, b=b)
d_rows = Tables.rowtable(d)
first(d_rows)
```


```
(y = 2.1264481757051645, a = 0.5641326460868754, b = "argle")
```


```julia
f = apply_schema(@formula(y ~ 1 + a + b), schema(d_rows));
fit!(Formulated(f, LinReg()), d_rows)
```


```
ex-Formulated: n=100 | value=((Intercept) = 1.00049, a = 1.99679, b: bargle = 3.00209)
```


???


This works even if you have strings in your data...


---




# Composable


Wrap any `OnlineStat` to take in tabular data...even with categorical variables...that ineract with others!


```julia
a, b = rand(100), repeat(["argle", "bargle"], outer=50)
β = [1.; 2; 3; 4]
#                                    vvvvvvvvvvvvvvvvvvv effect of a, modulated by "bargle"
X = hcat(ones(100), a, b.=="bargle", a .* (b.=="bargle"))
y = X * β .+ randn(100).*.01

d = (y=y, a=a, b=b)
d_rows = Tables.rowtable(d)
first(d_rows)
```


```
(y = 1.1544393334959597, a = 0.07810125068097484, b = "argle")
```


```julia
f = apply_schema(@formula(y ~ 1 + a + b + a&b), schema(d_rows));
fit!(Formulated(f, LinReg()), d_rows)
```


```
ex-Formulated: n=100 | value=((Intercept) = 1.00397, a = 1.99621, b: bargle = 2.99582, a & b: bargle = 4.00481)
```


???


Interactions between variables


---




# Composable


Wrap any `OnlineStat` to take in tabular data...even with (lazily applied) functions!


```julia
a, b = rand(100), repeat(["argle", "bargle"], outer=50)
β = [1.; 2; 3; 4]
X = hcat(ones(100), a, b.=="bargle", a .* (b.=="bargle"))

#   vvv exponential link function
y = exp.(X * β .+ randn(100).*.01)

d = (y=y, a=a, b=b)
d_rows = Tables.rowtable(d)
first(d_rows)
```


```
(y = 14.10325772980684, a = 0.8247341519452316, b = "argle")
```


```julia
#                         vvv inverse link function lazily applied
f = apply_schema(@formula(log(y) ~ 1 + a + b + a&b), schema(d_rows))
fit!(Formulated(f, LinReg()), d_rows)
```


```
ex-Formulated: n=100 | value=((Intercept) = 1.00641, a = 1.99384, b: bargle = 2.99091, a & b: bargle = 4.01076)
```


???


Or nonlinear transformations


As an aside: this is why functions in a formula have to apply elementwise, because we can't assume you have all the data available at once.


now, this works, but needs a bit of finessing


---






# Hackable


Everything is an `<:AbstractTerm` (including `FormulaTerm`)


```julia
using StatsModels
d = (y=rand(10), a=rand(10), b=repeat(["argle", "bargle"], outer=5))
f = apply_schema(@formula(y ~ 1 + a + b), schema(d))
```


```
FormulaTerm
Response:
  y(continuous)
Predictors:
  1
  a(continuous)
  b(StatsModels.DummyCoding:2→1)
```


--


Any `AbstractTerm` can transform a table/row via `modelcols(term, data)`.


```julia
y_term = f.lhs
```


```
y(continuous)
```


```julia
modelcols(y_term, d)
```


```
10-element Array{Float64,1}:
 0.4004913842024824
 0.12067869929118524
 0.098712201125148
 0.7324377633273806
 0.9102405049628304
 0.9937728049286358
 0.9420838835998335
 0.023797064792972833
 0.25623538970606763
 0.6688279715442109
```


---




# Hackable


Terms can be combined with normal Julia functions:


```julia
f = apply_schema(@formula(y ~ 1 + a + b), schema(d))
intercept, a_term, b_term = f.rhs.terms
```


```
1
a(continuous)
b(StatsModels.DummyCoding:2→1)
```


--


```julia
ab_interaction = a_term & b_term
```


```
a(continuous) & b(StatsModels.DummyCoding:2→1)
```


--


```julia
y, X = modelcols(y_term ~ f.rhs + ab_interaction, d)
X
```


```
10×4 Array{Float64,2}:
 1.0  0.454444   0.0  0.0
 1.0  0.392848   1.0  0.392848
 1.0  0.61469    0.0  0.0
 1.0  0.799695   1.0  0.799695
 1.0  0.0310631  0.0  0.0
 1.0  0.635453   1.0  0.635453
 1.0  0.933319   0.0  0.0
 1.0  0.495251   1.0  0.495251
 1.0  0.0928701  0.0  0.0
 1.0  0.429439   1.0  0.429439
```


???


Take this apart, create some modified version, put it back together, works just like before


---




# Hackable


Constructing a `@formula` at run-time


```julia
using StatsModels: term
build_f(response, vars) = term(:y) ~ sum(term.(vars))
print(build_f(:y, [:a, :b, :c, :d, :e, :f]))
```


```
y ~ a + b + c + d + e + f
```


```julia
print(build_f(:y, [1, :a, :b]))
```


```
y ~ 1 + a + b
```


```julia
print(build_f(:y, [1, :a, :b, term(:a)&term(:b)]))
```


```
y ~ 1 + a + b + a & b
```


---






# Extendable - Terms 2.0: Son of Terms


Original proposal from 2018


Example: using `poly(x, 4)` to generate a 4th order polynomial basis from `x`


Make **any** function special by doing one or more of


  * `is_special(::Val{:poly}) = true` (inside the macro parser)
  * `capture_call(::typeof(poly), fanon, names, ex) = PolyTerm(...)` (immediately after macro evaluation)
  * `apply_schema(::FunctionTerm{typeof(poly}), schema) = PolyTerm(...)` (at schema time)


--


Problem with this: **who owns `poly` in the `@formula`?**


--


What happens when you load another package with `is_special(::Val{:poly}) = false`?


Or (God forbid) two packages define `capture_call(::typeof(^), ...)` to do different things?


---






# Extendable - solution


Add custom syntax via **multiple dispatch**:


```julia
apply_schema(t::FunctionTerm{tyepof(my_special_fun)}, sch::Schema, Mod::Type) =
    MyFancyTerm(...)
```


The `Schema` is the "source" (information about the data)


The `Mod` is a "sink" (information about the model)


Together they provide the *context* for interpreting terms


---






# Extendable: [MixedModels.jl](https://github.com/JuliaStats/MixedModels.jl)


`@formula(y ~ 1 + a + b + (1 | group1) + (1 + b | group2))`


--


A term to represent the special syntax:


```julia
struct RandomEffectsTerm <: AbstractTerm
    lhs::StatsModels.TermOrTerms
    rhs::StatsModels.TermOrTerms
end
```


--


Method for `apply_schema` which converts a `FunctionTerm` to a `RandomEffectsTerm`:


```julia
apply_schema(t::FunctionTerm{typeof(|)}, schema, Mod::Type{<:MixedModel}) =
    RandomEffectsTerm(apply_schema.(t.args_parsed, Ref(schema), Mod))
```


--


A method to create the numerical representation (`ReMat` in this case...):


```julia
modelcols(t::RandomEffectsTerm, data) = ReMat(modelcols(t.lhs, data), extract_groups(t.rhs, data))
```


(MixedModels.jl takes this a lot further, with special syntax for `/`, `zerocorr`, `fulldummy`, and others)


---






# Who owns extended DSL syntax?


Dispatching on the model type resolves the question of who "owns" special DSL syntax


A wide type for the context provides broad coverage but can be overruled:


```julia
# applies everywhere
apply_schema(::FunctionTerm{typeof(|)}, ::Schema, ::Any)
# ...except for specific exceptions
apply_schema(::FunctionTerm(tyepof(|)}, ::Schema, ::MyFancyPipeModel)
```


You could still "steal" syntax, but that's type piracy (methods for types you don't own).


---






# Mistakes


Conflicting pressure to move stuff out of "macro magic" ends up taxing the compiler unless you're really careful


--


Three-way dispatch is hard.  Method ambiguities, and design ambiguity


--


Context only comes in at the very last stage (`apply_schema`).  No context-aware way of generating the schema.


  * Categorical variables with many levels used as grouping index (`OutOfMemoryError`)
  * Things like spline basis that need more information


--


...What happened to performance?


```julia
using StatsModels
typeof(@formula(y ~ 1 + a*b*c))
```


```
StatsModels.FormulaTerm{StatsModels.Term,Tuple{StatsModels.ConstantTerm{Int64},StatsModels.Term,StatsModels.Term,StatsModels.Term,StatsModels.InteractionTerm{Tuple{StatsModels.Term,StatsModels.Term}},StatsModels.InteractionTerm{Tuple{StatsModels.Term,StatsModels.Term}},StatsModels.InteractionTerm{Tuple{StatsModels.Term,StatsModels.Term}},StatsModels.InteractionTerm{Tuple{StatsModels.Term,StatsModels.Term,StatsModels.Term}}}}
```


---






# The future


Remove as many type parameters as we can


--


Better representation of non-special calls (`FunctionTerm`) ([#183](https://github.com/JuliaStats/StatsModels.jl/pull/183), [#117](https://github.com/JuliaStats/StatsModels.jl/pull/117))


  * not abuse the compiler so much
  * handle mixed/nested special and non-special calls
  * capture argument values, keyword arguments


--


Make row-wise table support first-class:


  * online/parallel `Schema` extraction
  * in-place `modelcols!`


--


Context-aware `Schema` creation


--


Modeling API, row-oriented transformations (drop missings, lead/lag)

