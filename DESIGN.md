# Per-client rate limiter (smoke-test design)

## Problem
An API gateway must cap each client (by API key) to a sustained rate with short bursts allowed, in a single process, with bounded memory even with many one-off clients.

## Decisions
- **Algorithm: token bucket**, one bucket per key. Chosen over fixed window (allows 2x bursts at window edges) and sliding log (memory per request). Token bucket gives O(1) memory per key and natural burst control.
- **Lazy refill:** no background timer. On each call, add `elapsed * rate` tokens, capped at `capacity`.
- **Injectable clock:** a callable returning monotonic seconds (Float), so behavior is deterministic in tests. Default: `Process.clock_gettime(Process::CLOCK_MONOTONIC)`.
- **Bounded memory:** at most `max_keys` buckets. When a new key arrives at the cap, evict the least-recently-used key. An evicted key that returns starts with a full bucket (acceptable: it was idle).
- **New keys start full** (`capacity` tokens).
- **Thread-safe:** one Mutex around state is sufficient for this scope.
- Out of scope: distributed limiting, persistence, per-key custom limits.

## Interface (Ruby 2.6, stdlib only)
File: `lib/rate_limiter.rb`

```ruby
class RateLimiter
  # rate: tokens added per second (positive finite Integer or Float)
  # capacity: max tokens / burst size (Integer >= 1)
  # max_keys: max tracked keys (Integer >= 1), default 10_000
  # clock: object responding to #call -> Float seconds, default monotonic
  # Raises ArgumentError on invalid rate/capacity/max_keys.
  def initialize(rate:, capacity:, max_keys: 10_000, clock: nil); end

  # Try to consume `cost` tokens (Integer >= 1, default 1) for `key`.
  # Returns true and deducts tokens if available; otherwise false and deducts nothing.
  # cost > capacity always returns false. cost < 1 raises ArgumentError.
  # Counts as a "use" for LRU purposes either way.
  def allow?(key, cost: 1); end

  # Seconds until `cost` tokens will be available for `key` (0.0 if available now).
  # Unknown key -> 0.0 (cost <= capacity). cost > capacity -> Float::INFINITY.
  # Must NOT create, refill-persist, or LRU-touch the key (read-only).
  def retry_after(key, cost: 1); end

  # Number of keys currently tracked.
  def size; end
end
```

## Acceptance
- `ruby -Ilib -Itest test/test_rate_limiter.rb` passes.
- No gems beyond Ruby 2.6 stdlib + bundled minitest.
