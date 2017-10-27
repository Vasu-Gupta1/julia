# This file is a part of Julia. License is MIT: https://julialang.org/license
# import Base: getindex, setindex!, size, similar, parent, Slice, @_propagate_inbounds_meta, @propagate_inbounds, @_inline_meta, AbstractCartesianIndex, tail, index_shape, index_ndims, index_dimsum, IndexStyle, ensure_indexable, fill_to_length, indices, OneTo, unsafe_length, unsafe_indices

abstract type AbstractCartesianIndex{N} end # This is a hacky forward declaration for CartesianIndex
const ViewIndex = Union{Real, AbstractArray}
const ScalarIndex = Real

# The view itself supports fast linear indexing if length(indices) == 1 and IndexStyle(indices[1]) is LinearFast()
"""
    SubArray{T,N,P,I} <: AbstractArray{T,N}

A specialized array type for that represents a view into an indexed subsection of a "parent" array.

Typically constructed with [`view`](@ref) or indexing inside a [`@view`](@ref) or [`@views`](@ref) macro,
SubArrays simply hold onto the parent array and the indices. The additional type parameters concretely
identify the type of the parent array (`P`) and the type of the tuple of indices (`I`).
"""
struct SubArray{T,N,P,I} <: AbstractArray{T,N}
    parent::P
    indices::I
end
# Compute the linear indexability of the indices, and combine it with the linear indexing of the parent
function SubArray(parent::AbstractArray, indices::Tuple)
    @_inline_meta
    SubArray(IndexStyle(viewindexing(indices), IndexStyle(parent)), parent, ensure_indexable(indices), index_shape(indices...))
end
function SubArray(::IndexCartesian, parent::P, indices::I, ::NTuple{N,Any}) where {P,I,N}
    @_inline_meta
    SubArray{eltype(P), N, P, I}(parent, indices)
end
function SubArray(::IndexLinear, parent::P, indices::I, shape::NTuple{N,Any}) where {P,I,N}
    @_inline_meta
    t = linearize_indices(parent, indices, shape)
    SubArray{eltype(P), N, P, typeof(t)}(parent, t)
end

# StridedSubArrays depend upon Ranges wrapped in ReshapedArrays, so more functionality
# is defined within reshapedarray.jl

# Collapse a set of linearly compatible indices into a single index
linearize_indices(parent, indices::Tuple{Any}, shape) = indices
function linearize_indices(parent, indices::Tuple{AbstractUnitRange, Vararg{Any}}, shape)
    @_inline_meta
    (reshape(range(first_index(parent, indices), prod(map(unsafe_length, shape))), shape),)
end
function linearize_indices(parent, indices, shape)
    @_inline_meta
    stride1 = compute_stride1(parent, indices)
    (reshape(range(first_index(parent, indices), stride1, prod(map(unsafe_length, shape))), shape),)
end

# This computes the linear indexing compatability for a given tuple of indices
viewindexing() = IndexLinear()
# Leading scalar indices simply increase the stride
viewindexing(I::Tuple{ScalarIndex, Vararg{Any}}) = (@_inline_meta; viewindexing(tail(I)))
# Slices may begin a section which may be followed by any number of Slices
viewindexing(I::Tuple{Slice, Slice, Vararg{Any}}) = (@_inline_meta; viewindexing(tail(I)))
# A UnitRange can follow Slices, but only if all other indices are scalar
viewindexing(I::Tuple{Slice, AbstractUnitRange, Vararg{ScalarIndex}}) = IndexLinear()
viewindexing(I::Tuple{Slice, Slice, Vararg{ScalarIndex}}) = IndexLinear() # disambiguate
# In general, ranges are only fast if all other indices are scalar
viewindexing(I::Tuple{AbstractRange, Vararg{ScalarIndex}}) = IndexLinear()
# All other index combinations are slow
viewindexing(I::Tuple{Vararg{Any}}) = IndexCartesian()
# Of course, all other array types are slow
viewindexing(I::Tuple{AbstractArray, Vararg{Any}}) = IndexCartesian()

# Simple utilities
indices(S::SubArray) = (@_inline_meta; index_shape(S.indices...))
size(V::SubArray) = (@_inline_meta; map(n->Int(unsafe_length(n)), indices(V)))
similar(V::SubArray, T::Type, dims::Dims) = similar(V.parent, T, dims)

"""
    parent(A)

Returns the "parent array" of an array view type (e.g., `SubArray`), or the array itself if
it is not a view.

# Examples
```jldoctest
julia> a = [1 2; 3 4]
2×2 Array{Int64,2}:
 1  2
 3  4

julia> s_a = Symmetric(a)
2×2 Symmetric{Int64,Array{Int64,2}}:
 1  2
 2  4

julia> parent(s_a)
2×2 Array{Int64,2}:
 1  2
 3  4
```
"""
parent(V::SubArray) = V.parent
parentindexes(V::SubArray) = V.indices

parent(a::AbstractArray) = a
"""
    parentindexes(A)

From an array view `A`, returns the corresponding indices in the parent.
"""
parentindexes(a::AbstractArray) = ntuple(i->OneTo(size(a,i)), ndims(a))

## SubArray creation
# We reshape the parent array such that its dimensionality matches the effective
# number of indices, even accounting for `CartesianIndex` and arrays thereof.
# This is important for two reasons:
#   1. Reshaping a LinearSlow array computes fast multiplicative inverses for
#      optimized ind2sub computations.
#   2. The internal "reindex" function doesn't support linear indexing
_maybe_reshape_parent(A::AbstractArray, I) = (@_inline_meta; _maybe_reshape_parent(IndexStyle(A), A, index_ndims(I...)))
_maybe_reshape_parent(::IndexLinear, A::AbstractArray, ::Tuple) = A
_maybe_reshape_parent(::IndexLinear, A::SubArray{<:Any,N}, ::NTuple{N, Bool}) where {N} = A
_maybe_reshape_parent(::IndexLinear, A::SubArray, ::NTuple{N, Bool}) where {N} = (@_inline_meta; reshape(A, Val(N)))
_maybe_reshape_parent(::IndexCartesian, A::AbstractArray{<:Any,N}, ::NTuple{N, Bool}) where {N} = A
_maybe_reshape_parent(::IndexCartesian, A::AbstractArray, ::NTuple{N, Bool}) where {N} = (@_inline_meta; reshape(A, Val(N)))
"""
    view(A, inds...)

Like [`getindex`](@ref), but returns a view into the parent array `A` with the
given indices instead of making a copy.  Calling [`getindex`](@ref) or
[`setindex!`](@ref) on the returned `SubArray` computes the
indices to the parent array on the fly without checking bounds.

```jldoctest
julia> A = [1 2; 3 4]
2×2 Array{Int64,2}:
 1  2
 3  4

julia> b = view(A, :, 1)
2-element view(::Array{Int64,2}, :, 1) with eltype Int64:
 1
 3

julia> fill!(b, 0)
2-element view(::Array{Int64,2}, :, 1) with eltype Int64:
 0
 0

julia> A # Note A has changed even though we modified b
2×2 Array{Int64,2}:
 0  2
 0  4
```
"""
function view(A::AbstractArray, I::Vararg{Any,N}) where {N}
    @_inline_meta
    J = to_indices(A, I)
    @boundscheck checkbounds(A, J...)
    unsafe_view(_maybe_reshape_parent(A, J), J...)
end

function unsafe_view(A::AbstractArray, I::Vararg{ViewIndex,N}) where {N}
    @_inline_meta
    SubArray(A, I)
end
# When we take the view of a view, it's often possible to "reindex" the parent
# view's indices such that we can "pop" the parent view and keep just one layer
# of indirection. But we can't always do this because arrays of `CartesianIndex`
# might span multiple parent indices, making the reindex calculation very hard.
# So we use _maybe_reindex to figure out if there are any arrays of
# `CartesianIndex`, and if so, we punt and keep two layers of indirection.
unsafe_view(V::SubArray, I::Vararg{ViewIndex,N}) where {N} =
    (@_inline_meta; _maybe_reindex(V, I))
_maybe_reindex(V, I) = (@_inline_meta; _maybe_reindex(V, I, I))
_maybe_reindex(V, I, ::Tuple{AbstractArray{<:AbstractCartesianIndex}, Vararg{Any}}) =
    (@_inline_meta; SubArray(V, I))
# But allow arrays of CartesianIndex{1}; they behave just like arrays of Ints
_maybe_reindex(V, I, A::Tuple{AbstractArray{<:AbstractCartesianIndex{1}}, Vararg{Any}}) =
    (@_inline_meta; _maybe_reindex(V, I, tail(A)))
_maybe_reindex(V, I, A::Tuple{Any, Vararg{Any}}) = (@_inline_meta; _maybe_reindex(V, I, tail(A)))
function _maybe_reindex(V, I, ::Tuple{})
    @_inline_meta
    @inbounds idxs = to_indices(V.parent, reindex(V, V.indices, I))
    SubArray(V.parent, idxs)
end

## Re-indexing is the heart of a view, transforming A[i, j][x, y] to A[i[x], j[y]]
#
# Recursively look through the heads of the parent- and sub-indices, considering
# the following cases:
# * Parent index is array  -> re-index that with one or more sub-indices (one per dimension)
# * Parent index is Colon  -> just use the sub-index as provided
# * Parent index is scalar -> that dimension was dropped, so skip the sub-index and use the index as is

reindex(V, ::Tuple{}, ::Tuple{}) = ()

# Skip dropped scalars, so simply peel them off the parent indices and continue
reindex(V, idxs::Tuple{ScalarIndex, Vararg{Any}}, subidxs::Tuple{Vararg{Any}}) =
    (@_propagate_inbounds_meta; (idxs[1], reindex(V, tail(idxs), subidxs)...))

# Slices simply pass their subindices straight through
reindex(V, idxs::Tuple{Slice, Vararg{Any}}, subidxs::Tuple{Any, Vararg{Any}}) =
    (@_propagate_inbounds_meta; (subidxs[1], reindex(V, tail(idxs), tail(subidxs))...))

# Re-index into parent vectors with one subindex
reindex(V, idxs::Tuple{AbstractVector, Vararg{Any}}, subidxs::Tuple{Any, Vararg{Any}}) =
    (@_propagate_inbounds_meta; (idxs[1][subidxs[1]], reindex(V, tail(idxs), tail(subidxs))...))

# Parent matrices are re-indexed with two sub-indices
reindex(V, idxs::Tuple{AbstractMatrix, Vararg{Any}}, subidxs::Tuple{Any, Any, Vararg{Any}}) =
    (@_propagate_inbounds_meta; (idxs[1][subidxs[1], subidxs[2]], reindex(V, tail(idxs), tail(tail(subidxs)))...))

# In general, we index N-dimensional parent arrays with N indices
@generated function reindex(V, idxs::Tuple{AbstractArray{T,N}, Vararg{Any}}, subidxs::Tuple{Vararg{Any}}) where {T,N}
    if length(subidxs.parameters) >= N
        subs = [:(subidxs[$d]) for d in 1:N]
        tail = [:(subidxs[$d]) for d in N+1:length(subidxs.parameters)]
        :(@_propagate_inbounds_meta; (idxs[1][$(subs...)], reindex(V, tail(idxs), ($(tail...),))...))
    else
        :(throw(ArgumentError("cannot re-index $(ndims(V)) dimensional SubArray with fewer than $(ndims(V)) indices\nThis should not occur; please submit a bug report.")))
    end
end

# In general, we simply re-index the parent indices by the provided ones
SlowSubArray{T,N,P,I<:Union{Tuple{}, Tuple{ScalarIndex}, Tuple{Any,Any,Vararg{Any}}}} = SubArray{T,N,P,I}
function getindex(V::SlowSubArray{<:Any,N}, I::Vararg{Int,N}) where {N}
    @_inline_meta
    @boundscheck checkbounds(V, I...)
    @inbounds r = V.parent[reindex(V, V.indices, I)...]
    r
end

OneIndexSubArray{T,N,P,I<:Tuple{<:AbstractArray}} = SubArray{T,N,P,I}
function getindex(V::OneIndexSubArray, I::Int...)
    @_inline_meta
    @boundscheck checkbounds(V, I...)
    @inbounds r = V.parent[V.indices[1][I...]]
    r
end

function setindex!(V::SlowSubArray{<:Any,N}, x, I::Vararg{Int,N}) where {N}
    @_inline_meta
    @boundscheck checkbounds(V, I...)
    @inbounds V.parent[reindex(V, V.indices, I)...] = x
    V
end
function setindex!(V::OneIndexSubArray, x, I::Int...)
    @_inline_meta
    @boundscheck checkbounds(V, I...)
    @inbounds V.parent[V.indices[1][I...]] = x
    V
end

IndexStyle(::Type{<:SubArray{<:Any,<:Any,<:Any,<:Tuple{I}}}) where {I<:AbstractArray} = IndexStyle(I)
IndexStyle(::Type{<:SubArray}) = IndexCartesian()

strides(V::SubArray) = substrides(V.parent, V.indices)

substrides(parent, I::Tuple) = substrides(1, parent, 1, I)
substrides(s, parent, dim, ::Tuple{}) = ()
substrides(s, parent, dim, I::Tuple{ScalarIndex, Vararg{Any}}) = (substrides(s*size(parent, dim), parent, dim+1, tail(I))...)
substrides(s, parent, dim, I::Tuple{Slice, Vararg{Any}}) = (s, substrides(s*size(parent, dim), parent, dim+1, tail(I))...)
substrides(s, parent, dim, I::Tuple{AbstractRange, Vararg{Any}}) = (s*step(I[1]), substrides(s*size(parent, dim), parent, dim+1, tail(I))...)
substrides(s, parent, dim, I::Tuple{Any, Vararg{Any}}) = throw(ArgumentError("strides is invalid for SubArrays with indices of type $(typeof(I[1]))"))

stride(V::SubArray, d::Integer) = d <= ndims(V) ? strides(V)[d] : strides(V)[end] * size(V)[end]

compute_stride1(parent::AbstractArray, I::NTuple{N,Any}) where {N} =
    (@_inline_meta; compute_stride1(1, fill_to_length(indices(parent), OneTo(1), Val(N)), I))
compute_stride1(s, inds, I::Tuple{}) = s
compute_stride1(s, inds, I::Tuple{ScalarIndex, Vararg{Any}}) =
    (@_inline_meta; compute_stride1(s*unsafe_length(inds[1]), tail(inds), tail(I)))
compute_stride1(s, inds, I::Tuple{AbstractRange, Vararg{Any}}) = s*step(I[1])
compute_stride1(s, inds, I::Tuple{Slice, Vararg{Any}}) = s
compute_stride1(s, inds, I::Tuple{Any, Vararg{Any}}) = throw(ArgumentError("invalid strided index type $(typeof(I[1]))"))

iscontiguous(A::SubArray) = iscontiguous(typeof(A))
iscontiguous(::Type{<:SubArray}) = false
iscontiguous(::Type{<:SubArray{<:Any,<:Any,<:Any,<:Tuple{I}}}) where {I} = _iscontiguousindex(I)
_iscontiguousindex(::Type{<:AbstractUnitRange}) = true
_iscontiguousindex(::Type) = false

first_index(V::SubArray) = (@_inline_meta; first_index(V.parent, V.indices))
first_index(parent::AbstractArray, I::Tuple{Any}) = (@_inline_meta; first(I[1]))
first_index(parent::AbstractArray, I::Tuple) = (@_inline_meta; sub2ind(parent, map(first, I)...))

unsafe_convert(::Type{Ptr{T}}, V::SubArray{T,N,P,<:Tuple{Vararg{RangeIndex}}}) where {T,N,P} =
    unsafe_convert(Ptr{T}, V.parent) + (first_index(V)-1)*sizeof(T)

pointer(V::OneIndexSubArray, i::Int) = pointer(V.parent, V.indices[1][i])
pointer(V::SubArray, i::Int) = _pointer(V, i)
_pointer(V::SubArray{<:Any,1}, i::Int) = pointer(V, (i,))
_pointer(V::SubArray, i::Int) = pointer(V, ind2sub(indices(V), i))

# Most of the time, reshape needs to add a full layer of indirection. But when
# there's only one index then we just need to reshape that index
reshape(V::OneIndexSubArray, dims::Dims) =
    SubArray(V.parent, (reshape(V.indices[1], dims),))

"""
    replace_ref_end!(ex)

Recursively replace occurrences of the symbol :end in a "ref" expression (i.e. A[...]) `ex`
with the appropriate function calls (`endof` or `size`). Replacement uses
the closest enclosing ref, so

    A[B[end]]

should transform to

    A[B[endof(B)]]

"""
replace_ref_end!(ex) = replace_ref_end_!(ex, nothing)[1]
# replace_ref_end_!(ex,withex) returns (new ex, whether withex was used)
function replace_ref_end_!(ex, withex)
    used_withex = false
    if isa(ex,Symbol) && ex == :end
        withex === nothing && error("Invalid use of end")
        return withex, true
    elseif isa(ex,Expr)
        if ex.head == :ref
            ex.args[1], used_withex = replace_ref_end_!(ex.args[1],withex)
            S = isa(ex.args[1],Symbol) ? ex.args[1]::Symbol : gensym(:S) # temp var to cache ex.args[1] if needed
            used_S = false # whether we actually need S
            # new :ref, so redefine withex
            nargs = length(ex.args)-1
            if nargs == 0
                return ex, used_withex
            elseif nargs == 1
                # replace with endof(S)
                ex.args[2], used_S = replace_ref_end_!(ex.args[2],:($endof($S)))
            else
                n = 1
                J = endof(ex.args)
                for j = 2:J
                    exj, used = replace_ref_end_!(ex.args[j],:($size($S,$n)))
                    used_S |= used
                    ex.args[j] = exj
                    if isa(exj,Expr) && exj.head == :...
                        # splatted object
                        exjs = exj.args[1]
                        n = :($n + length($exjs))
                    elseif isa(n, Expr)
                        # previous expression splatted
                        n = :($n + 1)
                    else
                        # an integer
                        n += 1
                    end
                end
            end
            if used_S && S !== ex.args[1]
                S0 = ex.args[1]
                ex.args[1] = S
                ex = Expr(:let, :($S = $S0), ex)
            end
        else
            # recursive search
            for i = eachindex(ex.args)
                ex.args[i], used = replace_ref_end_!(ex.args[i],withex)
                used_withex |= used
            end
        end
    end
    ex, used_withex
end

"""
    @view A[inds...]

Creates a `SubArray` from an indexing expression. This can only be applied directly to a
reference expression (e.g. `@view A[1,2:end]`), and should *not* be used as the target of
an assignment (e.g. `@view(A[1,2:end]) = ...`).  See also [`@views`](@ref)
to switch an entire block of code to use views for slicing.

```jldoctest
julia> A = [1 2; 3 4]
2×2 Array{Int64,2}:
 1  2
 3  4

julia> b = @view A[:, 1]
2-element view(::Array{Int64,2}, :, 1) with eltype Int64:
 1
 3

julia> fill!(b, 0)
2-element view(::Array{Int64,2}, :, 1) with eltype Int64:
 0
 0

julia> A
2×2 Array{Int64,2}:
 0  2
 0  4
```
"""
macro view(ex)
    if Meta.isexpr(ex, :ref)
        ex = replace_ref_end!(ex)
        if Meta.isexpr(ex, :ref)
            ex = Expr(:call, view, ex.args...)
        else # ex replaced by let ...; foo[...]; end
            assert(Meta.isexpr(ex, :let) && Meta.isexpr(ex.args[2], :ref))
            ex.args[2] = Expr(:call, view, ex.args[2].args...)
        end
        Expr(:&&, true, esc(ex))
    else
        throw(ArgumentError("Invalid use of @view macro: argument must be a reference expression A[...]."))
    end
end

############################################################################
# @views macro code:

# maybeview is like getindex, but returns a view for slicing operations
# (while remaining equivalent to getindex for scalar indices and non-array types)
@propagate_inbounds maybeview(A, args...) = getindex(A, args...)
@propagate_inbounds maybeview(A::AbstractArray, args...) = view(A, args...)
@propagate_inbounds maybeview(A::AbstractArray, args::Number...) = getindex(A, args...)
@propagate_inbounds maybeview(A) = getindex(A)
@propagate_inbounds maybeview(A::AbstractArray) = getindex(A)

# _views implements the transformation for the @views macro.
# @views calls esc(_views(...)) to work around #20241,
# so any function calls we insert (to maybeview, or to
# size and endof in replace_ref_end!) must be interpolated
# as values rather than as symbols to ensure that they are called
# from Base rather than from the caller's scope.
_views(x) = x
function _views(ex::Expr)
    if ex.head in (:(=), :(.=))
        # don't use view for ref on the lhs of an assignment,
        # but still use views for the args of the ref:
        lhs = ex.args[1]
        Expr(ex.head, Meta.isexpr(lhs, :ref) ?
                      Expr(:ref, _views.(lhs.args)...) : _views(lhs),
             _views(ex.args[2]))
    elseif ex.head == :ref
        Expr(:call, maybeview, _views.(ex.args)...)
    else
        h = string(ex.head)
        # don't use view on the lhs of an op-assignment a[i...] += ...
        if last(h) == '=' && Meta.isexpr(ex.args[1], :ref)
            lhs = ex.args[1]

            # temp vars to avoid recomputing a and i,
            # which will be assigned in a let block:
            a = gensym(:a)
            i = [gensym(:i) for k = 1:length(lhs.args)-1]

            # for splatted indices like a[i, j...], we need to
            # splat the corresponding temp var.
            I = similar(i, Any)
            for k = 1:length(i)
                if Meta.isexpr(lhs.args[k+1], :...)
                    I[k] = Expr(:..., i[k])
                    lhs.args[k+1] = lhs.args[k+1].args[1] # unsplat
                else
                    I[k] = i[k]
                end
            end

            Expr(:let,
                 Expr(:block,
                      :($a = $(_views(lhs.args[1]))),
                      [:($(i[k]) = $(_views(lhs.args[k+1]))) for k=1:length(i)]...),
                 Expr(first(h) == '.' ? :(.=) : :(=), :($a[$(I...)]),
                      Expr(:call, Symbol(h[1:end-1]),
                           :($maybeview($a, $(I...))),
                           _views.(ex.args[2:end])...)))
        else
            Expr(ex.head, _views.(ex.args)...)
        end
    end
end

"""
    @views expression

Convert every array-slicing operation in the given expression
(which may be a `begin`/`end` block, loop, function, etc.)
to return a view.   Scalar indices, non-array types, and
explicit `getindex` calls (as opposed to `array[...]`) are
unaffected.

Note that the `@views` macro only affects `array[...]` expressions
that appear explicitly in the given `expression`, not array slicing that
occurs in functions called by that code.
"""
macro views(x)
    esc(_views(replace_ref_end!(x)))
end
