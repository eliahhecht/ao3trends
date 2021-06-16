require 'nokogiri'
require 'open-uri'
require 'aws-sdk-dynamodb'
require 'twitter'
require 'optparse'
require 'yaml'

Work = Struct.new(:fandoms, :id, :posted_date) do
  def posted_day_number
    posted_date.jd
  end
end

DailyFandomStats = Struct.new(:fandom, :works_seen) do
  def self.from_hash(hash)
    new(hash['fandom_name'], hash['works_seen'])
  end
end

Gain = Struct.new(:fandom, :gain_ratio)

class DailyStats
  attr_reader :works_seen_by_fandom

  def initialize(daily_fandom_stats)
    @sorted_stats = daily_fandom_stats.sort_by { |s| s.works_seen }.reverse
    @works_seen_by_fandom = daily_fandom_stats.map { |s| [s.fandom, s.works_seen] }.to_h
  end

  def top(n)
    @sorted_stats.take(n)
  end

  def position_of(fandom)
    @sorted_stats.each_with_index do |stats, i|
      return i if stats.fandom == fandom
    end
    nil
  end

  def works_seen(fandom)
    @works_seen_by_fandom[fandom]
  end

  def compute_gains(previous)
    @sorted_stats.filter { |s| works_seen(s.fandom) >= 30 }.map do |stat|
      today_seen = works_seen(stat.fandom)
      prev_seen = previous.works_seen(stat.fandom)
      Gain.new(stat.fandom, prev_seen ? today_seen.to_f / prev_seen.to_f : Float::INFINITY)
    end
  end

  def compute_biggest_gains(previous)
    compute_gains(previous).sort_by { |g| g.gain_ratio }.reverse.take(10)
  end
end

def parse_work(work)
  Work.new(
    work.css('.fandoms .tag').map { |t| t.text },
    work['id'].split('_')[1].to_i,
    Date.today
  )
end

def load_works
  doc = Nokogiri::HTML(URI.open('https://archiveofourown.org/works/search?utf8=%E2%9C%93' +
    '&work_search%5Bsort_column%5D=created_at&work_search%5Bsort_direction%5D=desc&commit=Search' +
    '&cache_bust=' + Time.now.to_i.to_s))
  doc.css('li.work').map { |w| parse_work(w) }
end

def persist
  dynamodb_client = Aws::DynamoDB::Client.new

  load_works.each do |work|
    put_work_result = dynamodb_client.put_item({ table_name: 'Works', item: { 'work_id': work.id },
                                                 return_values: 'ALL_OLD' })
    unless put_work_result.attributes
      puts "New work #{work}, persisting stats"
      persist_stats(dynamodb_client, work)
    end
  end
end

def persist_stats(dynamodb_client, work)
  work.fandoms.each do |fandom|
    new_stats = dynamodb_client.update_item(
      {
        table_name: 'StatsByDayNumber',
        key: { fandom_name: fandom, posted_day_number: work.posted_day_number },
        update_expression: 'ADD works_seen :val',
        expression_attribute_values: { ':val': 1 },
        return_values: 'UPDATED_NEW'
      }
    )
    daily_threshold = 30
    new_count_today = new_stats.attributes['works_seen']
    puts "#{fandom} at #{format('%i', new_count_today)} today"

    next unless new_count_today >= daily_threshold

    prev_threshold = dynamodb_client.put_item(
      {
        table_name: 'CrossedDailyThreshold',
        item: { 'fandom': fandom },
        return_values: 'ALL_OLD'
      }
    )
    if prev_threshold.attributes
      puts "but it already crossed #{daily_threshold}"
    else
      tweet("#{fandom} just crossed the threshold of #{daily_threshold} works in a day!")
    end
  end
end

def tweet(message, reply_to = nil)
  secrets = YAML.load(File.read('twitter_secrets.yaml'))
  client = Twitter::REST::Client.new do |config|
    config.consumer_key = secrets['consumer_key']
    config.consumer_secret = secrets['consumer_secret']
    config.access_token = secrets['access_token']
    config.access_token_secret = secrets['access_token_secret']
  end
  puts "Sending tweet:\n#{message}"
  if running_locally
    puts "But not really because we're running locally"
    return 1
  end
  sleep(1) # let's try not to get throttled by Twitter
  begin
    client.update(message, in_reply_to_status_id: reply_to).id
  rescue FrozenError # some kind of bug in http lib
    nil
  end
end

def get_stats_for_day(dynamodb_client, date)
  puts "Getting stats for #{date} from #{dynamodb_client}"
  fandom_stats = dynamodb_client.query(
    {
      table_name: 'StatsByDayNumber',
      key_condition_expression: 'posted_day_number = :d',
      expression_attribute_values: { ":d": date.jd }
    }
  ).items.map { |s| DailyFandomStats.from_hash(s) }
  DailyStats.new(fandom_stats)
end

def send_long_tweet(contents)
  prev_tweet_id = nil
  tweet_content = ''
  contents.each_with_index do |c, i|
    if can_fit_in_tweet(tweet_content, c)
      tweet_content += "\n" if i != 0
      tweet_content += c
    else
      prev_tweet_id = tweet(tweet_content, prev_tweet_id)
      tweet_content = c
    end
  end
  tweet(tweet_content, prev_tweet_id) if tweet_content.size > 0
end

def char_weight(c)
  weight_1_ranges = [0...4351, 8192...8205, 8208...8223, 8242...8247]
  weight_1_ranges.any? { |r| r.include?(c.ord) } ? 1 : 2
end

def twitter_length(str)
  str.chars.map { |c| char_weight(c) }.sum
end

def can_fit_in_tweet(current_contents, new_contents)
  if current_contents.empty?
    true
  else
    # add 1 because we put a newline in between
    twitter_length(current_contents) + twitter_length(new_contents) + 1 <= 280
  end
end

def compute_aggregate_stats
  dynamodb_client = Aws::DynamoDB::Client.new

  yesterday = Date.today - 1
  yesterday_stats = get_stats_for_day(dynamodb_client, yesterday)
  day_before_stats = get_stats_for_day(dynamodb_client, yesterday - 1)

  top_ten_tweet = ["Top fandoms for #{yesterday.strftime('%F')}:"]
  yesterday_stats.top(10).each_with_index do |stat, index|
    prev_index = day_before_stats.position_of(stat.fandom)
    delta = delta_string(prev_index, index)
    top_ten_tweet.append("#{index + 1}: #{stat.fandom}#{delta}: #{format('%i', stat.works_seen)} works")
  end
  send_long_tweet(top_ten_tweet)

  gains_tweet = ["Biggest-gaining fandoms for #{yesterday.strftime('%F')}:"]
  yesterday_stats.compute_biggest_gains(day_before_stats).filter { |g| g.gain_ratio > 1 }.each do |gain|
    delta = gain.gain_ratio == Float::INFINITY ? 'new' : format('+%i%%', (gain.gain_ratio * 100 - 100))
    gains_tweet.append("-#{gain.fandom}: #{delta}")
  end
  send_long_tweet(gains_tweet)
end

def delta_string(prev_index, new_index)
  if prev_index
    delta_num = prev_index - new_index
    if delta_num < 0
      " (#{delta_num})"
    elsif delta_num > 0
      " (+#{delta_num})"
    else
      ''
    end
  else
    ' (new)'
  end
end

def stats_for_range_of_days_back(range)
  dynamodb_client = Aws::DynamoDB::Client.new
  last_week_top_fandoms = range
                          .flat_map { |days_back| get_stats_for_day(dynamodb_client, Date.today - days_back) }
                          .flat_map { |stats| stats.works_seen_by_fandom.to_a }
                          .each_with_object(Hash.new(0)) { |item, acc| acc[item[0]] += item[1] }
                          .sort_by { |_k, v| -v }
end

def compute_weekly_stats
  two_weeks_ago_top_fandoms = stats_for_range_of_days_back(8...14)
  last_week_top_fandoms = stats_for_range_of_days_back(1...7)

  yesterday_str = (Date.today - 1).strftime('%F')
  top_ten_tweet = ["Top fandoms for the week ending #{yesterday_str}:"]
  last_week_top_fandoms.take(10).each_with_index do |entry, index|
    fandom, works = entry
    prev_index = two_weeks_ago_top_fandoms.index { |prev_entry| prev_entry[0] == fandom }
    delta = delta_string(prev_index, index)
    top_ten_tweet.append("#{index + 1}: #{fandom}#{delta}: #{format('%i', works)} works")
  end
  send_long_tweet(top_ten_tweet)

  two_weeks_ago_hash = two_weeks_ago_top_fandoms.to_h
  week_gains_tweet = last_week_top_fandoms.filter { |entry| entry[1] >= 100 }.map do |entry|
    fandom, works = entry
    prev_works = two_weeks_ago_hash[fandom]
    gain = prev_works ? works.to_f / prev_works.to_f : Float::INFINITY
    [fandom, gain]
  end.sort_by { |entry| -entry[1] }.take(10).map do |entry|
    fandom, gain = entry
    delta = gain == Float::INFINITY ? 'new' : format('+%i%%', (gain * 100 - 100))
    "-#{fandom}: #{delta}"
  end
  week_gains_tweet.prepend("Biggest-gaining fandoms for the week ending #{yesterday_str}:")
  send_long_tweet(week_gains_tweet)
end

def handler(event:, context:)
  action = event['action']
  case action
  when 'stats', 'daily_stats'
    compute_aggregate_stats
  when 'weekly_stats'
    compute_weekly_stats
  when 'scrape'
    persist
  else
    throw "Unrecognized action #{action}"
  end
  {}
end

def running_locally
  __FILE__ == $0
end

if running_locally
  read_from_prod = false
  OptionParser.new do |opts|
    opts.on('--read-from-prod') { |v| read_from_prod = v }
  end.parse!

  unless read_from_prod
    Aws.config.update(endpoint: 'http://localhost:8000')
    persist
  end
  compute_aggregate_stats
  compute_weekly_stats
end
