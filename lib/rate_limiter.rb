class RateLimiter
  def initialize(rate:, capacity:, max_keys: 10_000, clock: nil)
    unless rate.is_a?(Numeric) && rate.real? && rate.to_f.finite? && rate.positive?
      raise ArgumentError, "rate must be a positive finite number"
    end
    validate_positive_integer!(capacity, "capacity")
    validate_positive_integer!(max_keys, "max_keys")

    @rate = rate.to_f
    @capacity = capacity
    @max_keys = max_keys
    @clock = clock.nil? ? -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) } : clock
    @buckets = {}
    @mutex = Mutex.new
  end

  def allow?(key, cost: 1)
    validate_positive_integer!(cost, "cost")

    @mutex.synchronize do
      now = @clock.call
      bucket = @buckets.delete(key)
      @buckets.shift if !bucket && @buckets.size == @max_keys

      tokens = bucket ? refilled_tokens(bucket, now) : @capacity
      allowed = cost <= @capacity && tokens >= cost
      tokens -= cost if allowed
      # Hash insertion order runs from least to most recently used.
      @buckets[key] = [tokens, now]
      allowed
    end
  end

  def retry_after(key, cost: 1)
    validate_positive_integer!(cost, "cost")
    return Float::INFINITY if cost > @capacity

    @mutex.synchronize do
      bucket = @buckets[key]
      next 0.0 unless bucket

      tokens = refilled_tokens(bucket, @clock.call)
      tokens >= cost ? 0.0 : (cost - tokens) / @rate
    end
  end

  def size
    @mutex.synchronize { @buckets.size }
  end

  private

  def refilled_tokens(bucket, now)
    tokens, last_refill = bucket
    [tokens + (now - last_refill) * @rate, @capacity].min
  end

  def validate_positive_integer!(value, name)
    unless value.is_a?(Integer) && value >= 1
      raise ArgumentError, "#{name} must be a positive Integer"
    end
  end
end
