# What is this about

Data is often tabular: **named variables** (columns) with **different types**

Models need a **numerical representation**

StatsModels.jl provides **`@formula` domain-specific language** to specify
**table-to-array** transformations for modeling

Critical "last-mile" step in between data pre-processing and your model

???

Why should you the distracted attendee of JuliaCon2020 extremely online care
about this?

Almost didn't submit a talk because honestly there's not a HUGE amount more to
talk about above and beyond what you saw in 2018.  but with 1 year of pretty
intensive code review and discussion and another year to see how some of our
choices shook out, I think it's worthwhile to revisit some of those choices,
where they went wrong and what we got right.  And in particular I want to talk
about what a distinctly Julian approach to this problem looks like, because
that's really influenced the design...

---

# A very quick example

```@example
using StatsModels

a, b = rand(10), repeat(["argle", "bargle"], outer=5)
y = 1.0 .+ 2a + 3(b .== "bargle") + 4a .* (b .== "bargle")
data = (a=a, b=b, y=y)

f = @formula(y ~ 1 + a + b + a&b)
sch = schema(data)
y, X = modelcols(apply_schema(f, sch), data)

β̂ = X \ y
```

---

# Three goals

Julia is a good language for these kinds of infrastructure problems because it
lends itself to packages that are

1. Composable
2. Hackable
3. Extendable

--

## For this project that means...

1. Composable - support any Tables.jl table (row or column), arbitrary Julia
   functions in the `@formula`
2. Hackable - muck around with the `@formula` without relying on weird, opaque,
   non-public internals
3. Extendable - provide means to not just *use* `@formula` but *extend* it

???

Obviously not mutually exclusive.

---

# Some history

**2012--2019**: DataFrames.jl: 

`@formula` → `Terms` (variable-by-term matrix) → `ModelFrame` (DataFrame wrapper) → `ModelMatrix`

- ✘ Composable (`DataFrame` in, specialized `ModelMatrix` out)
- ✘ Hackable (opaque internal representation of the formula)
- ✘ Extendable (DSL syntax rules baked into `@formula` / `Terms`)

--

**2018--2019**: Terms 2.0: Son of Terms
[(#71)](https://github.com/JuliaStats/StatsModels.jl/pull/71)/[JuliaCon2018](https://www.youtube.com/watch?v=HORLJrsghs4)

`@formula` → `AbstractTerm`s → `apply_schema` (+`schema`) → `modelcols` (+table/row) → `AbstractArray`

- ✔ Composable (Tables.jl in, `AbstractArray` out, arbitrary functions mosly work in `@formula`)
- ✔ Hackable (Everything is an `AbstractTerm`)
- ✔/✘ Extendable (Anyone can claim syntax as "special" at any point)

--

**2019--_present_**: `¯\_(ツ)_/¯`

- Fixing mistakes in extending `@formula` syntax
- What about performance??

???

So what I want to share is where I think we've done a good job with making a
**composable** and **hackable** `@formula`, and then talk about some of the
challenges with making this **truly extendable**.  then to wrap up I'll talk
about some of the design challenges we're still grappling with here.

---

# Composable

Supports any [Tables.jl](https://github.com/JuliaData/Tables.jl) data source.

Both "column-oriented" ("`NamedTuple` of `Vector`s") and "row-oriented"
("`Vector` of `NamedTuple`s")

--

(The caveat: schema extraction converts everything to columns right now)

---

# Composable

[OnlineStats.jl](https://github.com/joshday/OnlineStats.jl) provides 

> Online algorithms are well suited for streaming data or when data is too large
> to hold in memory. OnlineStats processes observations one by one and all
> algorithms use O(1) memory."

--

```@example online
using OnlineStats

a, b = rand(100), rand(100)
β = [1.; 2; 3]
X = hcat(ones(100), a, b)
y = X * β .+ randn(100).*.01

fit!(LinReg(), zip(eachrow(X), y))
```

--

...but what if your data 
- is in a table?
- has strings?
- needs non-linear transformations applied?

---

# Composable

Wrap any `OnlineStat` to take in tabular data:

```@example online
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

```@example online
a, b = rand(100), rand(100)
β = [1.; 2; 3]
X = hcat(ones(100), a, b)
y = X * β .+ randn(100).*.01

d = (y=y, a=a, b=b)
d_rows = Tables.rowtable(d)
first(d_rows)
```

```@example online
f = apply_schema(@formula(y ~ 1 + a + b), schema(d_rows))
fit!(Formulated(f, LinReg()), d_rows)
```

---

# Composable

Wrap any `OnlineStat` to take in tabular data...even with categorical values!

```@example online
a, b, c = rand(100), rand(100), repeat(["argle", "bargle"], outer=50)
β = [1.; 2; 3; 4; 5]
#                         vvvvvvvvvvvvvvvvvvvvvvvvv manually construct indicators for c
X = hcat(ones(100), a, b, c.=="argle", c.=="bargle")
y = X * β .+ randn(100).*.01

d = (y=y, a=a, b=b, c=c)
d_rows = Tables.rowtable(d)
first(d_rows)
```

```@example online
f = apply_schema(@formula(y ~ 1 + a + b + c), schema(d_rows));
fit!(Formulated(f, LinReg()), d_rows)
```


---

# Composable

Wrap any `OnlineStat` to take in tabular data...even with (lazily applied)
functions!

```@example online
a, b, c = rand(100), rand(100), repeat(["argle", "bargle"], outer=50)
β = [1.; 2; 3; 4; 5]
X = hcat(ones(100), a, b, c.=="argle", c.=="bargle")

#   vvv exponential link function
y = exp.(X * β .+ randn(100).*.01)

d = (y=y, a=a, b=b, c=c)
d_rows = Tables.rowtable(d)
first(d_rows)
```

```@example online
#                         vvv inverse link function
f = apply_schema(@formula(log(y) ~ 1 + a + b + c), schema(d_rows))
fit!(Formulated(f, LinReg()), d_rows)
```

---

# Hackable

Everything is an `<:AbstractTerm` (including `FormulaTerm`)

```@example hack1
using StatsModels
d = (y=rand(10), a=rand(10), b=repeat(["argle", "bargle"], outer=5))
f = apply_schema(@formula(y ~ 1 + a + b), schema(d))
```

---

# Hackable

Any `AbstractTerm` can transform a table/row via `modelcols(term, data)`.

```@example hack1
y_term = f.lhs
```

```@example hack1
modelcols(y_term, d)
```

---

# Hackable

Multiple dispatch: terms can be combined with normal Julia functions.

```@example hack1
intercept, a_term, b_term = f.rhs.terms
```

--

```@example hack1
ab_interaction = a_term & b_term
```

--

```@example hack1
y, X = modelcols(y_term ~ f.rhs + ab_interaction, d)
X
```

---

# Hackable

Constructing a `@formula` at run-time

```@example hack2
using StatsModels: term
build_f(response, vars) = term(:y) ~ sum(term.(vars))
print(build_f(:y, [:a, :b, :c, :d, :e, :f]))
```

```@example hack2
print(build_f(:y, [1, :a, :b]))
```

```@example hack2
print(build_f(:y, [1, :a, :b, term(:a)&term(:b)]))
```

--- 

# Extendable - proposal

Original proposal from 2018/Terms 2.0: Son of Terms

Example: using `poly(x, 4)` to generate a 4th order polynomial basis from `x`

Make **any** function special by doing one or more of

- `is_special(::Val{:poly}) = true` (inside the macro parser)
- `capture_call(::typeof(poly), fanon, names, ex) = PolyTerm(...)` (immediately after
  macro evaluation)
- `apply_schema(::FunctionTerm{typeof(poly}), schema) = PolyTerm(...)` (at
  schema time)

--

Problem with this: **who owns `poly` in the `@formula`?**

---

# Extendable - solution

Add custom syntax via **multiple dispatch**:

```julia
apply_schema(t::FunctionTerm{tyepof(my_special_fun)}, sch::Schema, Mod::Type) =
    MyFancyTerm(...)
```

The `Schema` is the "source" (information about the data)

The `Mod` is a "sink" (information about the model)

Together they provide the _context_ for interpreting terms

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

(MixedModels.jl takes this a lot further, with special syntax for `/`,
`zerocorr`, `fulldummy`, and others)

---

# Who owns extended DSL syntax?

Dispatching on the model type resolves the question of who "owns" special DSL
syntax

A wide type for the context provides broad coverage but can be overruled:

```julia
# applies everywhere
apply_schema(::FunctionTerm{typeof(|)}, ::Schema, ::Any)
# ...except for specific exceptions
apply_schema(::FunctionTerm(tyepof(|)}, ::Schema, ::MyFancyPipeModel)
```

You could still "steal" syntax, but that's type piracy (methods for types you
don't own).

---

# Mistakes

Conflicting pressure to move stuff out of "macro magic" ends up taxing the
compiler unless you're really careful

--

Three-way dispatch is hard.  Method ambiguities, and design ambiguity

--

Context only comes in at the very last stage (`apply_schema`).  No context-aware
way of generating the schema.

- Categorical variables with many levels used as grouping index
  (`OutOfMemoryError`)
- Things like spline basis that need more information

--

...What happened to performance?

```@example
using StatsModels
typeof(@formula(y ~ 1 + a*b*c))
```

---

# The future

Remove as many type parameters as we can

--

Better representation of non-special calls (`FunctionTerm`)
([#183](https://github.com/JuliaStats/StatsModels.jl/pull/183),
[#117](https://github.com/JuliaStats/StatsModels.jl/pull/117))
- not abuse the compiler so much
- handle mixed/nested special and non-special calls
- capture argument values, keyword arguments

--

Make row-wise table support first-class:
- online/parallel `Schema` extraction
- in-place `modelcols!` 

--

Context-aware `Schema` creation
