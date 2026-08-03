# ============================================================================
# Buffers — ChunkQueue and ChunkBuffer.
#
# ChunkQueue is FIFO storage for chunks, preserving order and total wire
# length. Transmission queues use it (put a chunk in, take a chunk out).
#
# ChunkBuffer is sparse: writes at arbitrary bit-offsets, tracks which
# regions are filled, supports region-query and gap enumeration (INET
# defect 4 — every INET caller wrote the same index-scan loop by hand).
# On CONFLICTING overlap ChunkBuffer takes a policy argument, fixing INET
# defect 3 (`ChunkBuffer.h:122`: *"TODO add flag to decide"* — silently
# preferring new data is wrong half the time for TCP retransmission).
#
# Reassembly/Reorder are built on top with a couple of helpers rather than
# separate types — INET's `ReassemblyBuffer` and `ReorderBuffer` are
# essentially thin wrappers over the buffer with a policy.
# ============================================================================

# ---------- ChunkQueue -------------------------------------------------------

"FIFO queue of chunks. `push!(q, c)` at the tail, `popfirst!(q, n)` at the head."
mutable struct ChunkQueue
    chunks::Vector{Chunk}
    total::BitLength
end
ChunkQueue() = ChunkQueue(Chunk[], ZERO_LENGTH)

Base.length(q::ChunkQueue) = Base.length(q.chunks)
Base.isempty(q::ChunkQueue) = isempty(q.chunks)
total_length(q::ChunkQueue) = q.total

function Base.push!(q::ChunkQueue, c::Chunk)
    isempty(c) && return q
    # Merge with the tail if possible (small optimisation, matches Sequence).
    if !isempty(q.chunks)
        m = _try_merge(q.chunks[end], c)
        if m !== nothing
            q.chunks[end] = m
            q.total = q.total + chunk_length(c)
            return q
        end
    end
    push!(q.chunks, c)
    q.total = q.total + chunk_length(c)
    return q
end

"""
    popfirst!(q, len::BitLength) -> Chunk

Consume `len` bits from the head and return them as a single (normalised)
chunk. Straddles chunk boundaries: the head chunk is sliced if `len` doesn't
consume it whole.
"""
function Base.popfirst!(q::ChunkQueue, len::BitLength)
    len <= q.total || error("ChunkQueue: pop $len exceeds queue total $(q.total)")
    parts = Chunk[]
    remaining = len.bits
    while remaining > 0
        head = q.chunks[1]
        head_len = chunk_length(head).bits
        if head_len <= remaining
            push!(parts, head)
            popfirst!(q.chunks)
            remaining -= head_len
        else
            push!(parts, slice(head, ZERO_LENGTH, BitLength(remaining)))
            q.chunks[1] = slice(head, BitLength(remaining), BitLength(head_len - remaining))
            remaining = 0
        end
    end
    q.total = q.total - len
    return sequence(parts)
end

# `peekfirst(q, len)` — non-consuming look at the head.
function peekfirst(q::ChunkQueue, len::BitLength)
    len <= q.total || error("ChunkQueue: peek $len exceeds queue total $(q.total)")
    parts = Chunk[]
    remaining = len.bits
    i = 1
    while remaining > 0
        head = q.chunks[i]
        head_len = chunk_length(head).bits
        take = min(head_len, remaining)
        push!(parts, slice(head, ZERO_LENGTH, BitLength(take)))
        remaining -= take
        i += 1
    end
    return sequence(parts)
end

# ---------- ChunkBuffer ------------------------------------------------------
#
# A sparse buffer: writes at arbitrary bit-offsets. Tracks filled regions as
# a sorted, non-overlapping vector of `(offset, chunk)` entries.
#
# OverlapPolicy governs what happens when a write covers already-filled bits:
#   OVERWRITE       — replace with the new bytes (INET's silent default)
#   KEEP_EXISTING   — keep old bytes, discard new (correct for TCP re-tx)
#   REFUSE          — throw

@enum OverlapPolicy OVERWRITE KEEP_EXISTING REFUSE

mutable struct ChunkBuffer
    regions::Vector{Tuple{Int64,Chunk}}   # (offset in bits, chunk); sorted, non-overlapping
end
ChunkBuffer() = ChunkBuffer(Tuple{Int64,Chunk}[])

Base.isempty(b::ChunkBuffer) = isempty(b.regions)
Base.length(b::ChunkBuffer)  = Base.length(b.regions)

"""
    write!(b::ChunkBuffer, offset::BitLength, chunk::Chunk;
           overlap::OverlapPolicy = REFUSE)

Write `chunk` at `offset`. If a filled region overlaps and the two bytes
DIFFER, `overlap` governs the outcome.
"""
function write!(b::ChunkBuffer, offset::BitLength, c::Chunk;
                overlap::OverlapPolicy = REFUSE)
    isempty(c) && return b
    off = Int64(offset.bits)
    len = Int64(chunk_length(c).bits)
    hi  = off + len - 1

    # Walk existing regions; handle any that intersect.
    new_regions = Tuple{Int64,Chunk}[]
    inserted = false
    for (r_off, r_chunk) in b.regions
        r_len = Int64(chunk_length(r_chunk).bits)
        r_hi  = r_off + r_len - 1
        if r_hi < off
            push!(new_regions, (r_off, r_chunk))
            continue
        elseif r_off > hi
            if !inserted
                push!(new_regions, (off, c)); inserted = true
            end
            push!(new_regions, (r_off, r_chunk))
            continue
        end
        # Overlap. Delegate to policy.
        overlap === REFUSE &&
            error("ChunkBuffer: overlap at [$r_off, $r_hi] vs write [$off, $hi]; policy = REFUSE")
        if overlap === KEEP_EXISTING
            # Split `c` into the parts NOT covered by (r_off, r_hi) and keep the existing.
            # We rebuild as: parts_of_c_left_of_r + existing + parts_of_c_right_of_r.
            if off < r_off
                left_len = r_off - off
                push!(new_regions, (off, slice(c, ZERO_LENGTH, BitLength(left_len))))
            end
            push!(new_regions, (r_off, r_chunk))
            if hi > r_hi
                right_off = r_hi + 1
                take_off  = right_off - off
                take_len  = hi - r_hi
                # trim the write's tail off c
                c = slice(c, BitLength(take_off), BitLength(take_len))
                off = right_off
                len = take_len
                hi  = off + len - 1
                # continue — the tail may overlap more existing regions
                continue
            end
            inserted = true
        elseif overlap === OVERWRITE
            # Preserve non-overlapping parts of the existing region.
            if r_off < off
                push!(new_regions, (r_off, slice(r_chunk, ZERO_LENGTH, BitLength(off - r_off))))
            end
            if !inserted
                push!(new_regions, (off, c)); inserted = true
            end
            if r_hi > hi
                keep_off = hi + 1
                keep_len = r_hi - hi
                take_off = keep_off - r_off
                push!(new_regions, (keep_off, slice(r_chunk, BitLength(take_off), BitLength(keep_len))))
            end
        end
    end
    if !inserted
        push!(new_regions, (off, c))
    end
    # Re-sort and coalesce touching regions.
    sort!(new_regions; by = first)
    coalesced = Tuple{Int64,Chunk}[]
    for entry in new_regions
        if !isempty(coalesced)
            (last_off, last_chunk) = coalesced[end]
            last_hi = last_off + Int64(chunk_length(last_chunk).bits) - 1
            if entry[1] == last_hi + 1
                merged = sequence(Chunk[last_chunk, entry[2]])
                coalesced[end] = (last_off, merged)
                continue
            end
        end
        push!(coalesced, entry)
    end
    b.regions = coalesced
    return b
end

"Byte range of the filled region containing `offset`, or `nothing` if in a gap."
function region_at(b::ChunkBuffer, offset::BitLength)
    off = Int64(offset.bits)
    for (r_off, r_chunk) in b.regions
        r_hi = r_off + Int64(chunk_length(r_chunk).bits) - 1
        if r_off <= off <= r_hi
            return (r_off:r_hi, r_chunk)
        end
    end
    return nothing
end

"Enumerate the gaps within [lo, hi]. Returns a Vector{UnitRange{Int64}}."
function gaps(b::ChunkBuffer, range::UnitRange{Int64})
    result = UnitRange{Int64}[]
    cursor = first(range)
    for (r_off, r_chunk) in b.regions
        r_hi = r_off + Int64(chunk_length(r_chunk).bits) - 1
        r_hi < cursor && continue
        r_off > last(range) && break
        if r_off > cursor
            push!(result, cursor:(r_off - 1))
        end
        cursor = r_hi + 1
    end
    if cursor <= last(range)
        push!(result, cursor:last(range))
    end
    return result
end

"Is [lo, hi] entirely filled (no gaps)?"
is_complete_range(b::ChunkBuffer, range::UnitRange{Int64}) = isempty(gaps(b, range))

"Read the assembled chunk over [lo, hi]. Errors on any gap."
function assembled_chunk(b::ChunkBuffer, range::UnitRange{Int64})
    isempty(gaps(b, range)) ||
        error("ChunkBuffer: cannot assemble; gaps at $(gaps(b, range))")
    parts = Chunk[]
    for (r_off, r_chunk) in b.regions
        r_hi = r_off + Int64(chunk_length(r_chunk).bits) - 1
        r_hi < first(range) && continue
        r_off > last(range) && break
        take_off = max(first(range) - r_off, 0)
        take_hi  = min(last(range),  r_hi) - r_off
        take_len = take_hi - take_off + 1
        push!(parts, slice(r_chunk, BitLength(Int64(take_off)), BitLength(Int64(take_len))))
    end
    return sequence(parts)
end
