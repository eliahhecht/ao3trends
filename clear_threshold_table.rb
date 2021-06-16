require 'aws-sdk-dynamodb'

dynamodb_client = Aws::DynamoDB::Client.new

dynamodb_client.scan({ table_name: 'CrossedDailyThreshold' }).items.each do |i|
  puts "deleting #{i}"
  dynamodb_client.delete_item({ table_name: 'CrossedDailyThreshold', key: { fandom: i['fandom'] } })
end
