"""
    InetExample

Umbrella package over the component example packages, so `using InetExample`
stays the one line that reaches every demo. Today that is `InetPacketExample`
alone (the packet & chunk API tour); a new component's example package joins
the loop below and needs no other edit here.
"""
module InetExample

import InetPacketExample

let _taken = Set{Symbol}()
    for _src in (InetPacketExample,)
        _srcname = nameof(_src)
        for _n in names(_src)
            _n === _srcname && continue
            isdefined(_src, _n) || continue   # an export with no binding behind it
            _n in _taken && continue          # homonym — the earlier package won
            push!(_taken, _n)
            Core.eval(@__MODULE__, Expr(:import, Expr(:(:), Expr(:., _srcname), Expr(:., _n))))
            Core.eval(@__MODULE__, Expr(:export, _n))
        end
    end
end

end # module InetExample
