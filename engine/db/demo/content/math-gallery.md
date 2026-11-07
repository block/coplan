Coplan typesets LaTeX math with KaTeX. The source stays plain Markdown, so agents
and people edit it like any other text.

## Inline math

Each delivery attempt fails independently with probability $p$, so a message
still fails after $n$ attempts with probability $p^n$. With exponential backoff
starting at $b$ seconds, the wait before attempt $k$ is $`b \cdot 2^{k-1}`$.

## Display math

The total time spent waiting before giving up is a geometric series:

$$
T(n) = \sum_{k=1}^{n-1} b \cdot 2^{k-1} = b\,(2^{n-1} - 1)
$$

A math fence is display math too:

```math
n_{\min} = \left\lceil \frac{\ln \varepsilon}{\ln p} \right\rceil
```

## Math in lists and tables

- At $p = 0.2$ and a target of $\varepsilon = 10^{-4}$, we need $n_{\min} = 6$ attempts.
- The last wait is then $b \cdot 2^{5} = 32b$.

| Attempts $n$ | Failure rate $p^n$ | Total wait $T(n)$ |
| --- | --- | --- |
| 3 | $8 \times 10^{-3}$ | $3b$ |
| 6 | $6.4 \times 10^{-5}$ | $31b$ |

## Dollar amounts stay text

Each retry costs about $0.002 in compute, so six attempts cost under $5 per
thousand messages. Prices like $10 and $25 are not math.

## Invalid math stays readable

If an expression cannot be typeset, readers see its source instead:
$\frac{1}{$ is missing its denominator.

## Code is untouched

Dollar signs in code stay literal: `echo "$RETRY_LIMIT"`.

```bash
export RETRY_BUDGET="$((6 * 32))"
```
