export Lens, set, get, update

import Base: get, setindex

abstract type Mutability end
struct Mutable <: Mutability end
struct Immutable <: Mutability end

"""
    Lens

A `Lens` allows to access or replace deeply nested parts of complicated objects.

# Example
```jldoctest
julia> using Setfield

julia> struct T;a;b; end

julia> t = T("AA", "BB")
T("AA", "BB")

julia> l = @lens _.a
(@lens _.a)

julia> get(l, t)
"AA"

julia> set(l, t, 2)
T(2, "BB")

julia> t
T("AA", "BB")

julia> update(lowercase, l, t)
T("aa", "BB")
```

# Interface
Concrete subtypes of `Lens` have to implement
* `set(lens, obj, val)`
* `get(lens, obj)`

These must be pure functions, that satisfy the three lens laws:
* `get(lens, set(lens, obj, val)) == val` (You get what you set.)
* `set(lens, obj, get(lens, obj)) == obj` (Setting what was already there changes nothing.)
* `set(lens, set(lens, obj, val1), val2) == set(lens, obj, val2)` (The last set wins.)

See also [`@lens`](@ref), [`set`](@ref), [`get`](@ref), [`update`](@ref).
"""
abstract type Lens end

set(l::Lens, obj, val) = set(l,obj,val,Mutable())
update(f,l::Lens, obj) = update(f, l,obj,Mutable())

"""
    update(f, l::Lens, obj)

Replace a deeply nested part `x` of `obj` by `f(x)`. See also [`Lens`](@ref).
"""
@inline function update(f, l::Lens, obj, m::Mutability)
    old_val = get(l, obj)
    new_val = f(old_val)
    set(l, obj, new_val, m)
end

struct IdentityLens <: Lens end

"""
    get(l::Lens, obj)

Access a deeply nested part of `obj`. See also [`Lens`](@ref).
"""
get(::IdentityLens, obj) = obj

"""
    set(l::Lens, obj, val)

Replace a deeply nested part of `obj` by `val`. See also [`Lens`](@ref).
"""
set(::IdentityLens, obj, val,::Mutability) = val

struct FieldLens{fieldname} <: Lens end
FieldLens(s::Symbol) = FieldLens{s}()

@generated function get(l::FieldLens{field}, obj) where {field}
    @assert field isa Symbol
    assert_hasfield(obj, field)
    Expr(:block,
        Expr(:meta, :inline),
        :(obj.$field)
    )
end

function set_field_lens_impl(T, field)
    args = map(fieldnames(T)) do fn
        fn == field ? :val : :(obj.$fn)
    end
    Expr(:block,
        Expr(:meta, :inline),
        Expr(:call, T, args...)
    )
end

function assert_hasfield(T, field)
    if !(field ∈ fieldnames(T))
        msg = "$T has no field $field"
        throw(ArgumentError(msg))
    end
end

@generated function set(l::FieldLens{field}, obj, val, m::Mutability) where {field}
    @assert field isa Symbol
    assert_hasfield(obj, field)
    if obj.mutable && (m == Mutable)
        :(obj.$field=val; obj)
    else
        set_field_lens_impl(obj, field)
    end
end

struct ComposedLens{L1, L2} <: Lens
    lens1::L1
    lens2::L2
end

compose() = IdentityLens()
compose(l::Lens) = l
compose(::IdentityLens, ::IdentityLens) = IdentityLens()
compose(::IdentityLens, l::Lens) = l
compose(l::Lens, ::IdentityLens) = l
compose(l1::Lens, l2 ::Lens) = ComposedLens(l1, l2)
function compose(ls::Lens...)
    # We can build _.a.b.c as (_.a.b).c or _.a.(b.c)
    # The compiler prefers (_.a.b).c
    compose(compose(Base.front(ls)...), last(ls))
end

function get(l::ComposedLens, obj)
    inner_obj = get(l.lens2, obj)
    get(l.lens1, inner_obj)
end

function set(l::ComposedLens, obj, val, m::Mutability)
    inner_obj = get(l.lens2, obj)
    inner_val = set(l.lens1, inner_obj, val, m)
    set(l.lens2, obj, inner_val, m)
end

struct IndexLens{I} <: Lens
    indices::I
end
IndexLens(indices...) = IndexLens(indices)

get(l::IndexLens, obj) = getindex(obj, l.indices...)
set(l::IndexLens, obj, val, ::Immutable) = Base.setindex(obj, val, l.indices...)
function set(l::IndexLens, obj, val, ::Mutable)
    if hassetindex!(obj)
        setindex!(obj, val, l.indices...)
    else
        set(l, obj, val, Immutable())
    end
end

hassetindex!(obj::AbstractArray) = true
hassetindex!(obj::Associative) = true
hassetindex!(obj::Tuple) = false

struct Focused{O, L <: Lens}
    object::O
    lens::L
end

update(f, foc::Focused) = update(f, foc.lens, foc.object)
set(foc::Focused, val) = set(foc.lens, foc.object, val)
get(foc::Focused) = get(foc.lens, foc.object)
