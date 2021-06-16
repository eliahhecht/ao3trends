require 'test/unit'
require_relative 'main'

class TestMain < Test::Unit::TestCase
  def test_tweet_len
    assert_equal(81, twitter_length('-僕のヒーローアカデミア | Boku no Hero Academia | My Hero Academia (0): 175 works'))
  end
end
