require 'aws-sdk-dynamodb'

dynamodb_client = Aws::DynamoDB::Client.new
# Aws.config.update(endpoint: 'http://localhost:8000')

dynamodb_client.scan({ table_name: 'DailyStats' }).items.each_with_index do |i, x|
  puts x if x % 100 == 0
  dynamodb_client.put_item({
                             table_name: 'StatsByDayNumber',
                             item: {
                               'fandom_name' => i['fandom_name'],
                               'posted_day_number' => Time.at(i['posted_seconds_since_epoch']).utc.to_date.jd,
                               'works_seen' => i['works_seen']
                             }
                           })
end
