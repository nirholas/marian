# @marian/web

The four product surfaces. Vanilla TypeScript, Vite, viem. No framework, because the whole app is
five screens and a framework would be more code than the app.

```bash
node ../../scripts/demo.mjs   # in one terminal: fork, deploy, seed
pnpm dev                      # in another: http://localhost:5273
```

The app detects a local fork automatically by probing `http://127.0.0.1:8599` and reading the chain
id it reports. Pointed at a network with no deployment, it renders a designed explanation of how to
get one rather than a blank screen or a spinner that never resolves.

## The rule this app is built around

Every product here has one number that is easy to like and one that qualifies it:

| Easy to like | Qualifier |
|---|---|
| the premium | the capped upside |
| the cash you can borrow | the halt buffer that shrank it |
| the fixed rate | that unmatched money earns nothing |
| the payout you can sell | that on-chain accrual is far below the real dividend |

The `figure()` component takes `qualifier` as a **required** field, so shipping the first without the
second is a type error rather than an oversight. The payoff chart on the writing screen exists for
the same reason: it draws the ceiling before it draws anything else, shades the upside above the
strike, and labels it "upside you gave up".

## Checking it

```bash
node ../../scripts/check-web.mjs http://localhost:5273
```

Not a screenshot tour. It fails on any console error, any uncaught exception, any failed network
request, any page still showing a loading skeleton after settling, and any horizontal overflow at
380px wide. A skeleton that never resolves is exactly the failure a screenshot would hide.
