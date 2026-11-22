require "minitest/autorun"
require "minitest/mock"
require "rate_limiter"

class RateLimiterTest < Minitest::Test
  class FakeClock
    attr_accessor :now

    def initialize
      @now = 100.0
    end

    def call
      now
    end
  end

  def setup
    @clock = FakeClock.new
    @limiter = RateLimiter.new(rate: 2.0, capacity: 3, max_keys: 2, clock: @clock)
  end

  def test_burst_grants_exactly_capacity_at_one_instant
    3.times { assert_equal true, @limiter.allow?(:client) }
    assert_equal false, @limiter.allow?(:client)
  end

  def test_refills_at_the_configured_rate_and_keeps_fractional_tokens
    assert @limiter.allow?(:client, cost: 3)

    @clock.now += 0.25
    assert_equal false, @limiter.allow?(:client)
    @clock.now += 0.25
    assert @limiter.allow?(:client)
    assert_equal false, @limiter.allow?(:client)

    @clock.now += 1.0
    assert @limiter.allow?(:client, cost: 2)
    assert_equal false, @limiter.allow?(:client)
  end

  def test_refill_caps_at_capacity_after_a_long_idle_period
    assert @limiter.allow?(:client, cost: 3)
    @clock.now += 100.0

    assert @limiter.allow?(:client, cost: 3)
    assert_equal false, @limiter.allow?(:client)
  end

  def test_custom_cost_deducts_exactly_that_many_tokens
    assert @limiter.allow?(:client, cost: 2)
    assert @limiter.allow?(:client)
    assert_equal false, @limiter.allow?(:client)
  end

  def test_cost_above_capacity_is_denied_even_with_a_full_bucket
    assert_equal false, @limiter.allow?(:client, cost: 4)
    assert @limiter.allow?(:client, cost: 3)
  end

  def test_cost_below_one_raises_argument_error
    [0, -1].each do |cost|
      assert_raises(ArgumentError) { @limiter.allow?(:client, cost: cost) }
    end
  end

  def test_denial_leaves_remaining_tokens_available
    assert @limiter.allow?(:client)
    assert_equal false, @limiter.allow?(:client, cost: 3)
    assert @limiter.allow?(:client, cost: 2)
    assert_equal false, @limiter.allow?(:client)
  end

  def test_new_keys_start_full_and_have_independent_buckets
    assert @limiter.allow?(:first, cost: 3)
    assert @limiter.allow?(:second, cost: 3)
    assert_equal false, @limiter.allow?(:first)
    assert_equal false, @limiter.allow?(:second)
  end

  def test_successful_allow_updates_lru_and_evicted_key_returns_full
    assert @limiter.allow?(:first)
    assert @limiter.allow?(:second, cost: 3)
    assert @limiter.allow?(:first, cost: 2)

    assert @limiter.allow?(:third, cost: 3)
    assert_equal false, @limiter.allow?(:first)
    assert @limiter.allow?(:second, cost: 3)
  end

  def test_allow_denied_for_insufficient_tokens_updates_lru
    assert_denial_updates_lru(cost: 1)
  end

  def test_allow_denied_for_cost_above_capacity_updates_lru
    assert_denial_updates_lru(cost: 4)
  end

  def test_size_counts_tracked_keys_and_stays_at_max_keys_after_eviction
    assert_equal 0, @limiter.size
    assert @limiter.allow?(:first, cost: 3)
    assert_equal 1, @limiter.size
    assert_equal false, @limiter.allow?(:first)
    assert_equal 1, @limiter.size

    assert @limiter.allow?(:second)
    assert_equal 2, @limiter.size
    assert @limiter.allow?(:third)
    assert_equal 2, @limiter.size
  end

  def test_retry_after_reports_deficit_over_rate_and_zero_when_ready
    assert @limiter.allow?(:client, cost: 3)
    assert_in_delta 0.5, @limiter.retry_after(:client)
    assert_in_delta 1.5, @limiter.retry_after(:client, cost: 3)

    @clock.now += 0.25
    assert_in_delta 0.25, @limiter.retry_after(:client)
    assert_in_delta 0.75, @limiter.retry_after(:client, cost: 2)

    @clock.now += 0.25
    assert_in_delta 0.0, @limiter.retry_after(:client)
    assert @limiter.allow?(:client)
    assert_in_delta 0.5, @limiter.retry_after(:client)
  end

  def test_retry_after_returns_infinity_for_cost_above_capacity
    assert @limiter.allow?(:known)
    assert_equal 1, @limiter.retry_after(:known, cost: 4).infinite?
    assert_equal 1, @limiter.retry_after(:unknown, cost: 4).infinite?
  end

  def test_retry_after_for_unknown_key_returns_zero_without_creating_or_evicting
    assert_in_delta 0.0, @limiter.retry_after(:unknown, cost: 3)
    assert_equal 0, @limiter.size

    assert @limiter.allow?(:first, cost: 3)
    assert @limiter.allow?(:second, cost: 3)
    assert_in_delta 0.0, @limiter.retry_after(:unknown)
    assert_equal 2, @limiter.size
    assert_in_delta 0.5, @limiter.retry_after(:first)
    assert_in_delta 0.5, @limiter.retry_after(:second)
  end

  def test_retry_after_does_not_touch_lru
    assert @limiter.allow?(:first, cost: 3)
    assert @limiter.allow?(:second, cost: 3)
    @clock.now += 0.25
    assert_in_delta 0.25, @limiter.retry_after(:first)

    assert @limiter.allow?(:third)
    assert_in_delta 0.25, @limiter.retry_after(:second)
    assert @limiter.allow?(:first, cost: 3)
  end

  def test_constructor_rejects_invalid_rate_capacity_and_max_keys
    valid = { rate: 2.0, capacity: 3, max_keys: 2, clock: @clock }
    invalid = {
      rate: [0.0, -0.5, Float::NAN, "2"],
      capacity: [0, -1, 1.5, "3"],
      max_keys: [0, -1, 1.5, "2"]
    }

    invalid.each do |option, values|
      values.each do |value|
        assert_raises(ArgumentError, "expected #{option}=#{value.inspect} to be rejected") do
          RateLimiter.new(**valid.merge(option => value))
        end
      end
    end
  end

  def test_constructor_accepts_positive_fractional_rate_and_minimum_integer_limits
    limiter = RateLimiter.new(rate: 0.5, capacity: 1, max_keys: 1, clock: @clock)
    assert limiter.allow?(:first)
    assert_in_delta 2.0, limiter.retry_after(:first)
    assert limiter.allow?(:second)
    assert_equal 1, limiter.size
  end

  def test_constructor_accepts_integer_rate
    limiter = RateLimiter.new(rate: 2, capacity: 1, clock: @clock)
    assert limiter.allow?(:a)
    assert_in_delta 0.5, limiter.retry_after(:a)
    assert_raises(ArgumentError) { RateLimiter.new(rate: 0, capacity: 1) }
  end

  def test_default_max_keys_is_ten_thousand
    limiter = RateLimiter.new(rate: 2.0, capacity: 1, clock: @clock)
    10_001.times { |key| limiter.allow?(key) }

    assert_equal 10_000, limiter.size
    assert_equal false, limiter.allow?(1)
    assert limiter.allow?(0)
  end

  def test_default_clock_uses_monotonic_seconds
    monotonic_clock = lambda do |clock_id|
      assert_equal Process::CLOCK_MONOTONIC, clock_id
      @clock.call
    end

    Process.stub(:clock_gettime, monotonic_clock) do
      limiter = RateLimiter.new(rate: 2.0, capacity: 1)
      assert limiter.allow?(:client)
      assert_equal false, limiter.allow?(:client)
      @clock.now += 0.5
      assert limiter.allow?(:client)
    end
  end

  def test_concurrent_allow_grants_exactly_capacity_with_a_frozen_clock
    ready = Queue.new
    start = Queue.new
    threads = Array.new(8) do
      Thread.new do
        ready << true
        start.pop
        Array.new(8) { @limiter.allow?(:client) }
      end
    end

    threads.size.times { ready.pop }
    threads.size.times { start << true }
    results = threads.flat_map(&:value)

    assert_equal 3, results.count(true)
    assert_equal 61, results.count(false)
  end

  private

  def assert_denial_updates_lru(cost:)
    assert @limiter.allow?(:first, cost: 3)
    assert @limiter.allow?(:second, cost: 3)
    assert_equal false, @limiter.allow?(:first, cost: cost)

    assert @limiter.allow?(:third, cost: 3)
    assert_equal false, @limiter.allow?(:first)
    assert @limiter.allow?(:second, cost: 3)
  end
end
