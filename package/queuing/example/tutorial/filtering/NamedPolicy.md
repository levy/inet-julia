# Naming a policy instead of writing it

INET's tutorial has steps where the interesting parameter is a *class name*:
`classifierClass = "inet::…"` picks which stock policy runs. Here a policy is
an ordinary function, so passing one is nothing special — a step's own model
just writes it.

Except when the step cannot. A step file is JSON, and JSON cannot hold a
function. So policies can be *registered under a name*, and a configuration
names one and gives it its argument.

## The network

The name and the argument come from the step file; the predicate is built from
them, and a name nobody registered fails loudly rather than quietly passing
everything:

```pred-ref
<<definition(file("../steps/classify.jl"), "_build_named_policy_network")>>
```

## Run it

`policy` is the registered name and `argument` its parameter. Try:

- `data_equals` with `1` — only the packets labelled 1, one in four here;
- `data_at_least` with `3` — labels 3 and 4, so half;
- `every_nth` with `4` — every fourth packet whatever its label, which is the
  ordinal question rather than the content one;
- `always` — everything, and the argument is ignored.

The difference from writing the predicate in the model is only *where the
choice lives*. What a name buys is that the choice can live in data — which is
what makes it worth having at all.

```pred-ref
<<realize(file("filtering/NamedPolicy.json"))>>
```
