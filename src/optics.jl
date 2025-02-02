export @optic
export set, modify
export ∘, opcompose, var"⨟"
export Elements, Recursive, If, Properties
export setproperties
export constructorof
using ConstructionBase
using CompositionsBase
using Base: getproperty
using Base

const EXPERIMENTAL = """This function/method/type is experimental. It can be changed or deleted at any point without warning"""

"""
    modify(f, obj, optic)

Replace a part `x` of `obj` by `f(x)`. The `optic` argument selects
which part to replace.

```jldoctest
julia> using Accessors

julia> obj = (a=1, b=2); optic=@optic _.a; f = x -> "hello \$x";

julia> modify(f, obj, optic)
(a = "hello 1", b = 2)
```
See also [`set`](@ref).
"""
function modify end

"""
    set(obj, optic, val)

Replace a part according to `optic` of `obj` by `val`.

```jldoctest
julia> using Accessors

julia> obj = (a=1, b=2); lens=@optic _.a; val = 100;

julia> set(obj, lens, val)
(a = 100, b = 2)
```
See also [`modify`](@ref).
"""
function set end

"""
    optic₁ ⨟ optic₂

Compose optics `optic₁`, `optic₂`, ..., `opticₙ` to access nested objects.

# Example
```jldoctest
julia> using Accessors

julia> obj = (a = (b = (c = 1,),),);

julia> la = @optic _.a
       lb = @optic _.b
       lc = @optic _.c
       lens = la ⨟ lb ⨟ lc
(@optic _.c) ∘ (@optic _.b) ∘ (@optic _.a)

julia> lens(obj)
1
```
"""
opcompose

const BASE_COMPOSED_FUNCTION_HAS_SHOW = VERSION >= v"1.6.0-DEV.85"
const BASE_COMPOSED_FUNCTION_IS_PUBLIC = VERSION >= v"1.6.0-DEV.1037"
if !BASE_COMPOSED_FUNCTION_IS_PUBLIC
    using Compat: ComposedFunction
end
if !BASE_COMPOSED_FUNCTION_HAS_SHOW
    function show_composed_function(io::IO, c::ComposedFunction)
        show(io, c.outer)
        print(io, " ∘ ")
        show(io, c.inner)
    end
    function Base.show(io::IO, c::ComposedFunction)
        show_composed_function(io, c)
    end
    function Base.show(io::IO, ::MIME"text/plain", c::ComposedFunction)
        show_composed_function(io, c)
    end
end

const ComposedOptic{Outer, Inner} = ComposedFunction{Outer, Inner}
outertype(::Type{ComposedOptic{Outer, Inner}}) where {Outer, Inner} = Outer
innertype(::Type{ComposedOptic{Outer, Inner}}) where {Outer, Inner} = Inner

# TODO better name
# also better way to organize traits will
# probably only emerge over time
abstract type OpticStyle end
struct ModifyBased <: OpticStyle end
struct SetBased <: OpticStyle end
OpticStyle(obj) = OpticStyle(typeof(obj))
# defining lenses should be very lightweight
# e.g. only a single `set` implementation
# so we choose this as the default trait
OpticStyle(::Type{T}) where {T} = SetBased()

function OpticStyle(::Type{ComposedOptic{O,I}}) where {O,I}
    composed_optic_style(OpticStyle(O), OpticStyle(I))
end
composed_optic_style(::SetBased, ::SetBased) = SetBased()
composed_optic_style(::ModifyBased, ::SetBased) = ModifyBased()
composed_optic_style(::SetBased, ::ModifyBased) = ModifyBased()
composed_optic_style(::ModifyBased, ::ModifyBased) = ModifyBased()

@inline function set(obj, optic, val)
    _set(obj, optic, val, OpticStyle(optic))
end

function _set(obj, optic, val, ::SetBased)
    Optic = typeof(optic)
    error("""
    This should be unreachable. You probably need to overload
    `Accessors.set(obj, ::$Optic, val)
    """
   )
end

struct Constant{V}
    value::V
end
(o::Constant)(x) = o.value

@inline function _set(obj, optic, val, ::ModifyBased)
    modify(Constant(val), obj, optic)
end

@inline function _set(obj, optic::ComposedOptic, val, ::SetBased)
    inner_obj = optic.inner(obj)
    inner_val = set(inner_obj, optic.outer, val)
    set(obj, optic.inner, inner_val)
end

@inline function modify(f, obj, optic)
    _modify(f, obj, optic, OpticStyle(optic))
end

function _modify(f, obj, optic, ::ModifyBased)
    Optic = typeof(optic)
    error("""
          This should be unreachable. You probably need to overload:
          `Accessors.modify(f, obj, ::$Optic)`
          """)
end

function _modify(f, obj, optic::ComposedOptic, ::ModifyBased)
    otr = optic.outer
    inr = optic.inner
    modify(obj, inr) do o1
        modify(f, o1, otr)
    end
end

@inline function _modify(f, obj, optic, ::SetBased)
    set(obj, optic, f(optic(obj)))
end

"""
    Elements

Access all elements of a collection that implements `map`.

```jldoctest
julia> using Accessors

julia> obj = (1,2,3);

julia> set(obj, Elements(), 0)
(0, 0, 0)

julia> modify(x -> 2x, obj, Elements())
(2, 4, 6)
```
$EXPERIMENTAL
"""
struct Elements end
OpticStyle(::Type{<:Elements}) = ModifyBased()

function modify(f, obj, ::Elements)
    map(f, obj)
end

"""
    If(modify_condition)

Restric access to locations for which `modify_condition` holds.

```jldoctest
julia> using Accessors

julia> obj = (1,2,3,4,5,6);

julia> @set obj |> Elements() |> If(iseven) *= 10
(1, 20, 3, 40, 5, 60)
```

$EXPERIMENTAL
"""
struct If{C}
    modify_condition::C
end
OpticStyle(::Type{<:If}) = ModifyBased()

function modify(f, obj, w::If)
    if w.modify_condition(obj)
        f(obj)
    else
        obj
    end
end

"""
    mapproperties(f, obj)

Construct a copy of `obj`, with each property replaced by
the result of applying `f` to it.

```jldoctest
julia> using Accessors

julia> obj = (a=1, b=2);

julia> Accessors.mapproperties(x -> x+1, obj)
(a = 2, b = 3)
```
$EXPERIMENTAL
"""
function mapproperties(f, obj)
    # TODO move this helper elsewhere?
    # TODO should we use a generated function based on fieldnames?
    pnames = propertynames(obj)
    if isempty(pnames)
        return obj
    else
        ctor = constructorof(typeof(obj))
        new_props = map(pnames) do p
            f(getproperty(obj, p))
        end
        return ctor(new_props...)
    end
end

"""
    Properties()

Access all properties of an objects.

```jldoctest
julia> using Accessors

julia> obj = (a=1, b=2, c=3)
(a = 1, b = 2, c = 3)

julia> set(obj, Properties(), "hi")
(a = "hi", b = "hi", c = "hi")

julia> modify(x -> 2x, obj, Properties())
(a = 2, b = 4, c = 6)
```
Based on [`mapproperties`](@ref).

$EXPERIMENTAL
"""
struct Properties end
OpticStyle(::Type{<:Properties}) = ModifyBased()
modify(f, o, ::Properties) = mapproperties(f, o)

"""
    Recursive(descent_condition, optic)

Apply `optic` recursively as long as `descent_condition` holds.
```jldoctest
julia> using Accessors

julia> obj = (a=missing, b=1, c=(d=missing, e=(f=missing, g=2)))
(a = missing, b = 1, c = (d = missing, e = (f = missing, g = 2)))

julia> set(obj, Recursive(!ismissing, Properties()), 100)
(a = 100, b = 1, c = (d = 100, e = (f = 100, g = 2)))

julia> obj = (1,2,(3,(4,5),6))
(1, 2, (3, (4, 5), 6))

julia> modify(x -> 100x, obj, Recursive(x -> (x isa Tuple), Elements()))
(100, 200, (300, (400, 500), 600))
```
"""
struct Recursive{Descent, Optic}
    descent_condition::Descent
    optic::Optic
end
OpticStyle(::Type{Recursive{D,O}}) where {D,O} = ModifyBased() # Is this a good idea?

function _modify(f, obj, r::Recursive, ::ModifyBased)
    modify(obj, r.optic) do o
        if r.descent_condition(o)
            modify(f, o, r)
        else
            f(o)
        end
    end
end

################################################################################
##### Lenses
################################################################################
struct PropertyLens{fieldname} end

function (l::PropertyLens{field})(obj) where {field}
    getproperty(obj, field)
end

@inline function set(obj, l::PropertyLens{field}, val) where {field}
    patch = (;field => val)
    setproperties(obj, patch)
end

struct IndexLens{I <: Tuple}
    indices::I
end

Base.@propagate_inbounds function (lens::IndexLens)(obj)
    getindex(obj, lens.indices...)
end
Base.@propagate_inbounds function set(obj, lens::IndexLens, val)
    setindex(obj, val, lens.indices...)
end

struct DynamicIndexLens{F}
    f::F
end

Base.@propagate_inbounds function (lens::DynamicIndexLens)(obj)
    return obj[lens.f(obj)...]
end

Base.@propagate_inbounds function set(obj, lens::DynamicIndexLens, val)
    return setindex(obj, val, lens.f(obj)...)
end
